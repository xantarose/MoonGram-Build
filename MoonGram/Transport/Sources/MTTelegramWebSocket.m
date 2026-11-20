#import "MTTelegramWebSocket.h"

@interface MTWebRead : NSObject
@property (nonatomic) NSUInteger length;
@property (nonatomic) long tag;
@end
@implementation MTWebRead
@end

@implementation MTTelegramWebSocket {
    __weak id<MTTcpConnectionInterfaceDelegate> _delegate;
    dispatch_queue_t _queue;
    NSURL *_url;
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSMutableArray<NSData *> *_writes;
    NSMutableArray<MTWebRead *> *_reads;
    NSMutableData *_buffer;
    NSUInteger _offset, _queuedBytes;
    BOOL _open, _closed, _sending, _receiving, _sentHeader;
}
static const NSUInteger MTWebBufferLimit = 32 * 1024 * 1024;

- (instancetype)initWithDatacenterTag:(int32_t)tag delegate:(id<MTTcpConnectionInterfaceDelegate>)delegate queue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _queue = queue;
        _writes = [NSMutableArray array];
        _reads = [NSMutableArray array];
        _buffer = [NSMutableData data];
        int dc = abs(tag);
        BOOL test = dc >= 10000;
        if (test) dc -= 10000;
        NSArray *names = @[@"pluto", @"venus", @"aurora", @"vesta", @"flora"];
        if (dc >= 1 && dc <= (int)names.count) {
            _url = [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@%@.web.telegram.org/%@", names[dc - 1], tag < 0 ? @"-1" : @"", test ? @"apiws_test" : @"apiws"]];
        }
    }
    return self;
}

- (bool)isWebProxyCarrier { return true; }
- (void)setGetLogPrefix:(NSString * _Nonnull (^_Nullable)())getLogPrefix {}
- (void)setUsageCalculationInfo:(MTNetworkUsageCalculationInfo *)info {}
- (bool)connectToHost:(NSString *)host onPort:(uint16_t)port viaInterface:(NSString *)interface withTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (!_url || _closed || _session) return false;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    _task = [_session webSocketTaskWithURL:_url protocols:@[@"binary"]];
    _task.maximumMessageSize = MTWebBufferLimit;
    [_task resume];
    if (timeout >= 0) {
        __weak MTTelegramWebSocket *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{
            MTTelegramWebSocket *strong = weakSelf;
            if (strong && !strong->_open) [strong fail:NSURLErrorTimedOut];
        });
    }
    return true;
}

- (void)writeData:(NSData *)data {
    if (_closed || data.length == 0) return;
    if (data.length > MTWebBufferLimit - _queuedBytes || _writes.count >= 2048) { [self fail:NSURLErrorDataLengthExceedsMaximum]; return; }
    _queuedBytes += data.length;
    if (!_sentHeader && data.length > 64) {
        [_writes addObject:[data subdataWithRange:NSMakeRange(0, 64)]];
        [_writes addObject:[data subdataWithRange:NSMakeRange(64, data.length - 64)]];
    } else { [_writes addObject:data]; }
    _sentHeader = YES;
    [self sendNext];
}

- (void)sendNext {
    if (!_open || _closed || _sending || !_writes.count) return;
    NSData *data = _writes.firstObject;
    _sending = YES;
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:data] completionHandler:^(NSError *error) {
        dispatch_async(self->_queue, ^{
            if (self->_closed) return;
            if (error) { [self finish:error]; return; }
            [self->_writes removeObjectAtIndex:0];
            self->_queuedBytes -= data.length;
            self->_sending = NO;
            [self sendNext];
        });
    }];
}

- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    if (_closed) return;
    if (length > MTWebBufferLimit || _reads.count >= 256) { [self fail:NSURLErrorDataLengthExceedsMaximum]; return; }
    MTWebRead *read = [[MTWebRead alloc] init];
    read.length = length;
    read.tag = tag;
    [_reads addObject:read];
    [self drainReads];
    if (timeout >= 0 && [_reads containsObject:read]) {
        __weak MTTelegramWebSocket *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{
            MTTelegramWebSocket *strong = weakSelf;
            if (strong && [strong->_reads containsObject:read]) [strong fail:NSURLErrorTimedOut];
        });
    }
}

- (void)drainReads {
    if (!_open || _closed) return;
    while (_reads.count) {
        MTWebRead *read = _reads.firstObject;
        if (read.length > _buffer.length - _offset) break;
        NSData *data = [_buffer subdataWithRange:NSMakeRange(_offset, read.length)];
        _offset += read.length;
        [_reads removeObjectAtIndex:0];
        // MTProtoKit may enqueue the next read synchronously from its callback.
        dispatch_async(_queue, ^{
            if (!self->_closed) [self->_delegate connectionInterfaceDidReadData:data withTag:read.tag networkType:0];
        });
    }
    if (!_reads.count || _receiving) return;
    if (_offset) { [_buffer replaceBytesInRange:NSMakeRange(0, _offset) withBytes:NULL length:0]; _offset = 0; }
    _receiving = YES;
    [_task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(self->_queue, ^{
            if (self->_closed) return;
            if (error) { [self finish:error]; return; }
            if (!message || message.type != NSURLSessionWebSocketMessageTypeData || message.data.length > MTWebBufferLimit - self->_buffer.length) {
                [self fail:NSURLErrorCannotDecodeRawData]; return;
            }
            self->_receiving = NO;
            [self->_buffer appendData:message.data];
            [self drainReads];
        });
    }];
}

- (void)fail:(NSInteger)code { [self finish:[NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil]]; }
- (void)finish:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    [_task cancel];
    [_session invalidateAndCancel];
    _task = nil;
    _session = nil;
    [_writes removeAllObjects];
    [_reads removeAllObjects];
    [_buffer setLength:0];
    [_delegate connectionInterfaceDidDisconnectWithError:error];
}
- (void)resetDelegate { _delegate = nil; }
- (void)disconnect { [self finish:nil]; }

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    dispatch_async(_queue, ^{
        if (self->_closed) return;
        if (![protocol isEqualToString:@"binary"]) { [self fail:NSURLErrorCannotParseResponse]; return; }
        self->_open = YES;
        [self->_delegate connectionInterfaceDidConnect];
        [self sendNext];
        [self drainReads];
    });
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler { completionHandler(nil); }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_async(_queue, ^{ [self finish:error]; });
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    dispatch_async(_queue, ^{ [self finish:nil]; });
}
@end
