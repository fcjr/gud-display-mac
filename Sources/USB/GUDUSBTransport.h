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

/// USB link speed reported by IOKit (0 low, 1 full, 2 high, 3 super, ...).
/// Bounds how much framebuffer traffic the device can possibly absorb.
@property(readonly, nonatomic) NSInteger deviceSpeed;

/// wMaxPacketSize of the bulk OUT endpoint.
@property(readonly, nonatomic) NSUInteger bulkMaxPacketSize;

/// Claims the IOUSBHostDevice for the given service, ensures a configuration
/// is selected (GUD gadgets report bDeviceClass 0xFF, so macOS's composite
/// driver never configures them and no interface nodes exist until we do),
/// then claims the vendor-specific interface and locates its bulk OUT pipe.
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

/// Resets and re-enumerates the device (recovery for wedged firmware).
/// The current services terminate — the termination handler will fire — and
/// the device re-registers as a new service for fresh matching.
- (BOOL)resetDeviceWithError:(NSError **)error;

/// Releases the interface. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
