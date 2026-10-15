#import <Foundation/Foundation.h>

// Vine identifies posts, users and comments by 64-bit numbers; diVine by 64-character hex strings (Nostr event ids
// and public keys). Every hex id handed to the app becomes a number made of its first 15 hex digits (60 bits, always
// positive), and the way back is remembered here. The table is kept on disk too, because Vine stores ids in its
// own database and asks for them again after a restart.
typedef NS_ENUM(char, RVIDKind) {
    RVIDKindPost    = 'p',
    RVIDKindUser    = 'u',
    RVIDKindComment = 'c',
    RVIDKindTag     = 't',   // a hashtag shown as a Vine channel (names, not hex: see idForName:)
};

// The signed-in guest (no diVine account behind it)
extern const long long RVGuestUserID;

@interface RVIDMap : NSObject

// The number for a hex id (registered for the way back)
+ (long long)idForHex:(NSString *)hex kind:(RVIDKind)kind;
+ (NSNumber *)numberForHex:(NSString *)hex kind:(RVIDKind)kind;

// The same for a name (a hashtag): the number is a hash of it, between 10^6 and 2^40
+ (long long)idForName:(NSString *)name kind:(RVIDKind)kind;

// The hex id (or name) behind a number the app sends, nil when it is not known (or of another kind)
+ (NSString *)hexForID:(long long)vineID kind:(RVIDKind)kind;
+ (NSString *)hexForString:(NSString *)vineID kind:(RVIDKind)kind;

// Writes pending changes to disk (also done by itself a few seconds after a change)
+ (void)flush;

@end
