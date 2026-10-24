// NativeDownloadRouter.m
// Optional download handler for standalone Gecko shell.
// Intercepts only HTTPS direct .tipa/.ipa links handed to UIApplication.openURL.
// All other links keep the system's original behavior.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*OriginalOpenURL)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = NULL;

static BOOL IsInstallableDownloadURL(NSURL *url) {
    if (url == nil || ![[url.scheme lowercaseString] isEqualToString:@"https"]) {
        return NO;
    }
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"ipa", @"tipa"] containsObject:ext];
}

static UIViewController *TopPresenter(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow != nil) break;
    }

    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController != nil) {
        top = top.presentedViewController;
    }
    return top;
}

static void ShowDownloadError(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = TopPresenter();
        if (!presenter) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"下载失败"
                             message:message ?: @"请用 Safari 打开链接重试。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void PresentDownloadShare(NSURL *fileURL) {
    UIViewController *presenter = TopPresenter();
    if (!presenter) return;

    UIAlertController *finished = [UIAlertController
        alertControllerWithTitle:@"下载完成"
                         message:[NSString stringWithFormat:
                             @"文件已保存到 ChatGPT Gecko 的 Downloads 文件夹：\\n%@\\n\\n可以通过分享菜单保存到「文件」或交给 TrollStore 安装。",
                             fileURL.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [finished addAction:[UIAlertAction actionWithTitle:@"稍后"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
    [finished addAction:[UIAlertAction actionWithTitle:@"分享 / 保存到文件"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
        UIViewController *top = TopPresenter();
        if (!top) return;
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[fileURL] applicationActivities:nil];
        UIPopoverPresentationController *pop = share.popoverPresentationController;
        if (pop) {
            pop.sourceView = top.view;
            pop.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds),
                                        CGRectGetMidY(top.view.bounds), 1, 1);
            pop.permittedArrowDirections = 0;
        }
        [top presentViewController:share animated:YES completion:nil];
    }]];
    [presenter presentViewController:finished animated:YES completion:nil];
}

static void DownloadInstallableFile(NSURL *url) {
    NSString *fileName = url.lastPathComponent ?: @"app.tipa";
    // URL.pathComponent is decoded by Foundation. Avoid unexpected filenames.
    fileName = [fileName lastPathComponent];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = TopPresenter();
        if (!presenter) {
            ShowDownloadError(@"当前页面无法启动下载，请用 Safari 下载。");
            return;
        }

        UIAlertController *working = [UIAlertController
            alertControllerWithTitle:@"正在下载"
                             message:[NSString stringWithFormat:@"%@\\n下载后可保存到「文件」。", fileName]
                      preferredStyle:UIAlertControllerStyleAlert];

        __block NSTimer *progressTimer = nil;
        __block BOOL cancelled = NO;
        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
            downloadTaskWithURL:url
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSError *saveError = error;
            NSInteger status = [(NSHTTPURLResponse *)response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 200;
            if (!saveError && status >= 400) {
                saveError = [NSError errorWithDomain:@"ChatGPTGeckoDownload"
                                               code:status
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)status]}];
            }

            NSURL *savedURL = nil;
            if (!saveError && location != nil) {
                NSFileManager *fm = NSFileManager.defaultManager;
                NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
                NSURL *downloads = [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
                if (![fm createDirectoryAtURL:downloads
                  withIntermediateDirectories:YES attributes:nil error:&saveError]) {
                    // saveError provides the explanation.
                } else {
                    NSURL *destination = [downloads URLByAppendingPathComponent:fileName];
                    if ([fm fileExistsAtPath:destination.path]) {
                        NSString *stem = [fileName stringByDeletingPathExtension];
                        NSString *suffix = fileName.pathExtension;
                        NSString *uniqueName = [NSString stringWithFormat:@"%@-%@.%@",
                            stem, [[NSUUID UUID].UUIDString substringToIndex:8], suffix];
                        destination = [downloads URLByAppendingPathComponent:uniqueName];
                    }
                    if ([fm moveItemAtURL:location toURL:destination error:&saveError]) {
                        savedURL = destination;
                    }
                }
            }

            NSURL *result = savedURL;
            NSError *failure = saveError;
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressTimer invalidate];
                progressTimer = nil;
                if (cancelled) return;
                [working dismissViewControllerAnimated:YES completion:^{
                    if (result) PresentDownloadShare(result);
                    else ShowDownloadError(failure.localizedDescription ?: @"请用 Safari 下载。");
                }];
            });
        }];
        [working addAction:[UIAlertAction actionWithTitle:@"取消下载"
                                                  style:UIAlertActionStyleCancel
                                                handler:^(__unused UIAlertAction *action) {
            cancelled = YES;
            [progressTimer invalidate];
            progressTimer = nil;
            [task cancel];
        }]];
        [presenter presentViewController:working animated:YES completion:^{
            [task resume];
            // NSURLSessionDownloadTask continuously exposes actual transferred
            // bytes. Only display a percentage when Content-Length is known.
            progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                repeats:YES block:^(__unused NSTimer *tick) {
                int64_t received = task.countOfBytesReceived;
                int64_t expected = task.countOfBytesExpectedToReceive;
                NSString *now = [NSByteCountFormatter
                    stringFromByteCount:received countStyle:NSByteCountFormatterCountStyleFile];
                if (expected > 0) {
                    NSString *total = [NSByteCountFormatter
                        stringFromByteCount:expected countStyle:NSByteCountFormatterCountStyleFile];
                    NSInteger percent = MIN(100, MAX(0, (NSInteger)((100.0 * received) / expected)));
                    working.message = [NSString stringWithFormat:
                        @"%@\n已下载 %@ / %@（%ld%%）",
                        fileName, now, total, (long)percent];
                } else {
                    working.message = [NSString stringWithFormat:
                        @"%@\n已下载 %@（文件总大小未知）", fileName, now];
                }
            }];
        }];
    });
}

static void ChatGPTGeckoOpenURL(id application, SEL selector,
                                NSURL *url, NSDictionary *options,
                                void (^completion)(BOOL)) {
    if (IsInstallableDownloadURL(url)) {
        DownloadInstallableFile(url);
        if (completion) completion(YES);
        return;
    }
    if (OriginalOpenURL) OriginalOpenURL(application, selector, url, options, completion);
    else if (completion) completion(NO);
}


// MARK: - Share / Save for EVERY completed Gecko download
//
// Unlike the direct UIApplication.openURL handler above, Gecko's own
// DownloadStore handles HTTP downloads (including authenticated files,
// Content-Disposition, attachment responses, and Blob downloads) and
// writes an atomic JSON manifest at Application Support/AppData/DownloadStore.
// Its "DownloadStore.DidChange" notification fires on the main queue, after
// completion has been persisted. Observe completed entries, *not* clicks or
// navigations, so regular web links remain regular web links.

static NSMutableSet<NSString *> *gKnownDownloadIDs = nil;
static NSMutableArray<NSURL *> *gShareQueue = nil;
static BOOL gSharePromptActive = NO;
static UIView *gDownloadBanner = nil;
static UILabel *gDownloadBannerLabel = nil;
static UIActivityIndicatorView *gDownloadBannerSpinner = nil;
static BOOL gDownloadOfferRetryScheduled = NO;
static NSString *const kKnownDownloadIDsKey = @"ChatGPTGecko.SeenCompletedDownloadIDsV1";

static NSURL *GeckoManifestURL(void) {
    NSURL *support = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"AppData" isDirectory:YES]
            URLByAppendingPathComponent:@"DownloadStore" isDirectory:NO];
}

static NSURL *GeckoDownloadsURL(void) {
    NSURL *documents = [NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
}

static NSArray<NSDictionary *> *AllGeckoDownloadEntries(void) {
    NSURL *manifest = GeckoManifestURL();
    if (!manifest) return @[];
    NSData *data = [NSData dataWithContentsOfURL:manifest];
    if (!data.length) return @[];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![parsed isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if (![entry[@"id"] isKindOfClass:[NSString class]]) continue;
        if (![entry[@"relativePath"] isKindOfClass:[NSString class]]) continue;
        [result addObject:entry];
    }
    return result;
}

static NSArray<NSDictionary *> *CompletedGeckoDownloadEntries(void) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *entry in AllGeckoDownloadEntries()) {
        id state = entry[@"state"];
        // Reynard's legacy records omit state and its model treats them
        // as completed. Never offer failed/paused/active files.
        if (!state || ([state isKindOfClass:[NSString class]] &&
                       [state isEqualToString:@"completed"])) {
            [result addObject:entry];
        }
    }
    return result;
}

static NSArray<NSDictionary *> *ActiveGeckoDownloadEntries(void) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *entry in AllGeckoDownloadEntries()) {
        if ([entry[@"state"] isKindOfClass:[NSString class]] &&
            [entry[@"state"] isEqualToString:@"active"]) {
            [result addObject:entry];
        }
    }
    return result;
}

static void PersistKnownDownloadIDs(void) {
    if (!gKnownDownloadIDs) return;
    // DownloadStore itself contains the historical records, so there is no
    // need to retain an unbounded second manifest in UserDefaults.
    NSArray<NSString *> *all = gKnownDownloadIDs.allObjects;
    if (all.count > 2000) {
        all = [all subarrayWithRange:NSMakeRange(all.count - 2000, 2000)];
    }
    [NSUserDefaults.standardUserDefaults setObject:all forKey:kKnownDownloadIDsKey];
}

static NSURL *VerifiedDownloadedFile(NSDictionary *entry) {
    NSString *relativePath = entry[@"relativePath"];
    if (![relativePath isKindOfClass:[NSString class]] ||
        relativePath.length == 0 ||
        ![relativePath isEqualToString:relativePath.lastPathComponent] ||
        [relativePath isEqualToString:@"."] ||
        [relativePath isEqualToString:@".."]) {
        return nil;
    }
    NSURL *directory = GeckoDownloadsURL();
    NSURL *url = [directory URLByAppendingPathComponent:relativePath isDirectory:NO];
    NSDictionary *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL];
    if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) return nil;
    return url;
}


// Exposed to the dedicated ChatGPT floating downloads button.
// This is only a count of active downloads; the original Reynard
// downloads screen supplies true progress, sizes, speed and controls.
NSUInteger ChatGPTGeckoActiveDownloadCount(void) {
    return ActiveGeckoDownloadEntries().count;
}

static void OfferNextGeckoDownload(void);

static void FinishGeckoDownloadOffer(void) {
    gSharePromptActive = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        OfferNextGeckoDownload();
    });
}

static void OfferNextGeckoDownload(void) {
    if (gSharePromptActive || gShareQueue.count == 0) return;
    UIViewController *presenter = TopPresenter();
    // Do not interrupt a login dialog, a permission prompt, a share sheet,
    // or another modal. Let the pending offers surface afterward.
    UIWindow *window = presenter.view.window;
    if (!presenter || !window ||
        [presenter isKindOfClass:[UIAlertController class]] ||
        [presenter isKindOfClass:[UIActivityViewController class]]) {
        if (!gDownloadOfferRetryScheduled) {
            gDownloadOfferRetryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                gDownloadOfferRetryScheduled = NO;
                OfferNextGeckoDownload();
            });
        }
        return;
    }

    NSURL *file = gShareQueue.firstObject;
    [gShareQueue removeObjectAtIndex:0];
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) {
        OfferNextGeckoDownload();
        return;
    }
    gSharePromptActive = YES;

    UIAlertController *prompt = [UIAlertController
        alertControllerWithTitle:@"下载完成"
                         message:[NSString stringWithFormat:
                            @"%@\n文件已保存在应用的 Downloads 文件夹。",
                            file.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];

    [prompt addAction:[UIAlertAction
        actionWithTitle:@"稍后"
                 style:UIAlertActionStyleCancel
               handler:^(__unused UIAlertAction *action) {
        FinishGeckoDownloadOffer();
    }]];

    [prompt addAction:[UIAlertAction
        actionWithTitle:@"分享 / 保存到文件"
                 style:UIAlertActionStyleDefault
               handler:^(__unused UIAlertAction *action) {
        UIViewController *top = TopPresenter();
        if (!top) {
            FinishGeckoDownloadOffer();
            return;
        }
        UIActivityViewController *sheet =
            [[UIActivityViewController alloc] initWithActivityItems:@[file]
                                             applicationActivities:nil];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        if (popover) {
            popover.sourceView = top.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds),
                                             CGRectGetMidY(top.view.bounds), 1, 1);
            popover.permittedArrowDirections = 0;
        }
        sheet.completionWithItemsHandler =
            ^(__unused UIActivityType activityType,
              __unused BOOL completed,
              __unused NSArray *returnedItems,
              __unused NSError *error) {
            FinishGeckoDownloadOffer();
        };
        [top presentViewController:sheet animated:YES completion:nil];
    }]];

    [presenter presentViewController:prompt animated:YES completion:nil];
}

static void CheckCompletedGeckoDownloads(void) {
    NSArray<NSDictionary *> *entries = CompletedGeckoDownloadEntries();
    if (!gKnownDownloadIDs) gKnownDownloadIDs = [NSMutableSet set];
    if (!gShareQueue) gShareQueue = [NSMutableArray array];
    BOOL changed = NO;
    for (NSDictionary *entry in entries) {
        NSString *downloadID = entry[@"id"];
        if ([gKnownDownloadIDs containsObject:downloadID]) continue;

        NSURL *fileURL = VerifiedDownloadedFile(entry);
        // Do not mark a completed entry seen if the file hasn't appeared.
        if (!fileURL) continue;

        [gKnownDownloadIDs addObject:downloadID];
        changed = YES;
        [gShareQueue addObject:fileURL];
    }
    if (changed) PersistKnownDownloadIDs();
    OfferNextGeckoDownload();
}

static void StartGeckoDownloadObserver(void) {
    gKnownDownloadIDs = [NSMutableSet set];
    gShareQueue = [NSMutableArray array];

    // Seed pre-existing downloads (and those seen in previous launches) so
    // upgrading this app does not prompt for old files all over again.
    NSArray *previousIDs = [NSUserDefaults.standardUserDefaults
        arrayForKey:kKnownDownloadIDsKey];
    for (id previous in previousIDs) {
        if ([previous isKindOfClass:[NSString class]])
            [gKnownDownloadIDs addObject:previous];
    }
    for (NSDictionary *existing in CompletedGeckoDownloadEntries()) {
        [gKnownDownloadIDs addObject:existing[@"id"]];
    }
    PersistKnownDownloadIDs();

    [NSNotificationCenter.defaultCenter
        addObserverForName:@"DownloadStore.DidChange"
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        CheckCompletedGeckoDownloads();
    }];

    [NSNotificationCenter.defaultCenter
        addObserverForName:@"DownloadStore.DidStartDownload"
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
    }];

    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        CheckCompletedGeckoDownloads();
    }];
}

__attribute__((constructor))
static void InstallDownloadRouter(void) {
    @autoreleasepool {
        StartGeckoDownloadObserver();
        Method m = class_getInstanceMethod([UIApplication class],
                        @selector(openURL:options:completionHandler:));
        if (m) {
            OriginalOpenURL = (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))
                method_getImplementation(m);
            method_setImplementation(m, (IMP)ChatGPTGeckoOpenURL);
        }
    }
}
