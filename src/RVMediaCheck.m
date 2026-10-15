#import "RVMediaCheck.h"
#import "RVHTTPRequest.h"
#import "RVCommon.h"

static const NSUInteger RVMaxKnown = 20000;

static NSMutableDictionary *g_known;     // file name (the blob's hash) -> @YES present / @NO missing
static BOOL g_saveScheduled;
static dispatch_queue_t g_checkQueue;

static NSString *RVMediaCheckPath(void)
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    return [caches stringByAppendingPathComponent:@"Revine/media.plist"];
}

// (the hash names the blob; "x.mp4" and "x" are the same file)
static NSString *RVMediaKey(NSString *url)
{
    return [[[NSURL URLWithString:url] lastPathComponent] stringByDeletingPathExtension] ?: url;
}

static void RVMediaCheckLoad(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_known = [[NSDictionary dictionaryWithContentsOfFile:RVMediaCheckPath()] mutableCopy] ?: [NSMutableDictionary dictionary];
        g_checkQueue = dispatch_queue_create("eu.samcejko.revine.mediacheck", DISPATCH_QUEUE_CONCURRENT);
    });
}

static void RVMediaCheckSaveLater(void)
{
    // (inside @synchronized (g_known))
    if (g_saveScheduled) return;
    g_saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSDictionary *snapshot;
        @synchronized (g_known) {
            g_saveScheduled = NO;
            snapshot = [g_known copy];
        }
        NSString *path = RVMediaCheckPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [snapshot writeToFile:path atomically:YES];
    });
}

// One check: YES present, NO missing, nil unknown (network trouble)
static NSNumber *RVProbe(NSString *url)
{
    NSURL *target = [NSURL URLWithString:url];
    if (!target) return nil;
    RVHTTPRequest *request = [[RVHTTPRequest alloc] initWithMethod:@"GET" URL:target];
    request.headers = @{ @"Range": @"bytes=0-0" };
    request.noCompression = YES;
    request.connectTimeout = 5;
    request.readTimeout = 5;
    __block NSInteger status = 0;
    __weak RVHTTPRequest *weakRequest = request;
    request.onHeaders = ^(NSInteger code, NSDictionary *headers) {
        status = code;
        if (code == 200) [weakRequest cancel];   // (a server that ignores the range: the whole file is not needed)
    };
    request.onData = ^(NSData *chunk) {};
    [request runSynchronously];
    if (status == 200 || status == 206) return @YES;
    if (status == 404 || status == 410) return @NO;
    return nil;
}

@implementation RVMediaCheck

+ (NSSet *)missingAmong:(NSArray *)urls timeout:(NSTimeInterval)timeout
{
    RVMediaCheckLoad();
    NSMutableSet *missing = [NSMutableSet set];
    NSMutableArray *unknown = [NSMutableArray array];
    @synchronized (g_known) {
        for (NSString *url in urls) {
            NSNumber *known = g_known[RVMediaKey(url)];
            if (!known) [unknown addObject:url];
            else if (![known boolValue]) [missing addObject:url];
        }
    }
    if (!unknown.count) return missing;

    // Side by side on a queue of our own (dispatch_apply would run only as many as the device has cores)
    NSDate *start = [NSDate date];
    dispatch_group_t group = dispatch_group_create();
    for (NSString *url in unknown) {
        dispatch_group_async(group, g_checkQueue, ^{
            NSNumber *present = RVProbe(url);
            if (!present) return;
            @synchronized (g_known) {
                if (g_known.count >= RVMaxKnown) [g_known removeAllObjects];
                g_known[RVMediaKey(url)] = present;
                RVMediaCheckSaveLater();
            }
        });
    }
    long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    @synchronized (g_known) {
        for (NSString *url in unknown) {
            NSNumber *known = g_known[RVMediaKey(url)];
            if (known && ![known boolValue]) [missing addObject:url];
        }
    }
    RVLog(@"media check: %lu new, %lu missing, %.2f s%@", (unsigned long)unknown.count, (unsigned long)missing.count,
          -[start timeIntervalSinceNow], timedOut ? @" (time limit)" : @"");
    return missing;
}

@end
