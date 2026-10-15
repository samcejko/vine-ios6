#import "RVConnectionPool.h"
#import "RVTLSSocket.h"
#import "RVCommon.h"

static const NSTimeInterval RVIdleTimeout = 25;     // most servers drop idle connections after 5 to 60 s
static const NSUInteger RVMaxIdlePerKey = 6;
static const NSUInteger RVMaxIdleTotal = 24;

@interface RVPooledConnection : NSObject
@property (nonatomic, strong) RVTLSSocket *socket;
@property (nonatomic) NSTimeInterval lastUsed;
@end

@implementation RVPooledConnection
@end

@implementation RVConnectionPool {
    NSMutableDictionary *_idle;     // key -> NSMutableArray<RVPooledConnection>
    NSUInteger _count;
    NSUInteger _reuses;
}

+ (instancetype)shared
{
    static RVConnectionPool *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [[RVConnectionPool alloc] init]; });
    return pool;
}

- (instancetype)init
{
    self = [super init];
    if (self) _idle = [NSMutableDictionary dictionary];
    return self;
}

// Must be called with the lock held. Moves expired connections into `dead`.
- (void)pruneLocked:(NSMutableArray *)dead
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *emptyKeys = [NSMutableArray array];
    for (NSString *key in _idle) {
        NSMutableArray *list = _idle[key];
        for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
            RVPooledConnection *c = list[(NSUInteger)i];
            if (now - c.lastUsed > RVIdleTimeout) {
                [dead addObject:c.socket];
                [list removeObjectAtIndex:(NSUInteger)i];
                _count--;
            }
        }
        if (!list.count) [emptyKeys addObject:key];
    }
    [_idle removeObjectsForKeys:emptyKeys];
}

- (RVTLSSocket *)checkoutSocketForKey:(NSString *)key
{
    if (!key) return nil;
    NSMutableArray *dead = [NSMutableArray array];
    RVTLSSocket *result = nil;
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        while (list.count && !result) {
            RVPooledConnection *c = [list lastObject];
            [list removeLastObject];
            _count--;
            if ([c.socket isLikelyAlive]) result = c.socket;
            else [dead addObject:c.socket];
        }
        if (result) _reuses++;
    }
    for (RVTLSSocket *s in dead) [s close];
    return result;
}

- (void)checkinSocket:(RVTLSSocket *)socket forKey:(NSString *)key
{
    if (!socket || !key) return;
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        if (!list) {
            list = [NSMutableArray array];
            _idle[key] = list;
        }
        if (list.count >= RVMaxIdlePerKey || _count >= RVMaxIdleTotal) {
            [dead addObject:socket];
        } else {
            RVPooledConnection *c = [[RVPooledConnection alloc] init];
            c.socket = socket;
            c.lastUsed = [NSDate timeIntervalSinceReferenceDate];
            [list addObject:c];
            _count++;
        }
    }
    for (RVTLSSocket *s in dead) [s close];
}

- (void)drain
{
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        for (NSString *key in _idle) {
            for (RVPooledConnection *c in _idle[key]) [dead addObject:c.socket];
        }
        [_idle removeAllObjects];
        _count = 0;
    }
    for (RVTLSSocket *s in dead) [s close];
    if (dead.count) RVLog(@"Connection pool drained (%lu closed)", (unsigned long)dead.count);
}

- (NSUInteger)idleCount
{
    @synchronized (self) { return _count; }
}

- (NSUInteger)reuseCount
{
    @synchronized (self) { return _reuses; }
}

@end
