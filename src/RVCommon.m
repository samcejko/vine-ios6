#import "RVCommon.h"

NSString * const RVErrorDomain = @"eu.samcejko.revine";

static NSString * const RVSupportDir = @"/Library/Application Support/Revine";

NSError *RVMakeError(NSInteger code, NSString *message)
{
    if (!message) message = @"Unknown error";
    return [NSError errorWithDomain:RVErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

NSString *RVStr(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

NSDictionary *RVDict(id value)
{
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSArray *RVArr(id value)
{
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

long long RVLong(id value)
{
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return [value longLongValue];
    return 0;
}

double RVDbl(id value)
{
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return [value doubleValue];
    return 0;
}

NSString *RVSupportPath(NSString *name)
{
    return [RVSupportDir stringByAppendingPathComponent:name];
}

NSString *RVText(NSString *key)
{
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // (a plain folder with en.lproj and cs.lproj inside works as a bundle for its translations)
        bundle = [NSBundle bundleWithPath:RVSupportDir];
    });
    NSString *text = [bundle localizedStringForKey:key value:nil table:@"Revine"];
    return text.length ? text : key;
}
