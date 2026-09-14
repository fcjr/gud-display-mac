#import "GUDUSBTransport.h"

#import <IOUSBHost/IOUSBHost.h>
#import <IOKit/IOMessage.h>

NSErrorDomain const GUDUSBTransportErrorDomain = @"GUDUSBTransportErrorDomain";

// GUD control requests are vendor requests addressed to the interface.
static const uint8_t kGUDRequestTypeIn = 0xC1;  // IN | vendor | interface
static const uint8_t kGUDRequestTypeOut = 0x41; // OUT | vendor | interface

static const NSTimeInterval kControlTimeout = 5.0;
static const NSTimeInterval kBulkTimeout = 3.0;

@implementation GUDUSBTransport {
    IOUSBHostDevice *_device;
    IOUSBHostInterface *_interface;
    IOUSBHostPipe *_bulkOut;
    void (^_terminationHandler)(void);
}

- (nullable instancetype)initWithService:(io_service_t)service
                      terminationHandler:(void (^)(void))terminationHandler
                                   error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _terminationHandler = [terminationHandler copy];
    id productName = CFBridgingRelease(IORegistryEntryCreateCFProperty(
        service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0));
    if ([productName isKindOfClass:[NSString class]]) {
        _productName = [productName copy];
    }
    id serialNumber = CFBridgingRelease(IORegistryEntryCreateCFProperty(
        service, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0));
    if ([serialNumber isKindOfClass:[NSString class]]) {
        _serialNumber = [serialNumber copy];
    }
    id locationID = CFBridgingRelease(IORegistryEntryCreateCFProperty(
        service, CFSTR("locationID"), kCFAllocatorDefault, 0));
    if ([locationID isKindOfClass:[NSNumber class]]) {
        _locationID = [locationID unsignedIntValue];
    }
    __weak GUDUSBTransport *weakSelf = self;
    _device = [[IOUSBHostDevice alloc]
        initWithIOService:service
                  options:(IOUSBHostObjectInitOptions)0
                    queue:nil
                    error:error
          interestHandler:^(IOUSBHostObject *hostObject, uint32_t messageType, void *messageArgument) {
              if (messageType == kIOMessageServiceIsTerminated) {
                  GUDUSBTransport *strongSelf = weakSelf;
                  if (strongSelf && strongSelf->_terminationHandler) {
                      strongSelf->_terminationHandler();
                  }
              }
          }];
    if (!_device) {
        return nil;
    }

    // GUD gadgets are vendor-class at the device level, so no macOS driver
    // configures them (Linux's usbcore always does — this is the one host
    // duty macOS leaves to us). matchInterfaces publishes the interface nodes.
    if (_device.configurationDescriptor == NULL) {
        if (![_device configureWithValue:1 matchInterfaces:YES error:error]) {
            [_device destroy];
            _device = nil;
            return nil;
        }
    }

    io_service_t interfaceService = [self copyVendorInterfaceServiceForDevice:service];
    if (interfaceService == IO_OBJECT_NULL) {
        if (error) {
            *error = [NSError errorWithDomain:GUDUSBTransportErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey : @"Vendor interface did not appear after configuration"}];
        }
        [_device destroy];
        _device = nil;
        return nil;
    }

    _interface = [[IOUSBHostInterface alloc]
        initWithIOService:interfaceService
                  options:(IOUSBHostObjectInitOptions)0
                    queue:nil
                    error:error
          interestHandler:nil];
    IOObjectRelease(interfaceService);
    if (!_interface) {
        [_device destroy];
        _device = nil;
        return nil;
    }

    _interfaceNumber = _interface.interfaceDescriptor->bInterfaceNumber;

    NSNumber *speed = CFBridgingRelease(IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, CFSTR("Device Speed"), kCFAllocatorDefault, kIORegistryIterateRecursively));
    _deviceSpeed = speed ? speed.integerValue : -1;

    const IOUSBConfigurationDescriptor *config = _interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *interfaceDescriptor = _interface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *endpoint = NULL;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                config, interfaceDescriptor, (const IOUSBDescriptorHeader *)endpoint)) != NULL) {
        BOOL isOut = (endpoint->bEndpointAddress & 0x80) == 0;
        BOOL isBulk = (endpoint->bmAttributes & 0x03) == 0x02;
        if (isOut && isBulk) {
            _bulkOut = [_interface copyPipeWithAddress:endpoint->bEndpointAddress error:error];
            _bulkMaxPacketSize = endpoint->wMaxPacketSize & 0x7ff;
            break;
        }
    }
    if (!_bulkOut) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:GUDUSBTransportErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"No bulk OUT endpoint on GUD interface"}];
        }
        [self invalidate];
        return nil;
    }

    return self;
}

// The interface nodes register asynchronously after configuration; poll the
// device's registry children briefly for the vendor-specific interface.
- (io_service_t)copyVendorInterfaceServiceForDevice:(io_service_t)deviceService
{
    for (int attempt = 0; attempt < 40; attempt++) {
        io_iterator_t iterator = IO_OBJECT_NULL;
        if (IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &iterator) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
                if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                    NSNumber *interfaceClass = CFBridgingRelease(IORegistryEntryCreateCFProperty(
                        child, CFSTR("bInterfaceClass"), kCFAllocatorDefault, 0));
                    if (interfaceClass.unsignedIntValue == 0xff) {
                        IOObjectRelease(iterator);
                        return child;
                    }
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(iterator);
        }
        usleep(50 * 1000);
    }
    return IO_OBJECT_NULL;
}

- (void)dealloc
{
    [self invalidate];
}

- (nullable NSData *)controlInWithRequest:(uint8_t)bRequest
                                   wValue:(uint16_t)wValue
                                   length:(uint16_t)length
                                    error:(NSError **)error
{
    IOUSBDeviceRequest request = {
        .bmRequestType = kGUDRequestTypeIn,
        .bRequest = bRequest,
        .wValue = wValue,
        .wIndex = self.interfaceNumber,
        .wLength = length,
    };
    NSMutableData *data = length > 0 ? [NSMutableData dataWithLength:length] : nil;
    NSUInteger bytesTransferred = 0;
    BOOL ok = [_interface sendDeviceRequest:request
                                       data:data
                           bytesTransferred:&bytesTransferred
                          completionTimeout:kControlTimeout
                                      error:error];
    if (!ok) {
        return nil;
    }
    data.length = bytesTransferred;
    return data ?: [NSData data];
}

- (BOOL)controlOutWithRequest:(uint8_t)bRequest
                       wValue:(uint16_t)wValue
                         data:(nullable NSData *)data
                        error:(NSError **)error
{
    IOUSBDeviceRequest request = {
        .bmRequestType = kGUDRequestTypeOut,
        .bRequest = bRequest,
        .wValue = wValue,
        .wIndex = self.interfaceNumber,
        .wLength = (uint16_t)data.length,
    };
    NSMutableData *payload = data.length > 0 ? [data mutableCopy] : nil;
    NSUInteger bytesTransferred = 0;
    return [_interface sendDeviceRequest:request
                                    data:payload
                        bytesTransferred:&bytesTransferred
                       completionTimeout:kControlTimeout
                                   error:error];
}

- (BOOL)bulkWrite:(NSMutableData *)data error:(NSError **)error
{
    NSUInteger bytesTransferred = 0;
    BOOL ok = [_bulkOut sendIORequestWithData:data
                             bytesTransferred:&bytesTransferred
                            completionTimeout:kBulkTimeout
                                        error:error];
    if (!ok) {
        return NO;
    }
    if (bytesTransferred != data.length) {
        if (error) {
            *error = [NSError errorWithDomain:GUDUSBTransportErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"Short bulk transfer"}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)resetDeviceWithError:(NSError **)error
{
    return [_device resetWithError:error];
}

- (void)invalidate
{
    _bulkOut = nil;
    [_interface destroy];
    _interface = nil;
    [_device destroy];
    _device = nil;
}

@end
