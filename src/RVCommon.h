// Shared macros and helpers of the Revine tweak. Everything here must be iOS 6.0 safe: the tweak runs inside the
// Vine 2.5.1 app on iOS 6.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define RVVersion @"0.1.0"
#define RVLog(fmt, ...) NSLog((@"[Revine] " fmt), ##__VA_ARGS__)
#define L(key) RVText(key)

extern NSString * const RVErrorDomain;

// NSError codes in RVErrorDomain (HTTP errors use the HTTP status as code)
enum {
    RVErrorNetwork        = -1,
    RVErrorTLS            = -2,
    RVErrorCertificate    = -3,
    RVErrorTimeout        = -4,
    RVErrorCancelled      = -5,
    RVErrorBadResponse    = -6,
    RVErrorDNS            = -7,
    RVErrorConnect        = -8,
    RVErrorConnectionLost = -9,
};

NSError *RVMakeError(NSInteger code, NSString *message);

// JSON values as the type the caller expects, nil/0 for anything else (NSNull, wrong type)
NSString *RVStr(id value);         // numbers become their decimal string
NSDictionary *RVDict(id value);
NSArray *RVArr(id value);
long long RVLong(id value);
double RVDbl(id value);

// The tweak's own files: /Library/Application Support/Revine/<name> (CA bundle, translations)
NSString *RVSupportPath(NSString *name);
// A text in the language of the device (English or Czech), from the support folder
NSString *RVText(NSString *key);

// Test mode (the root-owned file /Library/Application Support/Revine/debug, checked once at launch): every request
// of the app goes to the log
BOOL RVDebugLogRequests(void);
