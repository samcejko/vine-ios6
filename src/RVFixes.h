#import <Foundation/Foundation.h>

// Repairs inside Vine itself, independent of its servers
@interface RVFixes : NSObject

// Vine's AFNetworking builds GET requests that carry parameters as "(null)/timelines/graph?c_max=3..." on iOS 6:
// the base URL goes missing when the query is added. Those requests (the home feed, profiles' posts, every
// timeline) then fail before any protocol sees them. The hook puts the client's base URL back.
+ (void)install;

@end
