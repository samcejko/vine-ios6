#import "RVURLProtocol.h"
#import "RVVineAPI.h"
#import "RVDivine.h"
#import "RVHTTPRequest.h"
#import "RVCommon.h"

static const NSInteger RVMaxRedirects = 5;
static NSString * const RVProxyPrefix = @"http://media.vineapp.com/revine/proxy?u=";

static BOOL RVIsMediaHost(NSString *host)
{
    host = [host lowercaseString];
    return [host isEqualToString:@"media.divine.video"] || [host isEqualToString:@"cdn.divine.video"] ||
           [host isEqualToString:@"blossom.divine.video"];
}

// The address behind a proxy URL, nil for any other
static NSURL *RVProxyTarget(NSURL *url)
{
    if (![[url.host lowercaseString] isEqualToString:@"media.vineapp.com"] || ![url.path isEqualToString:@"/revine/proxy"]) return nil;
    for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
        if ([pair hasPrefix:@"u="]) {
            NSString *target = [[pair substringFromIndex:2] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            NSURL *targetURL = target ? [NSURL URLWithString:target] : nil;
            NSString *scheme = [targetURL.scheme lowercaseString];
            return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) ? targetURL : nil;
        }
    }
    return nil;
}

@interface RVURLProtocol ()
@property (nonatomic, strong) RVHTTPRequest *http;
@property (nonatomic, strong) NSThread *clientThread;
@property (nonatomic, strong) NSArray *clientModes;
@property (atomic) BOOL stopped;
@end

@implementation RVURLProtocol

+ (void)registerProtocol
{
    [NSURLProtocol registerClass:self];
}

+ (NSString *)proxyURLForURL:(NSString *)url
{
    if (!url.length) return url;
    NSURL *parsed = [NSURL URLWithString:url];
    if (!parsed || RVIsMediaHost(parsed.host) || [RVVineAPI handlesHost:parsed.host]) return url;
    return [RVProxyPrefix stringByAppendingString:[RVDivine escape:url]];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSURL *url = request.URL;
    NSString *scheme = [url.scheme lowercaseString];
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return NO;
    return [RVVineAPI handlesHost:url.host] || RVIsMediaHost(url.host);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

// (the client is talked to on the thread that called -startLoading, in its run loop modes)
- (void)performOnClientThread:(dispatch_block_t)block
{
    if (!self.clientThread || !block) return;
    [self performSelector:@selector(rv_runBlock:) onThread:self.clientThread withObject:[block copy] waitUntilDone:NO modes:self.clientModes];
}

- (void)rv_runBlock:(dispatch_block_t)block
{
    if (!self.stopped) block();
}

- (void)startLoading
{
    self.clientThread = [NSThread currentThread];
    NSString *mode = [[NSRunLoop currentRunLoop] currentMode];
    NSMutableArray *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    if (mode.length && ![mode isEqualToString:NSDefaultRunLoopMode]) [modes addObject:mode];
    self.clientModes = modes;

    NSURL *url = self.request.URL;
    NSURL *target = RVProxyTarget(url);
    if (target || RVIsMediaHost(url.host)) {
        [self fetch:target ?: url redirects:0];
        return;
    }
    NSURLRequest *request = self.request;
    NSData *body = [self requestBody];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.stopped) return;
        RVVineResponse *answer = [RVVineAPI responseForRequest:request body:body];
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        headers[@"Content-Type"] = answer.contentType ?: @"application/json";
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)answer.body.length];
        headers[@"Cache-Control"] = @"no-store";
        [self deliverStatus:answer.status headers:headers body:answer.body cache:NSURLCacheStorageNotAllowed];
    });
}

- (void)stopLoading
{
    self.stopped = YES;
    [self.http cancel];
}

// HTTPBody, or the stream AFNetworking may have set instead
- (NSData *)requestBody
{
    NSData *body = self.request.HTTPBody;
    if (body) return body;
    NSInputStream *stream = self.request.HTTPBodyStream;
    if (!stream) return nil;
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[16384];
    [stream open];
    while (data.length < 2 * 1024 * 1024) {
        NSInteger n = [stream read:buffer maxLength:sizeof(buffer)];
        if (n <= 0) break;
        [data appendBytes:buffer length:(NSUInteger)n];
    }
    [stream close];
    return data;
}

- (void)deliverStatus:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body cache:(NSURLCacheStoragePolicy)policy
{
    [self performOnClientThread:^{
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:policy];
        if (body.length) [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

#pragma mark - Media

// Videos (Vine downloads them to a file before playing), thumbnails and avatars: streamed as they arrive, Range
// requests passed on (the downloader resumes .part files)
- (void)fetch:(NSURL *)url redirects:(NSInteger)redirects
{
    NSString *method = [[self.request.HTTPMethod uppercaseString] isEqualToString:@"HEAD"] ? @"HEAD" : @"GET";
    RVHTTPRequest *r = [[RVHTTPRequest alloc] initWithMethod:method URL:url];
    r.noCompression = YES;
    r.highPriority = YES;
    r.connectTimeout = 15;
    r.readTimeout = 30;
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:[RVHTTPRequest defaultUserAgent] forKey:@"User-Agent"];
    for (NSString *name in @[@"Range", @"If-Range", @"Accept"]) {
        NSString *value = [self.request valueForHTTPHeaderField:name];
        if (value.length) headers[name] = value;
    }
    r.headers = headers;

    __weak RVURLProtocol *weakSelf = self;
    __block BOOL redirected = NO;
    __block BOOL answered = NO;
    r.onHeaders = ^(NSInteger status, NSDictionary *responseHeaders) {
        RVURLProtocol *me = weakSelf;
        if (!me || me.stopped) return;
        NSString *location = responseHeaders[@"location"];
        if (status >= 300 && status < 400 && location.length && redirects < RVMaxRedirects) {
            redirected = YES;
            NSURL *next = [[NSURL URLWithString:location relativeToURL:url] absoluteURL];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                RVURLProtocol *again = weakSelf;
                if (!again || again.stopped) return;
                if (next) [again fetch:next redirects:redirects + 1];
                else [again failWith:RVMakeError(RVErrorBadResponse, @"Bad redirect")];
            });
            return;
        }
        answered = YES;
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"content-type", @"content-length", @"content-range", @"accept-ranges", @"etag", @"last-modified"]) {
            NSString *value = responseHeaders[name];
            if (value.length) fields[[name capitalizedString]] = value;
        }
        if ([fields[@"Content-Type"] hasPrefix:@"video/"] || [fields[@"Content-Type"] hasPrefix:@"image/"]) {
            fields[@"Cache-Control"] = @"max-age=86400";
        }
        [me performOnClientThread:^{
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:me.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:fields];
            [me.client URLProtocol:me didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }];
    };
    r.onData = ^(NSData *chunk) {
        RVURLProtocol *me = weakSelf;
        if (!me || me.stopped || redirected || !chunk.length) return;
        NSData *copy = [chunk copy];
        [me performOnClientThread:^{ [me.client URLProtocol:me didLoadData:copy]; }];
    };
    r.onComplete = ^(NSError *error) {
        RVURLProtocol *me = weakSelf;
        if (!me || me.stopped || redirected) return;
        if (error) {
            RVLog(@"media %@ failed: %@", url.absoluteString, error.localizedDescription);
            [me failWith:error];
            return;
        }
        if (!answered) {
            [me failWith:RVMakeError(RVErrorBadResponse, @"No response")];
            return;
        }
        [me performOnClientThread:^{ [me.client URLProtocolDidFinishLoading:me]; }];
    };
    self.http = r;
    [r start];
}

- (void)failWith:(NSError *)error
{
    NSError *urlError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost
                                        userInfo:@{ NSLocalizedDescriptionKey: error.localizedDescription ?: @"" }];
    [self performOnClientThread:^{ [self.client URLProtocol:self didFailWithError:urlError]; }];
}

@end
