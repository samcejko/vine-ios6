#import <Foundation/Foundation.h>

// diVine's public REST API ("Funnelcake", https://api.divine.video) through the tweak's own TLS stack: the API sits
// behind a CDN that only accepts current ciphers, which iOS 6 does not have. Every call blocks; they run on the
// worker threads of RVURLProtocol.
@interface RVDivine : NSObject

// GET <path> (with its query) -> parsed JSON (dictionary or array). nil and an error when the request failed or
// the answer is not JSON; HTTP errors carry the status as code.
+ (id)get:(NSString *)pathAndQuery error:(NSError **)error;
+ (id)post:(NSString *)path json:(id)object error:(NSError **)error;

// The user records of these public keys (api/users/bulk), pubkey -> record. Records are kept for ten minutes.
+ (NSDictionary *)usersForPubkeys:(NSArray *)pubkeys;
// One user record (api/users/<pubkey>), nil when the user is unknown
+ (NSDictionary *)userForPubkey:(NSString *)pubkey error:(NSError **)error;

// A string as a query value (percent-encoded)
+ (NSString *)escape:(NSString *)string;

@end
