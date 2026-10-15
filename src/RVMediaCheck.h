#import <Foundation/Foundation.h>

// Some archived Vines have no video on diVine's media server (it answers 404) and Vine would spin on them for ever.
// A request for the first byte of the file tells; the answers are kept on disk, so a post is checked once.
@interface RVMediaCheck : NSObject

// The URLs among these that are known to be missing. URLs not known yet are checked side by side first, waiting
// at most `timeout` seconds in all; those that do not answer in time (or fail on the network) count as present.
+ (NSSet *)missingAmong:(NSArray *)urls timeout:(NSTimeInterval)timeout;

@end
