#import "RVFixes.h"
#import "RVCommon.h"
#import <objc/runtime.h>

static NSString * const RVNullPrefix = @"(null)/";

static id (*g_origRequestWithMethod)(id, SEL, id, id, id);

static id RVRequestWithMethod(id self, SEL _cmd, id method, id path, id parameters)
{
    id request = g_origRequestWithMethod(self, _cmd, method, path, parameters);
    NSString *built = [[request URL] absoluteString];
    if (![built hasPrefix:RVNullPrefix] || ![request respondsToSelector:@selector(setURL:)]) return request;
    NSURL *base = nil;
    @try { base = [self valueForKey:@"baseURL"]; } @catch (NSException *e) {}
    NSString *baseString = [base absoluteString];
    if (!baseString.length) return request;
    if (![baseString hasSuffix:@"/"]) baseString = [baseString stringByAppendingString:@"/"];
    NSURL *fixed = [NSURL URLWithString:[baseString stringByAppendingString:[built substringFromIndex:RVNullPrefix.length]]];
    if (fixed) [(NSMutableURLRequest *)request setURL:fixed];
    return request;
}

@implementation RVFixes

+ (void)install
{
    Class client = NSClassFromString(@"AFHTTPClient");
    Method m = client ? class_getInstanceMethod(client, @selector(requestWithMethod:path:parameters:)) : NULL;
    if (!m) {
        RVLog(@"AFHTTPClient requestWithMethod:path:parameters: not found");
        return;
    }
    g_origRequestWithMethod = (id (*)(id, SEL, id, id, id))method_setImplementation(m, (IMP)RVRequestWithMethod);
}

@end
