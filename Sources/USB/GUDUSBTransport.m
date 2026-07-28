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
    __weak GUDUSBTransport *weakSelf = self;
    _interface = [[IOUSBHostInterface alloc]
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
    if (!_interface) {
        return nil;
    }

    _interfaceNumber = _interface.interfaceDescriptor->bInterfaceNumber;

    const IOUSBConfigurationDescriptor *config = _interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *interfaceDescriptor = _interface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *endpoint = NULL;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                config, interfaceDescriptor, (const IOUSBDescriptorHeader *)endpoint)) != NULL) {
        BOOL isOut = (endpoint->bEndpointAddress & 0x80) == 0;
        BOOL isBulk = (endpoint->bmAttributes & 0x03) == 0x02;
        if (isOut && isBulk) {
            _bulkOut = [_interface copyPipeWithAddress:endpoint->bEndpointAddress error:error];
            break;
        }
    }
    if (!_bulkOut) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:GUDUSBTransportErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"No bulk OUT endpoint on GUD interface"}];
        }
        [_interface destroy];
        _interface = nil;
        return nil;
    }

    return self;
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

- (void)invalidate
{
    _bulkOut = nil;
    [_interface destroy];
    _interface = nil;
}

@end
