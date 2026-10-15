#import "RVDivine.h"
#import "RVHTTPRequest.h"
#import "RVCommon.h"

static NSString * const RVDivineBase = @"https://api.divine.video";
static const NSTimeInterval RVUserCacheSeconds = 600;

@implementation RVDivine

+ (id)request:(NSString *)method path:(NSString *)path body:(NSData *)body error:(NSError **)error
{
    NSURL *url = [NSURL URLWithString:[RVDivineBase stringByAppendingString:path]];
    if (!url) {
        if (error) *error = RVMakeError(RVErrorBadResponse, [NSString stringWithFormat:@"Bad path %@", path]);
        return nil;
    }
    RVHTTPRequest *request = [[RVHTTPRequest alloc] initWithMethod:method URL:url];
    NSMutableDictionary *headers = [@{ @"Accept": @"application/json" } mutableCopy];
    if (body) headers[@"Content-Type"] = @"application/json";
    request.headers = headers;
    request.body = body;
    request.connectTimeout = 15;
    request.readTimeout = 30;
    __block NSError *failure = nil;
    request.onComplete = ^(NSError *err) { failure = err; };
    NSDate *start = [NSDate date];
    [request runSynchronously];
    NSTimeInterval took = -[start timeIntervalSinceNow];
    if (failure) {
        RVLog(@"%@ %@ failed after %.2f s: %@", method, path, took, failure.localizedDescription);
        if (error) *error = failure;
        return nil;
    }
    NSData *data = request.responseBody;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (request.statusCode >= 400) {
        NSString *message = RVStr(RVDict(json)[@"error"]) ?: [NSString stringWithFormat:@"HTTP %ld", (long)request.statusCode];
        RVLog(@"%@ %@ -> %ld (%.2f s): %@", method, path, (long)request.statusCode, took, message);
        if (error) *error = RVMakeError(request.statusCode, message);
        return nil;
    }
    if (!json) {
        RVLog(@"%@ %@: not JSON (%lu bytes)", method, path, (unsigned long)data.length);
        if (error) *error = RVMakeError(RVErrorBadResponse, @"The answer of diVine was not JSON");
        return nil;
    }
    if (took > 2) RVLog(@"%@ %@ took %.2f s", method, path, took);
    return json;
}

+ (id)get:(NSString *)pathAndQuery error:(NSError **)error
{
    return [self request:@"GET" path:pathAndQuery body:nil error:error];
}

+ (id)post:(NSString *)path json:(id)object error:(NSError **)error
{
    NSData *body = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] : nil;
    return [self request:@"POST" path:path body:body ?: [NSData data] error:error];
}

#pragma mark - User records

+ (NSMutableDictionary *)userCache
{
    static NSMutableDictionary *cache;   // pubkey -> @[record, NSDate]
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (NSDictionary *)cachedUser:(NSString *)pubkey
{
    @synchronized ([self userCache]) {
        NSArray *entry = [self userCache][pubkey];
        if (entry && -[(NSDate *)entry[1] timeIntervalSinceNow] < RVUserCacheSeconds) return entry[0];
    }
    return nil;
}

+ (void)cacheUser:(NSDictionary *)record
{
    NSString *pubkey = RVStr(record[@"pubkey"]);
    if (!pubkey.length) return;
    @synchronized ([self userCache]) {
        NSMutableDictionary *cache = [self userCache];
        if (cache.count > 2000) [cache removeAllObjects];
        cache[pubkey] = @[record, [NSDate date]];
    }
}

+ (NSDictionary *)usersForPubkeys:(NSArray *)pubkeys
{
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *pubkey in pubkeys) {
        if (![pubkey isKindOfClass:[NSString class]] || !pubkey.length || found[pubkey]) continue;
        NSDictionary *record = [self cachedUser:pubkey];
        if (record) found[pubkey] = record;
        else if (![missing containsObject:pubkey]) [missing addObject:pubkey];
    }
    for (NSUInteger i = 0; i < missing.count; i += 100) {
        NSArray *chunk = [missing subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)100, missing.count - i))];
        NSDictionary *answer = RVDict([self post:@"/api/users/bulk" json:@{ @"pubkeys": chunk } error:NULL]);
        for (NSDictionary *record in RVArr(answer[@"users"])) {
            if (![record isKindOfClass:[NSDictionary class]]) continue;
            [self cacheUser:record];
            NSString *pubkey = RVStr(record[@"pubkey"]);
            if (pubkey) found[pubkey] = record;
        }
    }
    return found;
}

+ (NSDictionary *)userForPubkey:(NSString *)pubkey error:(NSError **)error
{
    if (!pubkey.length) return nil;
    NSDictionary *record = [self cachedUser:pubkey];
    if (record) return record;
    record = RVDict([self get:[@"/api/users/" stringByAppendingString:pubkey] error:error]);
    if (record) [self cacheUser:record];
    return record;
}

+ (NSString *)escape:(NSString *)string
{
    if (!string) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)string, NULL,
                                                                  CFSTR(":/?#[]@!$&'()*+,;= \"%<>{}|\\^`"), kCFStringEncodingUTF8);
    return CFBridgingRelease(escaped);
}

@end
