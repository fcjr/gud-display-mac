//
// GUDUSBTransport.h
//
// Thin Objective-C wrapper around IOUSBHost for the GUD protocol's transport
// needs: vendor-interface control requests on EP0 and bulk OUT writes.
// Objective-C because IOUSBHost's Swift-refined API surface is undocumented.
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const GUDUSBTransportErrorDomain;

@interface GUDUSBTransport : NSObject

/// Interface number of the claimed USB interface (used as wIndex in control requests).
@property(readonly, nonatomic) uint8_t interfaceNumber;

/// Claims the IOUSBHostInterface for the given service and locates the bulk OUT pipe.
/// The service must be an IOUSBHostInterface with bInterfaceClass 0xFF.
- (nullable instancetype)initWithService:(io_service_t)service
                      terminationHandler:(void (^)(void))terminationHandler
                                   error:(NSError **)error;

/// Vendor-interface control IN (bmRequestType 0xC1). Returns the received bytes.
- (nullable NSData *)controlInWithRequest:(uint8_t)bRequest
                                   wValue:(uint16_t)wValue
                                   length:(uint16_t)length
                                    error:(NSError **)error;

/// Vendor-interface control OUT (bmRequestType 0x41). Pass nil data for zero-length requests.
- (BOOL)controlOutWithRequest:(uint8_t)bRequest
                       wValue:(uint16_t)wValue
                         data:(nullable NSData *)data
                        error:(NSError **)error;

/// Synchronous bulk OUT transfer of the entire buffer. The buffer is used
/// directly for IO (no copy); callers should reuse one buffer across flushes.
- (BOOL)bulkWrite:(NSMutableData *)data error:(NSError **)error;

/// Releases the interface. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
