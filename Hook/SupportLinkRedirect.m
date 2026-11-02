#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Only redirect the developer's support mail action.
static NSURL *IKSupportTelegramURL(void) {
    return [NSURL URLWithString:@"https://t.me/ikiraplus"];
}

static BOOL IKIsOriginalSupportMailURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"mailto"]) return NO;
    NSString *value = url.absoluteString.lowercaseString ?: @"";
    return [value containsString:@"dataman@appl"] ||
           [value containsString:@"dataman@"];
}

static BOOL (*IKOriginalOpenURLLegacy)(id, SEL, NSURL *);
static void (*IKOriginalOpenURLModern)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
static void (*IKOriginalPresent)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void (*IKOriginalSetRecipients)(id, SEL, NSArray<NSString *> *);
static char IKSupportRecipientsMarker;

static BOOL IKOpenURLLegacy(id obj, SEL selector, NSURL *url) {
    if (IKIsOriginalSupportMailURL(url)) url = IKSupportTelegramURL();
    return IKOriginalOpenURLLegacy(obj, selector, url);
}

static void IKOpenURLModern(id obj, SEL selector, NSURL *url,
                            NSDictionary *options, void (^completion)(BOOL)) {
    if (IKIsOriginalSupportMailURL(url)) url = IKSupportTelegramURL();
    IKOriginalOpenURLModern(obj, selector, url, options, completion);
}

static void IKSetToRecipients(id obj, SEL selector, NSArray<NSString *> *addresses) {
    BOOL isSupport = NO;
    for (id recipient in addresses) {
        if ([recipient isKindOfClass:[NSString class]] &&
            [[recipient lowercaseString] containsString:@"dataman@appl"]) {
            isSupport = YES;
            break;
        }
    }
    objc_setAssociatedObject(obj, &IKSupportRecipientsMarker,
                             @(isSupport), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IKOriginalSetRecipients(obj, selector, addresses);
}

static void IKPresentController(id obj, SEL selector, UIViewController *controller,
                                BOOL animated, void (^completion)(void)) {
    Class mailClass = NSClassFromString(@"MFMailComposeViewController");
    if (mailClass && [controller isKindOfClass:mailClass] &&
        [objc_getAssociatedObject(controller, &IKSupportRecipientsMarker) boolValue]) {
        [[UIApplication sharedApplication] openURL:IKSupportTelegramURL()
                                          options:@{}
                                completionHandler:nil];
        if (completion) completion();
        return;
    }
    IKOriginalPresent(obj, selector, controller, animated, completion);
}

static void IKSwizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void IKInstallSupportRedirect(void) {
    IKSwizzle([UIApplication class], @selector(openURL:),
              (IMP)IKOpenURLLegacy, (IMP *)&IKOriginalOpenURLLegacy);
    IKSwizzle([UIApplication class], @selector(openURL:options:completionHandler:),
              (IMP)IKOpenURLModern, (IMP *)&IKOriginalOpenURLModern);
    IKSwizzle([UIViewController class], @selector(presentViewController:animated:completion:),
              (IMP)IKPresentController, (IMP *)&IKOriginalPresent);
    Class mailClass = NSClassFromString(@"MFMailComposeViewController");
    if (mailClass) {
        IKSwizzle(mailClass, NSSelectorFromString(@"setToRecipients:"),
                  (IMP)IKSetToRecipients, (IMP *)&IKOriginalSetRecipients);
    }
}
