#import <XCTest/XCTest.h>
#import <IOUSBHost/IOUSBHost.h>
#import "../Sources/USB/GUDUSBTransport.h"

// Exercise the real transport's completion and teardown code without USB.
@interface GUDFakeBulkPipe : NSObject
@property(nonatomic, copy) IOUSBHostCompletionHandler completion;
@property(nonatomic) BOOL rejectEnqueue;
@property(nonatomic) NSUInteger enqueueCount;
@property(nonatomic) NSTimeInterval timeout;
- (void)completeWithStatus:(IOReturn)status bytes:(NSUInteger)bytes;
@end

@implementation GUDFakeBulkPipe
- (BOOL)enqueueIORequestWithData:(NSMutableData *)data
              completionTimeout:(NSTimeInterval)timeout
                          error:(NSError **)error
              completionHandler:(IOUSBHostCompletionHandler)completion
{
    self.enqueueCount += 1;
    self.timeout = timeout;
    if (self.rejectEnqueue) {
        if (error) {
            *error = [NSError errorWithDomain:NSMachErrorDomain code:kIOReturnNoDevice userInfo:nil];
        }
        return NO;
    }
    self.completion = completion;
    return YES;
}

- (void)completeWithStatus:(IOReturn)status bytes:(NSUInteger)bytes
{
    IOUSBHostCompletionHandler completion = self.completion;
    self.completion = nil;
    if (completion) { completion(status, bytes); }
}

- (BOOL)abortWithOption:(IOUSBHostAbortOption)option error:(NSError **)error
{
    [self completeWithStatus:kIOReturnAborted bytes:0];
    return YES;
}
@end

@interface GUDUSBTransportTests : XCTestCase
@property(nonatomic, strong) GUDUSBTransport *transport;
@property(nonatomic, strong) GUDFakeBulkPipe *pipe;
@end

@implementation GUDUSBTransportTests
- (void)setUp
{
    [super setUp];
    self.transport = [GUDUSBTransport new];
    self.pipe = [GUDFakeBulkPipe new];
    [self.transport setValue:self.pipe forKey:@"bulkOut"];
}

- (void)tearDown
{
    [self.transport invalidate];
    self.transport = nil;
    self.pipe = nil;
    [super tearDown];
}

- (void)testSuccessRetainsPayloadUntilCompletion
{
    __weak NSMutableData *payload;
    @autoreleasepool {
        NSMutableData *data = [NSMutableData dataWithLength:64];
        payload = data;
        XCTAssertTrue([self.transport beginBulkWrite:data error:nil]);
    }
    XCTAssertNotNil(payload);
    XCTAssertEqual(self.pipe.timeout, 3.0);
    [self.pipe completeWithStatus:kIOReturnSuccess bytes:64];
    XCTAssertTrue([self.transport waitBulkWriteWithError:nil]);
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:8] error:nil]);
    [self.pipe completeWithStatus:kIOReturnSuccess bytes:8];
    XCTAssertTrue([self.transport waitBulkWriteWithError:nil]);
}

- (void)testShortCompletionIsAnError
{
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:nil]);
    [self.pipe completeWithStatus:kIOReturnSuccess bytes:32];
    NSError *error = nil;
    XCTAssertFalse([self.transport waitBulkWriteWithError:&error]);
    XCTAssertEqualObjects(error.localizedDescription, @"Short bulk transfer: 32 of 64 bytes");
}

- (void)testTimeoutPreservesUSBStatus
{
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:nil]);
    [self.pipe completeWithStatus:kIOReturnTimeout bytes:0];
    NSError *error = nil;
    XCTAssertFalse([self.transport waitBulkWriteWithError:&error]);
    XCTAssertEqual(error.code, kIOReturnTimeout);
}

- (void)testEnqueueFailureAllowsNextTransfer
{
    self.pipe.rejectEnqueue = YES;
    NSError *error = nil;
    XCTAssertFalse([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:&error]);
    XCTAssertEqual(error.code, kIOReturnNoDevice);
    XCTAssertTrue([self.transport waitBulkWriteWithError:nil]);
    self.pipe.rejectEnqueue = NO;
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:8] error:nil]);
    [self.pipe completeWithStatus:kIOReturnSuccess bytes:8];
    XCTAssertTrue([self.transport waitBulkWriteWithError:nil]);
}

- (void)testSecondBeginDoesNotOverwritePendingResult
{
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:nil]);
    NSError *error = nil;
    XCTAssertFalse([self.transport beginBulkWrite:[NSMutableData dataWithLength:8] error:&error]);
    XCTAssertEqual(error.code, kIOReturnBusy);
    XCTAssertEqual(self.pipe.enqueueCount, 1u);
    [self.pipe completeWithStatus:kIOReturnSuccess bytes:64];
    XCTAssertTrue([self.transport waitBulkWriteWithError:nil]);
}

- (void)testInvalidationDrainsCompletionAndRejectsNewIO
{
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:nil]);
    [self.transport invalidate];
    NSError *error = nil;
    XCTAssertFalse([self.transport waitBulkWriteWithError:&error]);
    XCTAssertEqual(error.code, kIOReturnAborted);
    error = nil;
    XCTAssertFalse([self.transport beginBulkWrite:[NSMutableData dataWithLength:8] error:&error]);
    XCTAssertEqual(error.code, kIOReturnNoDevice);
    [self.transport invalidate];
}

- (void)testInvalidationCanWakeAWaitingWorker
{
    XCTAssertTrue([self.transport beginBulkWrite:[NSMutableData dataWithLength:64] error:nil]);
    XCTestExpectation *finished = [self expectationWithDescription:@"bulk wait returns after cancellation"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        XCTAssertFalse([self.transport waitBulkWriteWithError:&error]);
        XCTAssertEqual(error.code, kIOReturnAborted);
        [finished fulfill];
    });
    [self.transport invalidate];
    [self waitForExpectations:@[finished] timeout:2.0];
}
@end
