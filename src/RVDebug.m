#import "RVDebug.h"
#import "RVCommon.h"
#import <objc/runtime.h>

static BOOL (*g_origOpenURL)(id, SEL, UIApplication *, NSURL *, NSString *, id);
static BOOL (*g_origHandleOpenURL)(id, SEL, UIApplication *, NSURL *);

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
            RVLog(@"DEBUG %@ = <%@> %@", path, v ? NSStringFromClass([v class]) : @"nil", v);
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

@implementation RVDebug

+ (void)install
{
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
