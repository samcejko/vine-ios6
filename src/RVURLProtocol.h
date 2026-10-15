#import <Foundation/Foundation.h>

// Takes the requests Vine makes with NSURLConnection (its API client, image and video downloads, the Explore web
// view) to hosts the tweak answers:
//   - Vine's own hosts -> RVVineAPI (JSON made from diVine's content, generated images and pages),
//   - diVine's media server, and other hosts wrapped in a media.vineapp.com/revine/proxy URL -> fetched through the
//     tweak's TLS stack (iOS 6 cannot connect to them itself) and streamed to the app as they arrive.
@interface RVURLProtocol : NSURLProtocol

+ (void)registerProtocol;

// A URL the app can load for any http(s) address: through the tweak's TLS stack
+ (NSString *)proxyURLForURL:(NSString *)url;

@end
