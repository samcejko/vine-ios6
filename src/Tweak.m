// Revine: loaded into Vine 2.5.1 (bundle id com.vine.iphone, see Revine.plist). Everything the app asks its old
// servers for is answered by RVURLProtocol from diVine's content.
#import "RVURLProtocol.h"
#import "RVTLSSocket.h"
#import "RVIDMap.h"
#import "RVCommon.h"

__attribute__((constructor)) static void RVInit(void)
{
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.vine.iphone"]) return;
        [RVURLProtocol registerProtocol];
        [RVTLSSocket warmUp];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                           queue:nil usingBlock:^(NSNotification *note) {
            [RVIDMap flush];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil
                                                           queue:nil usingBlock:^(NSNotification *note) {
            [RVIDMap flush];
        }];
        RVLog(@"Revine %@ loaded into Vine %@", RVVersion,
              [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]);
    }
}
