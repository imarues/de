#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdint.h>
#import "IslandBridge.h"

// This hook observes URLSession tasks; it does not change the network request,
// the output filename, the bytes written, the original delegate, or task resume.
// Unlike v1 it considers large DATA tasks, because download managers often
// implement their own storage/resume logic using URLSessionDataTask.
@interface IKDownloadObservation : NSObject
@property (nonatomic, strong) NSURLSessionTask *task;
@property (nonatomic) int32_t activityID;
@property (nonatomic) BOOL started;
@property (nonatomic) int64_t previousBytes;
@property (nonatomic, strong) NSDate *previousTime;
@end
@implementation IKDownloadObservation
@end

static NSMapTable<NSURLSessionTask *, IKDownloadObservation *> *gDownloads;
static NSMutableSet<NSString *> *gHookedClasses;
static NSTimer *gTimer;
static int32_t gNextID = 1000;

static BOOL IKIsUserDownload(NSURLSessionTask *task) {
    if ([task isKindOfClass:[NSURLSessionDownloadTask class]]) return YES;
    if (![task isKindOfClass:[NSURLSessionDataTask class]]) return NO;

    NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)task.response : nil;
    NSString *type = (http.MIMEType ?: @"").lowercaseString;
    NSString *disposition = @"";
    for (NSString *key in http.allHeaderFields) {
        if ([key caseInsensitiveCompare:@"content-disposition"] == NSOrderedSame) {
            disposition = [http.allHeaderFields[key] description].lowercaseString;
            break;
        }
    }
    NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
    NSString *path = url.path.lowercaseString ?: @"";
    NSString *ext = path.pathExtension;
    int64_t expected = task.countOfBytesExpectedToReceive;
    if (expected <= 0) expected = task.response.expectedContentLength;

    BOOL binaryType = [type containsString:@"octet-stream"] ||
                      [type containsString:@"application/zip"] ||
                      [type containsString:@"application/x-apple-diskimage"] ||
                      [type containsString:@"application/vnd.debian.binary-package"];
    BOOL extensionIsFile = [@[@"ipa", @"zip", @"deb", @"dylib", @"7z", @"rar",
                              @"mp4", @"mov", @"pdf", @"apk", @"exe", @"dmg",
                              @"bin", @"pkg"] containsObject:ext];
    BOOL isDLPath = [path hasPrefix:@"/dl/"];
    BOOL hasAttachment = [disposition containsString:@"attachment"];

    // Do not show unrelated ads, thumbnails, JSON, API requests, etc.
    if (expected >= 1024 * 1024 &&
        (isDLPath || extensionIsFile || hasAttachment || binaryType)) return YES;
    // Some servers stream with unknown Content-Length: require a meaningful
    // path/header and at least 1 MB actually received before creating activity.
    if (expected <= 0 && task.countOfBytesReceived >= 1024 * 1024 &&
        (isDLPath || extensionIsFile || hasAttachment)) return YES;
    return NO;
}

static void IKPollDownloads(NSTimer *unused) {
    (void)unused;
    NSArray<NSURLSessionTask *> *tasks = [[gDownloads keyEnumerator] allObjects];
    NSDate *now = [NSDate date];
    for (NSURLSessionTask *task in tasks) {
        IKDownloadObservation *entry = [gDownloads objectForKey:task];
        if (!entry) continue;

        NSURLSessionTaskState state = task.state;
        BOOL finished = (state == NSURLSessionTaskStateCompleted || state == NSURLSessionTaskStateCanceling);
        if (!entry.started && !finished && IKIsUserDownload(task)) {
            NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
            NSString *fileName = task.response.suggestedFilename ?: url.lastPathComponent;
            if (fileName.length == 0) fileName = @"Download";
            entry.activityID = ++gNextID;
            entry.started = YES;
            entry.previousBytes = 0;
            entry.previousTime = now;
            KiraIslandStart(entry.activityID, fileName.UTF8String);
            NSLog(@"[KiraIsland] Live progress started: %@", fileName);
        }
        if (entry.started) {
            int64_t received = MAX((int64_t)0, task.countOfBytesReceived);
            int64_t expected = task.countOfBytesExpectedToReceive;
            if (expected <= 0) expected = task.response.expectedContentLength;
            NSTimeInterval elapsed = [now timeIntervalSinceDate:entry.previousTime];
            double speed = elapsed > 0.0 ?
                MAX(0.0, (double)(received - entry.previousBytes) / elapsed) : 0;
            entry.previousBytes = received;
            entry.previousTime = now;

            if (finished) {
                KiraIslandFinish(entry.activityID,
                                 state == NSURLSessionTaskStateCompleted && task.error == nil,
                                 received, expected);
            } else {
                KiraIslandProgress(entry.activityID, received, expected, speed);
            }
        }
        if (finished) [gDownloads removeObjectForKey:task];
    }
    if (gDownloads.count == 0) {
        [gTimer invalidate];
        gTimer = nil;
    }
}

static void IKRegisterTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionDownloadTask class]] &&
        ![task isKindOfClass:[NSURLSessionDataTask class]]) return;
    void (^add)(void) = ^{
        if (!gDownloads) gDownloads = [NSMapTable strongToStrongObjectsMapTable];
        if ([gDownloads objectForKey:task]) return;
        IKDownloadObservation *obs = [IKDownloadObservation new];
        obs.task = task;
        obs.previousTime = [NSDate date];
        [gDownloads setObject:obs forKey:task];
        if (!gTimer) {
            gTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                IKPollDownloads(t);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
    };
    if ([NSThread isMainThread]) add();
    else dispatch_async(dispatch_get_main_queue(), add);
}

static BOOL IKIsSubclass(Class cls, Class target) {
    for (Class parent = cls; parent != Nil; parent = class_getSuperclass(parent)) {
        if (parent == target) return YES;
    }
    return NO;
}

static void IKInstallDownloadHook(void) {
    if (!gHookedClasses) gHookedClasses = [NSMutableSet set];
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    unsigned installed = 0;
    SEL selector = @selector(resume);
    for (unsigned int i=0; i<n; ++i) {
        Class cls = classes[i];
        if (!IKIsSubclass(cls, [NSURLSessionTask class])) continue;
        NSString *name = NSStringFromClass(cls);
        if ([gHookedClasses containsObject:name]) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j=0; j<methodCount; ++j) {
            Method method = methods[j];
            if (method_getName(method) != selector) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^(id obj) {
                ((void (*)(id, SEL))original)(obj, selector);
                IKRegisterTask((NSURLSessionTask *)obj);
            });
            method_setImplementation(method, replacement);
            [gHookedClasses addObject:name];
            installed++;
            break;
        }
        free(methods);
    }
    free(classes);
    NSLog(@"[KiraIsland] Hooked %u newly loaded URLSessionTask resume methods", installed);
}

__attribute__((constructor)) static void IKLoadNetworkHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        IKInstallDownloadHook();
        // NSURLSession concrete subclasses may be loaded lazily by iOS.
        // Revisit only classes that have not yet been hooked.
        __block int checks = 0;
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
            IKInstallDownloadHook();
            checks++;
            if (checks >= 12) [timer invalidate];
        }];
        // No more 50% diagnostic test. Live Activities are created only
        // when actual tasks with qualifying download responses are observed.
    });
}
