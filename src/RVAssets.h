#import <Foundation/Foundation.h>

// Images Vine's servers used to serve and nobody serves any more, drawn on the device (PNG data, cached)
@interface RVAssets : NSObject

// The avatar of users without a picture (Vine green with a white figure)
+ (NSData *)defaultAvatarPNG;

// A channel icon: the letter in white on a transparent square (Vine tints it with the channel colour)
+ (NSData *)channelIconPNGForLetter:(NSString *)letter;

@end
