#import <Foundation/Foundation.h>

@class RVTLSSocket;

// Idle keep-alive connections, keyed by "scheme://host:port". Sockets are handed out most recently
// used first, checked for liveness, and dropped after an idle timeout.
@interface RVConnectionPool : NSObject

+ (instancetype)shared;

- (RVTLSSocket *)checkoutSocketForKey:(NSString *)key;      // nil when nothing usable is idle
- (void)checkinSocket:(RVTLSSocket *)socket forKey:(NSString *)key;
- (void)drain;                                              // closes every idle connection (memory warning, background)

@property (nonatomic, readonly) NSUInteger idleCount;
@property (nonatomic, readonly) NSUInteger reuseCount;      // statistics: sockets handed out since launch

@end
