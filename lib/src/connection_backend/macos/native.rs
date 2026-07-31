use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    fmt,
    ptr::NonNull,
    sync::Arc,
};

use macaddr::MacAddr6;
use tokio::sync::{mpsc, watch};
use tracing::warn;
use uuid::Uuid;

use crate::api::connection::ConnectionStatus;

type DeviceCallback = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char);
type ServiceCallback = unsafe extern "C" fn(*mut c_void, *const u8, u8);
type DataCallback = unsafe extern "C" fn(*mut c_void, *const u8, usize);
type DisconnectCallback = unsafe extern "C" fn(*mut c_void);

unsafe extern "C" {
    fn openscq30_macos_enumerate_devices(
        callback: DeviceCallback,
        context: *mut c_void,
    ) -> c_int;
    fn openscq30_macos_enumerate_services(
        address: *const c_char,
        callback: ServiceCallback,
        context: *mut c_void,
    ) -> c_int;
    fn openscq30_macos_open_rfcomm(
        address: *const c_char,
        channel: u8,
        data_callback: DataCallback,
        disconnect_callback: DisconnectCallback,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
    fn openscq30_macos_rfcomm_write(
        connection: *mut c_void,
        data: *const u8,
        length: usize,
    ) -> c_int;
    fn openscq30_macos_rfcomm_release(connection: *mut c_void);
}

#[derive(Debug)]
pub struct NativeError {
    action: &'static str,
    status: c_int,
}

impl NativeError {
    fn new(action: &'static str, status: c_int) -> Self {
        Self { action, status }
    }

    fn status_name(&self) -> &'static str {
        match self.status as u32 {
            0xe000_02bc => "kIOReturnError",
            0xe000_02c0 => "kIOReturnNoDevice",
            0xe000_02cd => "kIOReturnNotOpen",
            0xe000_02d6 => "kIOReturnTimeout",
            _ => "unknown IOReturn",
        }
    }
}

impl fmt::Display for NativeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "macOS IOBluetooth operation {} failed with {} ({}, 0x{:08x})",
            self.action,
            self.status_name(),
            self.status,
            self.status as u32
        )
    }
}

impl std::error::Error for NativeError {}

#[derive(Debug)]
pub struct NativeDevice {
    pub name: String,
    pub mac_address: MacAddr6,
}

pub fn devices() -> Result<Vec<NativeDevice>, NativeError> {
    let mut devices = Vec::new();
    let status = unsafe {
        openscq30_macos_enumerate_devices(
            collect_device,
            (&raw mut devices).cast::<c_void>(),
        )
    };
    if status == 0 {
        Ok(devices)
    } else {
        Err(NativeError::new("enumerate devices", status))
    }
}

unsafe extern "C" fn collect_device(
    context: *mut c_void,
    name: *const c_char,
    address: *const c_char,
) {
    let devices = unsafe { &mut *context.cast::<Vec<NativeDevice>>() };
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned();
    let address = unsafe { CStr::from_ptr(address) }.to_string_lossy();
    match address.parse() {
        Ok(mac_address) => devices.push(NativeDevice { name, mac_address }),
        Err(error) => warn!(%address, ?error, "ignoring invalid macOS Bluetooth address"),
    }
}

#[derive(Debug, Clone, Copy)]
pub struct NativeService {
    pub uuid: Uuid,
    pub channel: u8,
}

pub fn services(mac_address: MacAddr6) -> Result<Vec<NativeService>, NativeError> {
    let address = CString::new(mac_address.to_string()).expect("MAC addresses contain no NUL");
    let mut services = Vec::new();
    let status = unsafe {
        openscq30_macos_enumerate_services(
            address.as_ptr(),
            collect_service,
            (&raw mut services).cast::<c_void>(),
        )
    };
    if status == 0 {
        Ok(services)
    } else {
        Err(NativeError::new("enumerate RFCOMM services", status))
    }
}

unsafe extern "C" fn collect_service(context: *mut c_void, uuid: *const u8, channel: u8) {
    let services = unsafe { &mut *context.cast::<Vec<NativeService>>() };
    let bytes = unsafe { std::slice::from_raw_parts(uuid, 16) };
    if let Ok(uuid) = Uuid::from_slice(bytes) {
        services.push(NativeService { uuid, channel });
    }
}

struct CallbackContext {
    data_sender: mpsc::Sender<Vec<u8>>,
    connection_status: watch::Sender<ConnectionStatus>,
}

pub struct NativeConnection {
    handle: NonNull<c_void>,
    _callbacks: Arc<CallbackContext>,
}

unsafe impl Send for NativeConnection {}
unsafe impl Sync for NativeConnection {}

impl fmt::Debug for NativeConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("NativeConnection").finish_non_exhaustive()
    }
}

impl NativeConnection {
    pub fn open(
        mac_address: MacAddr6,
        channel: u8,
        data_sender: mpsc::Sender<Vec<u8>>,
        connection_status: watch::Sender<ConnectionStatus>,
    ) -> Result<Self, NativeError> {
        let address = CString::new(mac_address.to_string()).expect("MAC addresses contain no NUL");
        let callbacks = Arc::new(CallbackContext {
            data_sender,
            connection_status,
        });
        let mut status = 0;
        let handle = unsafe {
            openscq30_macos_open_rfcomm(
                address.as_ptr(),
                channel,
                receive_data,
                receive_disconnect,
                Arc::as_ptr(&callbacks).cast_mut().cast::<c_void>(),
                &raw mut status,
            )
        };
        let handle = NonNull::new(handle)
            .ok_or_else(|| NativeError::new("open RFCOMM channel", status))?;
        Ok(Self {
            handle,
            _callbacks: callbacks,
        })
    }

    pub fn write(&self, data: &[u8]) -> Result<(), NativeError> {
        let status = unsafe {
            openscq30_macos_rfcomm_write(self.handle.as_ptr(), data.as_ptr(), data.len())
        };
        if status == 0 {
            Ok(())
        } else {
            Err(NativeError::new("write RFCOMM packet", status))
        }
    }
}

unsafe extern "C" fn receive_data(context: *mut c_void, data: *const u8, length: usize) {
    let callbacks = unsafe { &*context.cast::<CallbackContext>() };
    let packet = unsafe { std::slice::from_raw_parts(data, length) }.to_vec();
    if let Err(error) = callbacks.data_sender.try_send(packet) {
        warn!(?error, "dropping RFCOMM packet because the receiver is unavailable");
    }
}

unsafe extern "C" fn receive_disconnect(context: *mut c_void) {
    let callbacks = unsafe { &*context.cast::<CallbackContext>() };
    callbacks
        .connection_status
        .send_replace(ConnectionStatus::Disconnected);
}

impl Drop for NativeConnection {
    fn drop(&mut self) {
        unsafe { openscq30_macos_rfcomm_release(self.handle.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_bluetooth_uuid_bytes() {
        let bytes = [
            0x00, 0x00, 0x11, 0x01, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5f,
            0x9b, 0x34, 0xfb,
        ];
        assert_eq!(
            Uuid::from_slice(&bytes).unwrap(),
            Uuid::parse_str("00001101-0000-1000-8000-00805f9b34fb").unwrap()
        );
    }

    #[test]
    fn parses_soundcore_vendor_uuid_bytes() {
        let bytes = [
            0x0c, 0xf1, 0x2d, 0x31, 0xfa, 0xc3, 0x45, 0x53, 0xbd, 0x80, 0xd6, 0x83, 0x2e,
            0x7b, 0x39, 0x57,
        ];
        assert_eq!(
            Uuid::from_slice(&bytes).unwrap(),
            Uuid::parse_str("0cf12d31-fac3-4553-bd80-d6832e7b3957").unwrap()
        );
    }

    #[test]
    fn names_known_io_return_errors() {
        let error = NativeError::new("test", 0xe000_02bcu32 as c_int);
        assert_eq!(error.status_name(), "kIOReturnError");
        assert!(error.to_string().contains("0xe00002bc"));
    }
}
