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

BOOL RVDebugLogRequests(void)
{
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = [[NSFileManager defaultManager] fileExistsAtPath:RVSupportPath(@"debug")]; });
    return enabled;
}

NSString *RVText(NSString *key)
{
    // The texts follow the language of the device, not Vine's: Vine has no Czech, and iOS would pick the tweak's
    // language to match the app's
    static NSDictionary *texts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *preferred = [NSLocale preferredLanguages];
        NSString *language = preferred.count ? preferred[0] : @"en";
        NSString *folder = [language hasPrefix:@"cs"] ? @"cs.lproj" : @"en.lproj";
        NSString *path = [[RVSupportDir stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"Revine.strings"];
        NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        texts = RVDict([contents propertyListFromStringsFileFormat]) ?: @{};
    });
    NSString *text = RVStr(texts[key]);
    return text.length ? text : key;
}
