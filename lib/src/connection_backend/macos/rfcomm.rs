use std::{
    collections::HashSet,
    panic::Location,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use macaddr::MacAddr6;
use tokio::sync::{mpsc, watch};
use tracing::{debug, instrument};

use crate::{
    api::connection::{
        self, ConnectionDescriptor, ConnectionStatus, RfcommBackend, RfcommConnection,
    },
    connection::RfcommServiceSelectionStrategy,
};

use super::native::{self, NativeConnection};

#[derive(Debug, Default)]
pub struct MacosRfcommBackend;

#[async_trait]
impl RfcommBackend for MacosRfcommBackend {
    #[instrument(skip(self))]
    async fn devices(&self) -> connection::Result<HashSet<ConnectionDescriptor>> {
        tokio::task::spawn_blocking(native::devices)
            .await
            .expect("macOS device enumeration task panicked")
            .map(|devices| {
                devices
                    .into_iter()
                    .map(|device| ConnectionDescriptor {
                        name: device.name,
                        mac_address: device.mac_address,
                    })
                    .collect()
            })
            .map_err(|error| connection::Error::BluetoothAdapterUnavailable {
                source: Some(Box::new(error)),
                location: Location::caller(),
            })
    }

    #[instrument(skip(self, service_selection_strategy))]
    async fn connect(
        &self,
        mac_address: MacAddr6,
        service_selection_strategy: RfcommServiceSelectionStrategy,
    ) -> connection::Result<Arc<dyn RfcommConnection + Send + Sync>> {
        let services = tokio::task::spawn_blocking(move || native::services(mac_address))
            .await
            .expect("macOS service discovery task panicked")
            .map_err(|error| connection::Error::DeviceNotFound {
                source: Some(Box::new(error)),
                location: Location::caller(),
            })?;
        debug!(?services, "found RFCOMM services");

        let selected_uuid = match service_selection_strategy {
            RfcommServiceSelectionStrategy::Constant(uuid) => uuid,
            RfcommServiceSelectionStrategy::Dynamic(select_uuid) => {
                select_uuid(services.iter().map(|service| service.uuid).collect())
            }
        };
        let channel = services
            .iter()
            .find(|service| service.uuid == selected_uuid)
            .map(|service| service.channel)
            .ok_or(connection::Error::DeviceNotFound {
                source: None,
                location: Location::caller(),
            })?;
        debug!(%selected_uuid, channel, "opening RFCOMM service");

        let (data_sender, data_receiver) = mpsc::channel(100);
        let (connection_status_sender, connection_status_receiver) =
            watch::channel(ConnectionStatus::Connected);
        let native = tokio::task::spawn_blocking(move || {
            NativeConnection::open(mac_address, channel, data_sender, connection_status_sender)
        })
        .await
        .expect("macOS RFCOMM open task panicked")
        .map_err(|error| connection::Error::Other {
            source: Box::new(error),
            location: Location::caller(),
        })?;

        Ok(Arc::new(MacosRfcommConnection {
            native: Arc::new(native),
            read_channel: Mutex::new(Some(data_receiver)),
            connection_status: connection_status_receiver,
        }))
    }
}

#[derive(Debug)]
struct MacosRfcommConnection {
    native: Arc<NativeConnection>,
    read_channel: Mutex<Option<mpsc::Receiver<Vec<u8>>>>,
    connection_status: watch::Receiver<ConnectionStatus>,
}

#[async_trait]
impl RfcommConnection for MacosRfcommConnection {
    async fn write(&self, data: &[u8]) -> connection::Result<()> {
        let native = Arc::clone(&self.native);
        let data = data.to_vec();
        tokio::task::spawn_blocking(move || native.write(&data))
            .await
            .expect("macOS RFCOMM write task panicked")
            .map_err(|error| connection::Error::WriteError {
                source: Some(Box::new(error)),
                location: Location::caller(),
            })
    }

    fn read_channel(&self) -> mpsc::Receiver<Vec<u8>> {
        self.read_channel
            .lock()
            .unwrap()
            .take()
            .expect("read_channel may only be called once per MacosRfcommConnection")
    }

    fn connection_status(&self) -> watch::Receiver<ConnectionStatus> {
        self.connection_status.clone()
    }
}
