#import <Foundation/Foundation.h>

// Repairs inside Vine itself, independent of its servers
@interface RVFixes : NSObject

// The VineRedirect tweak (bag.xml.vineredirect) replaces "https://api.vineapp.com" in every +[NSURL URLWithString:]
// with the address set in its preferences, "(null)" when none is set. AFNetworking builds GET requests that carry
// parameters with +URLWithString:, so the home feed, profiles' posts and every timeline turn into
// "(null)/timelines/graph?c_max=3..." and fail before any protocol sees them. The hook puts the client's base URL
// back.
+ (void)install;

@end
