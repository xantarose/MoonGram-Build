#import <Foundation/Foundation.h>
#import <MtProtoKit/MTContext.h>

/// A first-party Telegram Web connection. MTProtoKit retains ownership of encryption and framing.
@interface MTTelegramWebSocket : NSObject <MTTcpConnectionInterface, NSURLSessionWebSocketDelegate>
- (instancetype)initWithDatacenterTag:(int32_t)tag delegate:(id<MTTcpConnectionInterfaceDelegate>)delegate queue:(dispatch_queue_t)queue;
@end
