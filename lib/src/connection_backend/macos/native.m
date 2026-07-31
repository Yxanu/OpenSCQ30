#import "native.h"

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static NSString *OpenSCQ30NormalizedAddress(NSString *address) {
  return [[[address stringByReplacingOccurrencesOfString:@":" withString:@""]
      stringByReplacingOccurrencesOfString:@"-"
                                withString:@""] lowercaseString];
}

static IOBluetoothDevice *OpenSCQ30Device(NSString *address) {
  NSString *normalizedAddress = OpenSCQ30NormalizedAddress(address);
  for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
    if ([OpenSCQ30NormalizedAddress([device addressString])
            isEqualToString:normalizedAddress]) {
      return device;
    }
  }
  return nil;
}

@interface OpenSCQ30SDPQuery : NSObject
@property(nonatomic) BOOL finished;
@property(nonatomic) IOReturn status;
@end

@implementation OpenSCQ30SDPQuery
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
  (void)device;
  self.status = status;
  self.finished = YES;
}
@end

static IOReturn OpenSCQ30EnsureServices(IOBluetoothDevice *device) {
  if ([device services] != nil && [[device services] count] > 0) {
    return kIOReturnSuccess;
  }

  OpenSCQ30SDPQuery *query = [[OpenSCQ30SDPQuery alloc] init];
  IOReturn status = [device performSDPQuery:query];
  if (status != kIOReturnSuccess) {
    return status;
  }

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
  while (!query.finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop]
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return query.finished ? query.status : kIOReturnTimeout;
}

static IOBluetoothSDPUUID *
OpenSCQ30UUIDInElement(IOBluetoothSDPDataElement *element) {
  IOBluetoothSDPUUID *uuid = [element getUUIDValue];
  if (uuid != nil) {
    return uuid;
  }
  for (IOBluetoothSDPDataElement *child in [element getArrayValue]) {
    uuid = OpenSCQ30UUIDInElement(child);
    if (uuid != nil) {
      return uuid;
    }
  }
  return nil;
}

int32_t openscq30_macos_enumerate_devices(openscq30_device_callback callback,
                                          void *context) {
  @autoreleasepool {
    NSArray *devices = [IOBluetoothDevice pairedDevices];
    if (devices == nil) {
      return kIOReturnNoDevice;
    }
    for (IOBluetoothDevice *device in devices) {
      if (![device isConnected]) {
        continue;
      }
      NSString *name = [device nameOrAddress] ?: @"";
      NSString *address = [device addressString] ?: @"";
      callback(context, [name UTF8String], [address UTF8String]);
    }
    return kIOReturnSuccess;
  }
}

int32_t openscq30_macos_enumerate_services(const char *address,
                                           openscq30_service_callback callback,
                                           void *context) {
  @autoreleasepool {
    IOBluetoothDevice *device =
        OpenSCQ30Device([NSString stringWithUTF8String:address]);
    if (device == nil || ![device isConnected]) {
      return kIOReturnNoDevice;
    }

    IOReturn status = OpenSCQ30EnsureServices(device);
    if (status != kIOReturnSuccess) {
      return status;
    }

    for (IOBluetoothSDPServiceRecord *service in [device services]) {
      BluetoothRFCOMMChannelID channel = 0;
      if ([service getRFCOMMChannelID:&channel] != kIOReturnSuccess) {
        continue;
      }
      IOBluetoothSDPDataElement *classes =
          [service getAttributeDataElement:0x0001];
      IOBluetoothSDPUUID *uuid = OpenSCQ30UUIDInElement(classes);
      IOBluetoothSDPUUID *expanded = [uuid getUUIDWithLength:16];
      if (expanded == nil || [expanded length] != 16) {
        continue;
      }
      uint8_t bytes[16];
      [expanded getBytes:bytes length:sizeof(bytes)];
      callback(context, bytes, channel);
    }
    return kIOReturnSuccess;
  }
}

@interface OpenSCQ30RFCOMMConnection
    : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, copy) NSString *address;
@property(nonatomic) BluetoothRFCOMMChannelID channelID;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) NSThread *thread;
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSLock *writeLock;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL didNotifyDisconnect;
@property(nonatomic) IOReturn openStatus;
@property(nonatomic) openscq30_data_callback dataCallback;
@property(nonatomic) openscq30_disconnect_callback disconnectCallback;
@property(nonatomic) void *callbackContext;
- (BOOL)start;
- (void)stopAndWait;
- (IOReturn)writeBytes:(const uint8_t *)data length:(size_t)length;
@end

@implementation OpenSCQ30RFCOMMConnection
- (instancetype)initWithAddress:(NSString *)address
                      channelID:(BluetoothRFCOMMChannelID)channelID
                   dataCallback:(openscq30_data_callback)dataCallback
             disconnectCallback:
                 (openscq30_disconnect_callback)disconnectCallback
                        context:(void *)context {
  self = [super init];
  if (self != nil) {
    _address = [address copy];
    _channelID = channelID;
    _dataCallback = dataCallback;
    _disconnectCallback = disconnectCallback;
    _callbackContext = context;
    _condition = [[NSCondition alloc] init];
    _writeLock = [[NSLock alloc] init];
    _openStatus = kIOReturnError;
  }
  return self;
}

- (BOOL)start {
  self.thread = [[NSThread alloc] initWithTarget:self
                                        selector:@selector(connectionThread)
                                          object:nil];
  [self.thread setName:@"OpenSCQ30 RFCOMM"];
  [self.thread start];

  [self.condition lock];
  while (!self.ready) {
    [self.condition wait];
  }
  BOOL success = self.openStatus == kIOReturnSuccess;
  [self.condition unlock];
  return success;
}

- (void)connectionThread {
  @autoreleasepool {
    IOBluetoothDevice *device = OpenSCQ30Device(self.address);
    IOBluetoothRFCOMMChannel *channel = nil;
    IOReturn status = device == nil
                          ? kIOReturnNoDevice
                          : [device openRFCOMMChannelSync:&channel
                                            withChannelID:self.channelID
                                                 delegate:self];

    [self.condition lock];
    self.openStatus = status;
    if (status == kIOReturnSuccess) {
      self.channel = channel;
    }
    self.ready = YES;
    [self.condition broadcast];
    [self.condition unlock];

    if (status != kIOReturnSuccess) {
      return;
    }

    while (!self.stopping && [self.channel isOpen]) {
      @autoreleasepool {
        [[NSRunLoop currentRunLoop]
               runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      }
    }

    [self.channel setDelegate:nil];
    if ([self.channel isOpen]) {
      [self.channel closeChannel];
    }
    self.channel = nil;
  }
}

- (void)stopAndWait {
  self.stopping = YES;
  if (self.thread != nil && ![self.thread isFinished] &&
      [NSThread currentThread] != self.thread) {
    while (![self.thread isFinished]) {
      [NSThread sleepForTimeInterval:0.01];
    }
  }
}

- (IOReturn)writeBytes:(const uint8_t *)data length:(size_t)length {
  if (length > UINT16_MAX || self.channel == nil || ![self.channel isOpen]) {
    return kIOReturnNotOpen;
  }
  [self.writeLock lock];
  IOReturn status = [self.channel writeSync:(void *)data length:(UInt16)length];
  [self.writeLock unlock];
  return status;
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel
                     data:(void *)data
                   length:(size_t)length {
  (void)channel;
  self.dataCallback(self.callbackContext, data, length);
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
  (void)channel;
  self.stopping = YES;
  if (!self.didNotifyDisconnect) {
    self.didNotifyDisconnect = YES;
    self.disconnectCallback(self.callbackContext);
  }
}

- (void)dealloc {
  [self stopAndWait];
}
@end

void *
openscq30_macos_open_rfcomm(const char *address, uint8_t channel,
                            openscq30_data_callback data_callback,
                            openscq30_disconnect_callback disconnect_callback,
                            void *context, int32_t *status) {
  @autoreleasepool {
    OpenSCQ30RFCOMMConnection *connection = [[OpenSCQ30RFCOMMConnection alloc]
           initWithAddress:[NSString stringWithUTF8String:address]
                 channelID:channel
              dataCallback:data_callback
        disconnectCallback:disconnect_callback
                   context:context];
    BOOL success = [connection start];
    *status = connection.openStatus;
    if (!success) {
      return NULL;
    }
    return (__bridge_retained void *)connection;
  }
}

int32_t openscq30_macos_rfcomm_write(void *connection, const uint8_t *data,
                                     size_t length) {
  OpenSCQ30RFCOMMConnection *object =
      (__bridge OpenSCQ30RFCOMMConnection *)connection;
  return [object writeBytes:data length:length];
}

void openscq30_macos_rfcomm_release(void *connection) {
  if (connection == NULL) {
    return;
  }
  OpenSCQ30RFCOMMConnection *object =
      (__bridge_transfer OpenSCQ30RFCOMMConnection *)connection;
  [object stopAndWait];
}
