#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdint.h>
#import "IslandBridge.h"

// Runtime hook: observe URLSession download tasks without modifying DataManager UI.
// Ordinary URLSession data tasks (including advertising/network API traffic) are ignored.
@interface IKDownloadObservation : NSObject
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic) int32_t activityID;
@property (nonatomic) int64_t previousBytes;
@property (nonatomic, strong) NSDate *previousTime;
@end
@implementation IKDownloadObservation
@end

static NSMapTable<NSURLSessionDownloadTask *, IKDownloadObservation *> *gDownloads;
static NSTimer *gTimer;
static int32_t gNextID = 1000;

static void IKPollDownloads(NSTimer *timer) {
    (void)timer;
    NSArray<NSURLSessionDownloadTask *> *tasks = [[gDownloads keyEnumerator] allObjects];
    NSDate *now = [NSDate date];
    for (NSURLSessionDownloadTask *task in tasks) {
        IKDownloadObservation *item = [gDownloads objectForKey:task];
        if (!item) continue;
        int64_t received = MAX((int64_t)0, task.countOfBytesReceived);
        int64_t expected = task.countOfBytesExpectedToReceive;
        NSTimeInterval elapsed = [now timeIntervalSinceDate:item.previousTime];
        double speed = elapsed > 0.0 ? MAX(0.0, (double)(received - item.previousBytes) / elapsed) : 0.0;
        item.previousBytes = received;
        item.previousTime = now;
        KiraIslandProgress(item.activityID, received, expected, speed);
        NSURLSessionTaskState state = task.state;
        if (state == NSURLSessionTaskStateCompleted || state == NSURLSessionTaskStateCanceling) {
            KiraIslandFinish(item.activityID, state == NSURLSessionTaskStateCompleted && task.error == nil,
                             received, expected);
            [gDownloads removeObjectForKey:task];
        }
    }
    if (gDownloads.count == 0) {
        [gTimer invalidate];
        gTimer = nil;
    }
}

static void IKRegisterDownload(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionDownloadTask class]]) return;
    void (^add)(void) = ^{
        NSURLSessionDownloadTask *download = (NSURLSessionDownloadTask *)task;
        if (!gDownloads) gDownloads = [NSMapTable strongToStrongObjectsMapTable];
        if ([gDownloads objectForKey:download]) return;
        NSURL *url = download.currentRequest.URL ?: download.originalRequest.URL;
        NSString *name = download.response.suggestedFilename ?: url.lastPathComponent;
        if (name.length == 0) name = @"Download";
        IKDownloadObservation *obs = [IKDownloadObservation new];
        obs.task = download;
        obs.activityID = ++gNextID;
        obs.previousTime = [NSDate date];
        obs.previousBytes = 0;
        [gDownloads setObject:obs forKey:download];
        KiraIslandStart(obs.activityID, name.UTF8String);
        if (!gTimer) {
            gTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                IKPollDownloads(t);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
        }
        NSLog(@"[KiraIsland] Tracking NSURLSession download: %@", name);
    };
    if ([NSThread isMainThread]) add();
    else dispatch_async(dispatch_get_main_queue(), add);
}

static BOOL IKIsSubclass(Class candidate, Class parent) {
    for (Class c = candidate; c != Nil; c = class_getSuperclass(c)) {
        if (c == parent) return YES;
    }
    return NO;
}

static void IKInstallDownloadHook(void) {
    unsigned int classesCount = 0;
    Class *classes = objc_copyClassList(&classesCount);
    unsigned int installed = 0;
    SEL resumeSelector = @selector(resume);
    for (unsigned int i=0; i<classesCount; i++) {
        Class cls = classes[i];
        if (!IKIsSubclass(cls, [NSURLSessionTask class])) continue;
        unsigned int methodsCount = 0;
        Method *methods = class_copyMethodList(cls, &methodsCount);
        for (unsigned int j=0; j<methodsCount; j++) {
            Method method = methods[j];
            if (method_getName(method) != resumeSelector) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^(id obj) {
                ((void (*)(id, SEL))original)(obj, resumeSelector);
                IKRegisterDownload(obj);
            });
            method_setImplementation(method, replacement);
            installed++;
            break;
        }
        free(methods);
    }
    free(classes);
    NSLog(@"[KiraIsland] Hook installed for %u URLSessionTask resume implementations", installed);
}

__attribute__((constructor)) static void IKLoadNetworkHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ IKInstallDownloadHook(); });
}
