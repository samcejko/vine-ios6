#import "RVIDMap.h"
#import "RVCommon.h"

const long long RVGuestUserID = 1000000000000000001LL;

// Two generations: when the current one is full it becomes the previous one and the oldest ids go. What the app
// still shows was looked up recently and is copied into the current generation again.
static const NSUInteger RVMaxPerGeneration = 20000;

static NSMutableDictionary *g_current;    // @"<number>" -> @"<kind>:<hex>"
static NSMutableDictionary *g_previous;
static BOOL g_dirty;
static BOOL g_saveScheduled;
static dispatch_queue_t g_queue;

static NSString *RVIDMapPath(void)
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    return [caches stringByAppendingPathComponent:@"Revine/ids.plist"];
}

static void RVIDMapLoad(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_queue = dispatch_queue_create("eu.samcejko.revine.ids", DISPATCH_QUEUE_SERIAL);
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:RVIDMapPath()];
        g_current = [RVDict(saved[@"current"]) mutableCopy] ?: [NSMutableDictionary dictionary];
        g_previous = [RVDict(saved[@"previous"]) mutableCopy] ?: [NSMutableDictionary dictionary];
        RVLog(@"id map: %lu + %lu entries", (unsigned long)g_current.count, (unsigned long)g_previous.count);
    });
}

// (called inside @synchronized)
static void RVIDMapScheduleSave(void)
{
    g_dirty = YES;
    if (g_saveScheduled) return;
    g_saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), g_queue, ^{
        [RVIDMap flush];
    });
}

@implementation RVIDMap

+ (long long)idForHex:(NSString *)hex kind:(RVIDKind)kind
{
    if (hex.length < 15) return 0;
    unsigned long long value = strtoull([[hex substringToIndex:15] UTF8String], NULL, 16);
    if (value == 0) return 0;
    [self remember:[hex lowercaseString] forID:(long long)value kind:kind];
    return (long long)value;
}

+ (long long)idForName:(NSString *)name kind:(RVIDKind)kind
{
    if (!name.length) return 0;
    // FNV-1a over the UTF-8 bytes
    const char *bytes = [name UTF8String];
    unsigned long long hash = 1469598103934665603ULL;
    for (const char *p = bytes; *p; p++) {
        hash ^= (unsigned char)*p;
        hash *= 1099511628211ULL;
    }
    long long vineID = 1000000LL + (long long)(hash % ((1ULL << 40) - 1000000ULL));
    [self remember:name forID:vineID kind:kind];
    return vineID;
}

+ (void)remember:(NSString *)value forID:(long long)vineID kind:(RVIDKind)kind
{
    NSString *key = [NSString stringWithFormat:@"%lld", vineID];
    NSString *entry = [NSString stringWithFormat:@"%c:%@", kind, value];
    RVIDMapLoad();
    @synchronized ([RVIDMap class]) {
        if (![g_current[key] isEqualToString:entry]) {
            if (g_current.count >= RVMaxPerGeneration) {
                g_previous = g_current;
                g_current = [NSMutableDictionary dictionary];
            }
            g_current[key] = entry;
            RVIDMapScheduleSave();
        }
    }
}

+ (NSNumber *)numberForHex:(NSString *)hex kind:(RVIDKind)kind
{
    return @([self idForHex:hex kind:kind]);
}

+ (NSString *)hexForID:(long long)vineID kind:(RVIDKind)kind
{
    if (vineID <= 0) return nil;
    NSString *key = [NSString stringWithFormat:@"%lld", vineID];
    RVIDMapLoad();
    NSString *entry;
    @synchronized ([RVIDMap class]) {
        entry = g_current[key];
        if (!entry) {
            entry = g_previous[key];
            if (entry) {
                g_current[key] = entry;   // still in use: keep it when the previous generation goes
                RVIDMapScheduleSave();
            }
        }
    }
    if (entry.length < 3 || [entry characterAtIndex:0] != (unichar)kind) return nil;
    return [entry substringFromIndex:2];
}

+ (NSString *)hexForString:(NSString *)vineID kind:(RVIDKind)kind
{
    return [self hexForID:[vineID longLongValue] kind:kind];
}

+ (void)flush
{
    RVIDMapLoad();
    NSDictionary *snapshot;
    @synchronized ([RVIDMap class]) {
        g_saveScheduled = NO;
        if (!g_dirty) return;
        g_dirty = NO;
        snapshot = @{ @"current": [g_current copy], @"previous": [g_previous copy] };
    }
    NSString *path = RVIDMapPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![snapshot writeToFile:path atomically:YES]) RVLog(@"id map: saving failed");
}

@end
