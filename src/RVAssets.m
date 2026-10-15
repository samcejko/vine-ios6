#import "RVAssets.h"
#import "RVCommon.h"

@implementation RVAssets

+ (NSMutableDictionary *)cache
{
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

// (image contexts may be used off the main thread since iOS 4)
+ (NSData *)cachedPNG:(NSString *)key size:(CGSize)size draw:(void (^)(CGContextRef ctx))draw
{
    @synchronized ([self cache]) {
        NSData *png = [self cache][key];
        if (png) return png;
        UIGraphicsBeginImageContextWithOptions(size, NO, 2.0);
        draw(UIGraphicsGetCurrentContext());
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        png = image ? UIImagePNGRepresentation(image) : nil;
        if (png) [self cache][key] = png;
        return png;
    }
}

+ (NSData *)defaultAvatarPNG
{
    CGSize size = CGSizeMake(100, 100);
    return [self cachedPNG:@"avatar" size:size draw:^(CGContextRef ctx) {
        CGContextSetRGBFillColor(ctx, 0.0, 0.749, 0.561, 1.0);   // #00bf8f
        CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.92);
        CGContextFillEllipseInRect(ctx, CGRectMake(34, 18, 32, 32));            // head
        CGContextFillEllipseInRect(ctx, CGRectMake(18, 56, 64, 64));            // shoulders (cut by the edge)
    }];
}

+ (NSData *)channelIconPNGForLetter:(NSString *)letter
{
    NSString *text = [letter length] ? [[letter substringToIndex:1] uppercaseString] : @"?";
    CGSize size = CGSizeMake(44, 44);
    return [self cachedPNG:[@"icon-" stringByAppendingString:text] size:size draw:^(CGContextRef ctx) {
        [[UIColor whiteColor] set];
        UIFont *font = [UIFont boldSystemFontOfSize:30];
        CGSize textSize = [text sizeWithFont:font];
        [text drawAtPoint:CGPointMake(floorf((size.width - textSize.width) / 2), floorf((size.height - textSize.height) / 2))
                 withFont:font];
    }];
}

@end
