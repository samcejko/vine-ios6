#import <Foundation/Foundation.h>

// What the tweak answers in place of a Vine server
@interface RVVineResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, strong) NSData *body;
@end

// Vine 2.5.1 talks to api.vineapp.com (JSON API), config.vineapp.com (client flags), media.vineapp.com (uploads)
// and vine.co (the Explore page, a web view). Those servers are gone; this class answers the app's requests the way
// they did, with the content of diVine (the Vine archive and new videos). Viewing works without an account: the app
// signs in as a guest, and actions that would need a diVine account (like, comment, follow, post) are refused with a
// message.
@interface RVVineAPI : NSObject

// YES for the hosts answered here
+ (BOOL)handlesHost:(NSString *)host;

// Blocks (diVine is asked over the network); call it from a worker thread
+ (RVVineResponse *)responseForRequest:(NSURLRequest *)request body:(NSData *)body;

@end
