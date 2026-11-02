#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdint.h>
#import "IslandBridge.h"

// Does not change requests, stored data, delegate callbacks or existing
// download logic. Observes NSURLSession delegate callbacks to identify
// user-visible transfers and pass their actual byte counts to ActivityKit.
@interface IKTaskObservation : NSObject
@property(nonatomic,strong) NSURLSessionTask *task;
@property(nonatomic) int32_t activityID;
@property(nonatomic) BOOL running;
@property(nonatomic) int64_t lastBytes;
@property(nonatomic,strong) NSDate *lastDate;
@end
@implementation IKTaskObservation
@end

static NSMapTable<NSURLSessionTask *, IKTaskObservation *> *gTasks;
static NSMutableSet<NSString *> *gInstalled;
static NSTimer *gPollingTimer;
static int32_t gNextID = 1000;

static BOOL IKIsValidDownload(NSURLSessionTask *task, int64_t bytes) {
    if ([task isKindOfClass:[NSURLSessionDownloadTask class]]) {
        return bytes >= 1024 * 1024;
    }
    NSHTTPURLResponse *response = [task.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)task.response : nil;
    if (!response) return NO;
    NSString *mime = response.MIMEType.lowercaseString ?: @"";
    NSString *disposition = @"";
    for (id key in response.allHeaderFields) {
        if ([[key description] caseInsensitiveCompare:@"content-disposition"] == NSOrderedSame) {
            disposition = [response.allHeaderFields[key] description].lowercaseString;
            break;
        }
    }
    NSString *path = (task.currentRequest.URL ?: task.originalRequest.URL).path.lowercaseString ?: @"";
    NSString *ext = path.pathExtension;
    BOOL knownExtension = [@[@"ipa", @"zip", @"dylib", @"deb", @"7z", @"rar", @"pdf",
                             @"mp4", @"mov", @"apk", @"exe", @"dmg", @"pkg", @"bin"]
                           containsObject:ext];
    BOOL binaryType = [mime containsString:@"octet-stream"] ||
                      [mime containsString:@"application/zip"] ||
                      [mime containsString:@"application/pdf"] ||
                      [mime containsString:@"application/x-debian"] ||
                      [mime containsString:@"application/vnd.debian"];
    BOOL attachment = [disposition containsString:@"attachment"];
    // Require actual downloaded bytes to suppress advertising/API traffic.
    return bytes >= 1024 * 1024 &&
           (knownExtension || [path hasPrefix:@"/dl/"] || binaryType || attachment);
}

static IKTaskObservation *IKGetOrCreate(NSURLSessionTask *task) {
    if (!gTasks) gTasks = [NSMapTable strongToStrongObjectsMapTable];
    IKTaskObservation *item = [gTasks objectForKey:task];
    if (!item) {
        item = [IKTaskObservation new];
        item.task = task;
        item.lastDate = [NSDate date];
        [gTasks setObject:item forKey:task];
    }
    return item;
}

static void IKUpdate(NSURLSessionTask *task, int64_t received, int64_t expected, BOOL ended, BOOL success) {
    if (!task) return;
    IKTaskObservation *item = IKGetOrCreate(task);
    received = MAX(0, received);
    if (expected <= 0) expected = task.response.expectedContentLength;
    if (expected <= 0) expected = task.countOfBytesExpectedToReceive;
    NSDate *now = [NSDate date];

    if (!item.running && !ended && IKIsValidDownload(task, received)) {
        NSURL *url = task.currentRequest.URL ?: task.originalRequest.URL;
        NSString *name = task.response.suggestedFilename ?: url.lastPathComponent;
        if (!name.length) name = @"Download";
        item.activityID = ++gNextID;
        item.running = YES;
        item.lastBytes = 0;
        item.lastDate = now;
        KiraIslandStart(item.activityID, name.UTF8String);
        NSLog(@"[KiraIsland] START %@ received=%lld expected=%lld", name, received, expected);
    }

    if (!item.running) {
        if (ended) [gTasks removeObjectForKey:task];
        return;
    }

    NSTimeInterval dt = [now timeIntervalSinceDate:item.lastDate];
    double speed = dt > 0 ? MAX(0.0, (double)(received - item.lastBytes) / dt) : 0;
    item.lastBytes = received;
    item.lastDate = now;
    if (ended) {
        KiraIslandFinish(item.activityID, success, received, expected);
        [gTasks removeObjectForKey:task];
        NSLog(@"[KiraIsland] END id=%d success=%d", item.activityID, (int)success);
    } else {
        KiraIslandProgress(item.activityID, received, expected, speed);
    }
}

// Delegate callback hook may execute on a URLSession background delegate queue.
// Funnel all dictionary and ActivityKit state operations through the main queue.
static void IKObserveTask(NSURLSessionTask *task, int64_t received, int64_t expected,
                          BOOL ended, BOOL success) {
    if (!task) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        IKUpdate(task, received, expected, ended, success);
    });
}

static void IKPoll(NSTimer *timer) {
    (void)timer;
    NSArray<NSURLSessionTask *> *all = [[gTasks keyEnumerator] allObjects];
    for (NSURLSessionTask *task in all) {
        NSURLSessionTaskState state = task.state;
        BOOL finished = state == NSURLSessionTaskStateCompleted ||
                        state == NSURLSessionTaskStateCanceling;
        IKUpdate(task, task.countOfBytesReceived, task.countOfBytesExpectedToReceive,
                 finished, finished && task.error == nil &&
                 state == NSURLSessionTaskStateCompleted);
    }
    if (gTasks.count == 0 && gPollingTimer) {
        [gPollingTimer invalidate];
        gPollingTimer = nil;
    }
}

static void IKRegisterTask(NSURLSessionTask *task) {
    if (!task) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        IKGetOrCreate(task);
        if (!gPollingTimer) {
            gPollingTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                IKPoll(timer);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gPollingTimer forMode:NSRunLoopCommonModes];
        }
    });
}

static BOOL IKSubclassOf(Class cls, Class root) {
    while (cls) { if (cls == root) return YES; cls = class_getSuperclass(cls); }
    return NO;
}

// Install a method hook only for methods implemented directly by that class.
// Subclasses inheriting a method automatically use their superclass hook.
static BOOL IKInstall(Class cls, SEL selector, id block, NSString *identifier) {
    if ([gInstalled containsObject:identifier]) return NO;
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned j = 0; j < count; j++) {
        if (method_getName(methods[j]) == selector) { found = methods[j]; break; }
    }
    free(methods);
    if (!found) return NO;
    IMP imp = imp_implementationWithBlock(block);
    method_setImplementation(found, imp);
    [gInstalled addObject:identifier];
    return YES;
}

static void IKInstallHooks(void) {
    if (!gInstalled) gInstalled = [NSMutableSet new];
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned hooks = 0;

    SEL resume = @selector(resume);
    SEL write = @selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:);
    SEL data = @selector(URLSession:dataTask:didReceiveData:);
    SEL finish = @selector(URLSession:downloadTask:didFinishDownloadingToURL:);
    SEL complete = @selector(URLSession:task:didCompleteWithError:);

    for (unsigned i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (IKSubclassOf(cls, [NSURLSessionTask class])) {
            // Use the original implementation, then observe the resumed task.
            Method method = class_getInstanceMethod(cls, resume);
            IMP original = method ? method_getImplementation(method) : NULL;
            if (original) {
                id block = ^(NSURLSessionTask *task) {
                    ((void (*)(id, SEL))original)(task, resume);
                    IKRegisterTask(task);
                };
                if (IKInstall(cls, resume, block, [name stringByAppendingString:@":resume"])) hooks++;
            }
        }
        // These are actual user download progress callbacks (not guessed).
        Method writeMethod = class_getInstanceMethod(cls, write);
        IMP writeOriginal = writeMethod ? method_getImplementation(writeMethod) : NULL;
        if (writeOriginal) {
            id block = ^(id self, NSURLSession *session, NSURLSessionDownloadTask *task,
                         int64_t bytes, int64_t total, int64_t expected) {
                ((void (*)(id,SEL,id,id,int64_t,int64_t,int64_t))writeOriginal)(
                    self, write, session, task, bytes, total, expected);
                IKRegisterTask(task);
                IKObserveTask(task, total, expected, NO, NO);
            };
            if (IKInstall(cls, write, block, [name stringByAppendingString:@":didWriteData"])) hooks++;
        }
        Method dataMethod = class_getInstanceMethod(cls, data);
        IMP dataOriginal = dataMethod ? method_getImplementation(dataMethod) : NULL;
        if (dataOriginal) {
            id block = ^(id self, NSURLSession *session, NSURLSessionDataTask *task, NSData *chunk) {
                ((void (*)(id,SEL,id,id,id))dataOriginal)(self, data, session, task, chunk);
                IKRegisterTask(task);
                IKObserveTask(task, task.countOfBytesReceived, task.countOfBytesExpectedToReceive, NO, NO);
            };
            if (IKInstall(cls, data, block, [name stringByAppendingString:@":didReceiveData"])) hooks++;
        }
        Method finishMethod = class_getInstanceMethod(cls, finish);
        IMP finishOriginal = finishMethod ? method_getImplementation(finishMethod) : NULL;
        if (finishOriginal) {
            id block = ^(id self, NSURLSession *session, NSURLSessionDownloadTask *task, NSURL *location) {
                ((void (*)(id,SEL,id,id,id))finishOriginal)(self, finish, session, task, location);
                IKObserveTask(task, task.countOfBytesReceived, task.countOfBytesExpectedToReceive, YES, YES);
            };
            if (IKInstall(cls, finish, block, [name stringByAppendingString:@":didFinish"])) hooks++;
        }
        Method completeMethod = class_getInstanceMethod(cls, complete);
        IMP completeOriginal = completeMethod ? method_getImplementation(completeMethod) : NULL;
        if (completeOriginal) {
            id block = ^(id self, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
                ((void (*)(id,SEL,id,id,id))completeOriginal)(self, complete, session, task, error);
                IKObserveTask(task, task.countOfBytesReceived, task.countOfBytesExpectedToReceive,
                              YES, error == nil);
            };
            if (IKInstall(cls, complete, block, [name stringByAppendingString:@":didComplete"])) hooks++;
        }
    }
    free(classes);
    if (hooks > 0) NSLog(@"[KiraIsland] Runtime hooks installed: %u", hooks);
}

__attribute__((constructor)) static void IKLoadNetworkHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        IKInstallHooks();
        // System creates concrete URLSession classes lazily. Scan for newly
        // registered classes during the first minutes of normal app usage.
        __block unsigned attempts = 0;
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            IKInstallHooks();
            if (++attempts >= 90) [timer invalidate];
        }];
        // Deliberately no automatic fake 50% test.
    });
}
