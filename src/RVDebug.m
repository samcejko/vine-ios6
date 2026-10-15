#import "RVDebug.h"
#import "RVCommon.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

// CMTime's layout, without linking CoreMedia
typedef struct { long long value; int timescale; unsigned int flags; long long epoch; } CMTimeLike;

static BOOL (*g_origOpenURL)(id, SEL, UIApplication *, NSURL *, NSString *, id);
static BOOL (*g_origHandleOpenURL)(id, SEL, UIApplication *, NSURL *);
static void RVInspect(NSDictionary *q);

static BOOL RVDebugEnabled(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:RVSupportPath(@"debug")];
}

static NSDictionary *RVDebugQuery(NSString *query)
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *value = [[[pair substringFromIndex:eq.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "]
                           stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        values[[pair substringToIndex:eq.location]] = value ?: @"";
    }
    return values;
}

static UIViewController *RVTopController(void)
{
    UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (YES) {
        if (top.presentedViewController) top = top.presentedViewController;
        else if ([top isKindOfClass:[UINavigationController class]] && [(UINavigationController *)top visibleViewController]) {
            UIViewController *next = [(UINavigationController *)top visibleViewController];
            if (next == top) break;
            top = next;
        } else if ([top isKindOfClass:[UITabBarController class]] && [(UITabBarController *)top selectedViewController]) {
            top = [(UITabBarController *)top selectedViewController];
        } else break;
    }
    return top;
}

static BOOL RVVisible(UIView *v)
{
    for (UIView *p = v; p; p = p.superview) if (p.hidden || p.alpha < 0.01) return NO;
    return YES;
}

static NSString *RVViewText(UIView *v)
{
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        return b.currentTitle ?: b.accessibilityLabel ?: @"";
    }
    if ([v isKindOfClass:[UILabel class]]) return [(UILabel *)v text] ?: @"";
    if ([v isKindOfClass:[UITextField class]]) {
        UITextField *f = (UITextField *)v;
        return [NSString stringWithFormat:@"%@ [%@]", f.text ?: @"", f.placeholder ?: @""];
    }
    if ([v isKindOfClass:[UITableViewCell class]]) return [(UITableViewCell *)v textLabel].text ?: @"";
    return v.accessibilityLabel ?: @"";
}

static void RVDumpView(UIView *v, UIWindow *w, NSMutableArray *lines)
{
    if (lines.count > 220 || v.hidden || v.alpha < 0.01) return;
    BOOL interesting = [v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UILabel class]] ||
                       [v isKindOfClass:[UITableViewCell class]] || v.gestureRecognizers.count > 0;
    if (interesting) {
        CGRect r = [v convertRect:v.bounds toView:w];
        if (CGRectIntersectsRect(r, w.bounds) && r.size.width > 1 && r.size.height > 1) {
            NSString *text = RVViewText(v);
            if (text.length > 60) text = [[text substringToIndex:60] stringByAppendingString:@"..."];
            [lines addObject:[NSString stringWithFormat:@"%@ (%.0f,%.0f %.0fx%.0f)%@ %@", NSStringFromClass([v class]),
                              r.origin.x, r.origin.y, r.size.width, r.size.height,
                              v.gestureRecognizers.count ? @" G" : @"", text]];
        }
    }
    for (UIView *sub in v.subviews) RVDumpView(sub, w, lines);
}

// Fires the single-tap recognizers of a view through UIKit's private target list
// (UIGestureRecognizer._targets of UIGestureRecognizerTarget {_target, _action})
static BOOL RVFireTapRecognizers(UIView *v)
{
    BOOL fired = NO;
    Ivar targetsIvar = class_getInstanceVariable([UIGestureRecognizer class], "_targets");
    if (!targetsIvar) return NO;
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
        if (![gr isKindOfClass:[UITapGestureRecognizer class]] || !gr.enabled) continue;
        if ([(UITapGestureRecognizer *)gr numberOfTapsRequired] != 1) continue;
        NSArray *targets = object_getIvar(gr, targetsIvar);
        for (id entry in targets) {
            Ivar tIvar = class_getInstanceVariable([entry class], "_target");
            Ivar aIvar = class_getInstanceVariable([entry class], "_action");
            if (!tIvar || !aIvar) continue;
            id target = object_getIvar(entry, tIvar);
            SEL action = *(SEL *)((char *)(__bridge void *)entry + ivar_getOffset(aIvar));
            if (!target || !action || ![target respondsToSelector:action]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [target performSelector:action withObject:gr];
#pragma clang diagnostic pop
            fired = YES;
        }
    }
    return fired;
}

// A tap on this view or the nearest one above it that reacts: tap recognizer, control, table row
static NSString *RVActivate(UIView *hit)
{
    for (UIView *v = hit; v; v = v.superview) {
        if (RVFireTapRecognizers(v)) return [@"tap recognizer of " stringByAppendingString:NSStringFromClass([v class])];
        if ([v isKindOfClass:[UIControl class]]) {
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            return [@"control " stringByAppendingString:NSStringFromClass([v class])];
        }
        if ([v isKindOfClass:[UITableViewCell class]]) {
            UITableViewCell *cell = (UITableViewCell *)v;
            UITableView *table = nil;
            for (UIView *p = cell.superview; p && !table; p = p.superview) if ([p isKindOfClass:[UITableView class]]) table = (UITableView *)p;
            NSIndexPath *ip = table ? [table indexPathForCell:cell] : nil;
            if (table && ip && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [table.delegate tableView:table didSelectRowAtIndexPath:ip];
                return [NSString stringWithFormat:@"row %ld/%ld", (long)ip.section, (long)ip.row];
            }
        }
    }
    return @"nothing";
}

static UIView *RVFindWithText(UIView *root, NSString *text)
{
    if (root.hidden || root.alpha < 0.01) return nil;
    for (UIView *sub in [root.subviews reverseObjectEnumerator]) {   // (front-most first)
        UIView *found = RVFindWithText(sub, text);
        if (found) return found;
    }
    NSString *own = RVViewText(root);
    if (own.length && [own rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return root;
    return nil;
}

static void RVCollect(UIView *root, Class cls, NSMutableArray *found)
{
    if (root.hidden || root.alpha < 0.01) return;
    if ([root isKindOfClass:cls]) [found addObject:root];
    for (UIView *sub in root.subviews) RVCollect(sub, cls, found);
}

static void RVWriteSnapshot(void)
{
    CGSize size = [UIScreen mainScreen].bounds.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, w.center.x, w.center.y);
        CGContextConcatCTM(ctx, w.transform);
        CGContextTranslateCTM(ctx, -w.bounds.size.width * w.layer.anchorPoint.x, -w.bounds.size.height * w.layer.anchorPoint.y);
        [w.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *png = UIImagePNGRepresentation(img);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
    [png writeToFile:path atomically:YES];
    RVLog(@"DEBUG snapshot -> %@ (%lu bytes)", path, (unsigned long)png.length);
}

// Every AVPlayerLayer on screen: is its player playing, where, which file
static void RVLogPlayers(CALayer *layer, UIWindow *w, NSInteger *found)
{
    if ([layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
        (*found)++;
        id player = [layer valueForKey:@"player"];
        id item = [player valueForKey:@"currentItem"];
        id asset = [item valueForKey:@"asset"];
        NSURL *assetURL = [asset respondsToSelector:@selector(URL)] ? [asset valueForKey:@"URL"] : nil;
        float rate = player ? [[player valueForKey:@"rate"] floatValue] : 0;
        double now = 0;
        if (item) {
            NSValue *t = [item valueForKey:@"currentTime"];
            CMTimeLike time;
            [t getValue:&time];
            now = time.timescale ? (double)time.value / time.timescale : 0;
        }
        CGRect r = [layer convertRect:layer.bounds toLayer:w.layer];
        RVLog(@"DEBUG player (%.0f,%.0f %.0fx%.0f) rate %.1f time %.2f status %@ %@", r.origin.x, r.origin.y, r.size.width, r.size.height,
              rate, now, [item valueForKey:@"status"], assetURL.lastPathComponent);
    }
    for (CALayer *sub in layer.sublayers) RVLogPlayers(sub, w, found);
}

// What is really on the screen, video included (UIKit's private UIGetScreenImage, looked up at run time)
static void RVWriteScreen(void)
{
    CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    if (!grab) { RVLog(@"DEBUG screen: no UIGetScreenImage"); return; }
    CGImageRef cg = grab();
    if (!cg) { RVLog(@"DEBUG screen: no image"); return; }
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    NSData *png = UIImagePNGRepresentation(img);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
    [png writeToFile:path atomically:YES];
    RVLog(@"DEBUG screen -> %@ (%lu bytes)", path, (unsigned long)png.length);
}

static void RVHandleDebug(NSURL *url)
{
    NSString *command = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSDictionary *q = RVDebugQuery(url.query);
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    UIViewController *top = RVTopController();

    if ([command isEqualToString:@"dump"]) {
        RVLog(@"DEBUG top %@ (root %@)", NSStringFromClass([top class]), NSStringFromClass([key.rootViewController class]));
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden) continue;
            NSMutableArray *lines = [NSMutableArray array];
            RVDumpView(w, w, lines);
            RVLog(@"DEBUG window %@ level %.0f: %lu views", NSStringFromClass([w class]), w.windowLevel, (unsigned long)lines.count);
            for (NSString *line in lines) RVLog(@"DEBUG  %@", line);
        }
    } else if ([command isEqualToString:@"snapshot"]) {
        RVWriteSnapshot();
    } else if ([command isEqualToString:@"screen"]) {
        RVWriteScreen();
    } else if ([command isEqualToString:@"players"]) {
        NSInteger found = 0;
        for (UIWindow *w in [UIApplication sharedApplication].windows) RVLogPlayers(w.layer, w, &found);
        RVLog(@"DEBUG players: %ld", (long)found);
    } else if ([command isEqualToString:@"press"]) {
        CGPoint pt = CGPointMake([q[@"x"] floatValue], [q[@"y"] floatValue]);
        UIView *hit = [key hitTest:pt withEvent:nil];
        RVLog(@"DEBUG press (%.0f,%.0f) on %@ -> %@", pt.x, pt.y, NSStringFromClass([hit class]), RVActivate(hit));
    } else if ([command isEqualToString:@"tap"]) {
        NSString *text = q[@"text"] ?: @"";
        UIView *found = nil;
        for (UIWindow *w in [[UIApplication sharedApplication].windows reverseObjectEnumerator]) {
            if (w.hidden) continue;
            found = RVFindWithText(w, text);
            if (found) break;
        }
        RVLog(@"DEBUG tap '%@' on %@ -> %@", text, found ? NSStringFromClass([found class]) : @"(not found)", found ? RVActivate(found) : @"nothing");
    } else if ([command isEqualToString:@"type"]) {
        NSMutableArray *fields = [NSMutableArray array];
        RVCollect(key, [UITextField class], fields);
        NSInteger n = [q[@"n"] integerValue];
        UITextField *field = n >= 0 && n < (NSInteger)fields.count ? fields[(NSUInteger)n] : nil;
        if (field) {
            [field becomeFirstResponder];
            field.text = q[@"text"] ?: @"";
            [field sendActionsForControlEvents:UIControlEventEditingChanged];
            [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:field];
            if ([q[@"submit"] boolValue] && [field.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                [field.delegate textFieldShouldReturn:field];
            }
        }
        RVLog(@"DEBUG type -> field %ld of %lu %@", (long)n, (unsigned long)fields.count, field ? @"set" : @"missing");
    } else if ([command isEqualToString:@"alert"]) {
        UIAlertView *alert = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSMutableArray *found = [NSMutableArray array];
            RVCollect(w, [UIAlertView class], found);
            if (found.count) { alert = found[0]; break; }
        }
        if (alert) {
            NSInteger index = q[@"n"] ? [q[@"n"] integerValue] : alert.cancelButtonIndex;
            if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:index];
            [alert dismissWithClickedButtonIndex:index animated:YES];
        }
        RVLog(@"DEBUG alert -> %@ / %@", alert ? alert.title : @"none", alert ? alert.message : @"");
    } else if ([command isEqualToString:@"back"]) {
        [top.navigationController popViewControllerAnimated:YES];
        RVLog(@"DEBUG back from %@", NSStringFromClass([top class]));
    } else if ([command isEqualToString:@"close"]) {
        UIViewController *root = key.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        RVLog(@"DEBUG close %@", NSStringFromClass([root class]));
    } else if ([command isEqualToString:@"inspect"]) {
        RVInspect(q);
    } else {
        RVLog(@"DEBUG unknown command %@", command);
    }
}

// The ivars of an object (objects by class and a short description, numbers by value)
static void RVLogIvars(id object, Class cls)
{
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
            NSString *value;
            if (type && type[0] == '@') {
                id v = object_getIvar(object, ivars[i]);
                NSString *d = [v description] ?: @"nil";
                if (d.length > 300) d = [[d substringToIndex:300] stringByAppendingString:@"..."];
                value = v ? [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([v class]), d] : @"nil";
            } else if (type && (type[0] == 'c' || type[0] == 'B' || type[0] == 'C')) {
                value = [NSString stringWithFormat:@"%d", (int)*((char *)(__bridge void *)object + ivar_getOffset(ivars[i]))];
            } else if (type && (type[0] == 'i' || type[0] == 'I' || type[0] == 'l' || type[0] == 'L')) {
                value = [NSString stringWithFormat:@"%d", *(int *)((char *)(__bridge void *)object + ivar_getOffset(ivars[i]))];
            } else {
                value = [NSString stringWithFormat:@"(%s)", type ?: "?"];
            }
            RVLog(@"DEBUG  %@.%@ = %@", NSStringFromClass(c), name, value);
        }
        free(ivars);
    }
}

// inspect?class=X[&sel=sharedInstance]: X's class methods, and the ivars of the object its shared-instance method
// returns
static void RVInspect(NSDictionary *q)
{
    Class cls = NSClassFromString(q[@"class"] ?: @"");
    if (!cls) { RVLog(@"DEBUG inspect: no class %@", q[@"class"]); return; }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    NSMutableArray *names = [NSMutableArray array];
    SEL shared = q[@"sel"] ? NSSelectorFromString(q[@"sel"]) : NULL;
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        [names addObject:name];
        if (!shared && [name rangeOfString:@"shared" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            [name rangeOfString:@":"].location == NSNotFound) shared = sel;
    }
    free(methods);
    RVLog(@"DEBUG class methods of %@: %@", NSStringFromClass(cls), [names componentsJoinedByString:@" "]);
    if (q[@"methods"]) {
        Method *im = class_copyMethodList(cls, &count);
        NSMutableArray *inames = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) [inames addObject:NSStringFromSelector(method_getName(im[i]))];
        free(im);
        RVLog(@"DEBUG instance methods of %@: %@", NSStringFromClass(cls), [inames componentsJoinedByString:@" "]);
    }
    if (!shared || ![cls respondsToSelector:shared]) { RVLog(@"DEBUG inspect: no shared instance method"); return; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id instance = [cls performSelector:shared];
#pragma clang diagnostic pop
    RVLog(@"DEBUG +%@ -> %@", NSStringFromSelector(shared), instance ? NSStringFromClass([instance class]) : @"nil");
    if (instance) RVLogIvars(instance, [instance class]);
    NSString *path = q[@"path"];   // a key path to follow from there (e.g. client.baseURL)
    if (instance && path.length) {
        @try {
            id v = [instance valueForKeyPath:path];
            NSString *d = [v description] ?: @"nil";
            if (q[@"full"]) {
                // (long values in pieces: syslog cuts long lines)
                for (NSUInteger i = 0; i < d.length; i += 400) {
                    RVLog(@"DEBUG %@ [%lu] %@", path, (unsigned long)i, [d substringWithRange:NSMakeRange(i, MIN((NSUInteger)400, d.length - i))]);
                }
            }
            RVLog(@"DEBUG %@ = <%@> %@", path, v ? NSStringFromClass([v class]) : @"nil", d.length > 300 ? [d substringToIndex:300] : d);
            if (v && q[@"deep"]) RVLogIvars(v, [v class]);
        } @catch (NSException *e) {
            RVLog(@"DEBUG %@: %@", path, e.reason);
        }
    }
}

static BOOL RVIsDebugURL(NSURL *url)
{
    return [[url.scheme lowercaseString] isEqualToString:@"vine"] && [[url.host lowercaseString] isEqualToString:@"revine"];
}

static BOOL RVOpenURL(id self, SEL _cmd, UIApplication *app, NSURL *url, NSString *source, id annotation)
{
    if (RVIsDebugURL(url)) {
        if (RVDebugEnabled()) RVHandleDebug(url);
        return YES;
    }
    return g_origOpenURL ? g_origOpenURL(self, _cmd, app, url, source, annotation) : NO;
}

static BOOL RVHandleOpenURL(id self, SEL _cmd, UIApplication *app, NSURL *url)
{
    if (RVIsDebugURL(url)) {
        if (RVDebugEnabled()) RVHandleDebug(url);
        return YES;
    }
    return g_origHandleOpenURL ? g_origHandleOpenURL(self, _cmd, app, url) : NO;
}

// Which client and base URL Vine picks per endpoint (test mode only)
static id (*g_origClientForEndpoint)(id, SEL, id);
static id RVClientForEndpoint(id self, SEL _cmd, id endpoint)
{
    id client = g_origClientForEndpoint(self, _cmd, endpoint);
    id base = nil;
    @try { base = [client valueForKey:@"baseURL"]; } @catch (NSException *e) {}
    RVLog(@"DEBUG clientForEndpoint %@ -> %@ base %@", endpoint, NSStringFromClass([client class]), base);
    if ([[base description] hasPrefix:@"(null)"]) RVLog(@"DEBUG stack %@", [NSThread callStackSymbols]);
    return client;
}

// What -[VNAPIManager modifyRequest:] does to a request (test mode only; its signature is logged at load)
static void *(*g_origModifyRequest)(id, SEL, id);
static void *RVModifyRequest(id self, SEL _cmd, id request)
{
    NSString *before = [[request URL] absoluteString];
    void *result = g_origModifyRequest(self, _cmd, request);
    RVLog(@"DEBUG modifyRequest %@ -> %@", before, [[request URL] absoluteString]);
    return result;
}

static NSString *RVOneLine(id value)
{
    NSString *d = [value description] ?: @"nil";
    d = [d stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([d rangeOfString:@"  "].location != NSNotFound) d = [d stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return d;
}

static id (*g_origRequestWithMethod)(id, SEL, id, id, id);
static id RVRequestWithMethod(id self, SEL _cmd, id method, id path, id parameters)
{
    id request = g_origRequestWithMethod(self, _cmd, method, path, parameters);
    NSString *result = [[request URL] absoluteString];
    if ([result hasPrefix:@"(null)"]) {
        id base = nil;
        @try { base = [self valueForKey:@"baseURL"]; } @catch (NSException *e) {}
        NSMutableArray *types = [NSMutableArray array];
        if ([parameters isKindOfClass:[NSDictionary class]]) {
            for (id key in parameters) [types addObject:[NSString stringWithFormat:@"%@:%@", key, NSStringFromClass([parameters[key] class])]];
        }
        RVLog(@"DEBUG AF %@ path=%@ params=%@ types=%@ base=%@ -> %@", method, path, RVOneLine(parameters),
              [types componentsJoinedByString:@","], base, result);
    }
    return request;
}

// The Objective-C method of the main executable an address falls in (Vine's binary has no symbols, but its
// classes are in the runtime)
static NSString *RVMethodForAddress(uintptr_t address)
{
    const char *image = _dyld_get_image_name(0);
    unsigned int classCount = 0;
    const char **names = objc_copyClassNamesForImage(image, &classCount);
    NSString *best = nil;
    uintptr_t bestAddress = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = objc_getClass(names[i]);
        for (int meta = 0; meta < 2 && cls; meta++) {
            Class c = meta ? object_getClass(cls) : cls;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(c, &count);
            for (unsigned int m = 0; m < count; m++) {
                uintptr_t a = (uintptr_t)method_getImplementation(methods[m]) & ~(uintptr_t)1;
                if (a <= address && a > bestAddress) {
                    bestAddress = a;
                    best = [NSString stringWithFormat:@"%c[%s %@]", meta ? '+' : '-', names[i], NSStringFromSelector(method_getName(methods[m]))];
                }
            }
            free(methods);
        }
    }
    free(names);
    return best ? [NSString stringWithFormat:@"%@ + %lu", best, (unsigned long)(address - bestAddress)] : @"?";
}

static NSUncaughtExceptionHandler *g_previousHandler;
static void RVUncaught(NSException *exception)
{
    RVLog(@"DEBUG uncaught %@: %@", exception.name, exception.reason);
    const struct mach_header *header = _dyld_get_image_header(0);
    uintptr_t start = (uintptr_t)header;
    for (NSNumber *n in exception.callStackReturnAddresses) {
        uintptr_t a = (uintptr_t)[n unsignedLongValue];
        Dl_info info;
        if (dladdr((void *)a, &info) && info.dli_fbase == header) {
            RVLog(@"DEBUG   0x%lx (+0x%lx) %@", (unsigned long)a, (unsigned long)(a - start), RVMethodForAddress(a));
        } else if (dladdr((void *)a, &info)) {
            RVLog(@"DEBUG   0x%lx %s %s", (unsigned long)a, info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?", info.dli_sname ?: "");
        }
    }
    if (g_previousHandler) g_previousHandler(exception);
}

static void RVLogStack(NSArray *addresses)
{
    const struct mach_header *header = _dyld_get_image_header(0);
    uintptr_t start = (uintptr_t)header;
    for (NSNumber *n in addresses) {
        uintptr_t a = (uintptr_t)[n unsignedLongValue];
        Dl_info info;
        if (dladdr((void *)a, &info) && info.dli_fbase == header) {
            RVLog(@"DEBUG   0x%lx (+0x%lx) %@", (unsigned long)a, (unsigned long)(a - start), RVMethodForAddress(a));
        } else if (dladdr((void *)a, &info)) {
            RVLog(@"DEBUG   0x%lx %s %s", (unsigned long)a, info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?", info.dli_sname ?: "");
        }
    }
}

// A subdataWithRange: past the end: who asked (the exception that follows has no readable stack)
static id (*g_origSubdata)(id, SEL, NSRange);
static id RVSubdata(id self, SEL _cmd, NSRange range)
{
    if (NSMaxRange(range) > [(NSData *)self length]) {
        RVLog(@"DEBUG subdataWithRange {%lu, %lu} of %lu bytes, from:", (unsigned long)range.location, (unsigned long)range.length,
              (unsigned long)[(NSData *)self length]);
        RVLogStack([NSThread callStackReturnAddresses]);
        NSData *head = [(NSData *)self subdataWithRange:NSMakeRange(0, MIN((NSUInteger)64, [(NSData *)self length]))];
        RVLog(@"DEBUG   data starts %@", head);
    }
    return g_origSubdata(self, _cmd, range);
}

@implementation RVDebug

+ (void)install
{
    if (RVDebugLogRequests()) {
        Class data = NSClassFromString(@"NSConcreteMutableData");
        Method sub = data ? class_getInstanceMethod(data, @selector(subdataWithRange:)) : NULL;
        if (sub) g_origSubdata = (id (*)(id, SEL, NSRange))method_setImplementation(sub, (IMP)RVSubdata);
    }
    if (RVDebugLogRequests()) {
        // (after Crashlytics has set its own handler at launch: ours goes first and passes on)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            g_previousHandler = NSGetUncaughtExceptionHandler();
            NSSetUncaughtExceptionHandler(&RVUncaught);
        });
    }
    if (RVDebugLogRequests()) {
        Class af = NSClassFromString(@"AFHTTPClient");
        Method m = af ? class_getInstanceMethod(af, @selector(requestWithMethod:path:parameters:)) : NULL;
        if (m) g_origRequestWithMethod = (id (*)(id, SEL, id, id, id))method_setImplementation(m, (IMP)RVRequestWithMethod);
    }
    if (RVDebugLogRequests()) {
        Class manager = NSClassFromString(@"VNAPIManager");
        Method m = manager ? class_getInstanceMethod(manager, @selector(clientForEndpoint:)) : NULL;
        if (m) g_origClientForEndpoint = (id (*)(id, SEL, id))method_setImplementation(m, (IMP)RVClientForEndpoint);
        Method modify = manager ? class_getInstanceMethod(manager, NSSelectorFromString(@"modifyRequest:")) : NULL;
        if (modify) {
            RVLog(@"DEBUG modifyRequest: types %s", method_getTypeEncoding(modify));
            g_origModifyRequest = (void *(*)(id, SEL, id))method_setImplementation(modify, (IMP)RVModifyRequest);
        }
        Method headers = manager ? class_getInstanceMethod(manager, NSSelectorFromString(@"addHeadersToRequest:")) : NULL;
        if (headers) RVLog(@"DEBUG addHeadersToRequest: types %s", method_getTypeEncoding(headers));
    }
    Class delegate = NSClassFromString(@"VNAppDelegate");
    if (!delegate) {
        RVLog(@"debug: no VNAppDelegate");
        return;
    }
    SEL openSel = @selector(application:openURL:sourceApplication:annotation:);
    Method open = class_getInstanceMethod(delegate, openSel);
    if (open) g_origOpenURL = (BOOL (*)(id, SEL, UIApplication *, NSURL *, NSString *, id))method_setImplementation(open, (IMP)RVOpenURL);
    else class_addMethod(delegate, openSel, (IMP)RVOpenURL, "c@:@@@@");
    SEL handleSel = @selector(application:handleOpenURL:);
    Method handle = class_getInstanceMethod(delegate, handleSel);
    if (handle) g_origHandleOpenURL = (BOOL (*)(id, SEL, UIApplication *, NSURL *))method_setImplementation(handle, (IMP)RVHandleOpenURL);
}

@end
