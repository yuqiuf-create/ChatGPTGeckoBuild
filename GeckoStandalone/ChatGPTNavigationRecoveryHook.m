// ChatGPTStandaloneHook.m
// User-requested dedicated ChatGPT shell around the Gecko-powered Reynard runtime.
// This file is part of a GPL-3.0 compatible local modification.
// It does not intercept ChatGPT credentials or network requests.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*OriginalViewDidAppear)(id, SEL, BOOL) = NULL;
static NSString *const kStartupDone = @"ChatGPTStandalone.InitialOpenV1";

static UIView *FindView(UIView *root, NSString *shortClass);


// The download UI is implemented in a separate native module, shared by
// ChatGPT, Claude and Gemini shells. It is draggable and opens the native
// Reynard download manager for real-time progress.
extern void ChatGPTInstallFloatingDownloads(UIViewController *controller);


static UIView *FindView(UIView *root, NSString *shortClass) {
    if (root == nil) return nil;
    NSString *name = NSStringFromClass([root class]);
    if ([[name componentsSeparatedByString:@"."] lastObject] &&
        [[[name componentsSeparatedByString:@"."] lastObject] isEqualToString:shortClass]) {
        return root;
    }
    for (UIView *child in root.subviews) {
        UIView *found = FindView(child, shortClass);
        if (found) return found;
    }
    return nil;
}

// ChatGPT-only iOS 15 page-layout repair.
// Keep BrowserChrome alive so Gecko's UI and overlay lifecycle still works;
// only suppress its lower address/navigation bar. Do NOT constrain
// ContentView to new required anchors: Reynard already owns those anchors.
static void ApplyChatChrome(UIViewController *controller) {
    if (!controller.isViewLoaded) return;
    UIView *chrome = FindView(controller.view, @"BrowserChrome");
    if (!chrome) return;
    UIView *bottom = FindView(chrome, @"BottomToolbar");
    if (!bottom) return;

    // Reynard's BottomToolbar lays its topAnchor 94 pt above the
    // BrowserChrome safe-area bottom. The page's lower layout anchor
    // refers to that topAnchor. Recover the reserved web-page height
    // by updating this *existing* constraint rather than adding any.
    UILayoutGuide *safe = chrome.safeAreaLayoutGuide;
    for (NSLayoutConstraint *constraint in chrome.constraints) {
        BOOL normal = constraint.firstItem == bottom &&
            constraint.secondItem == safe &&
            constraint.firstAttribute == NSLayoutAttributeTop &&
            constraint.secondAttribute == NSLayoutAttributeBottom;
        BOOL reversed = constraint.secondItem == bottom &&
            constraint.firstItem == safe &&
            constraint.secondAttribute == NSLayoutAttributeTop &&
            constraint.firstAttribute == NSLayoutAttributeBottom;
        if ((normal || reversed) && constraint.constant != 0) {
            constraint.constant = 0;
        }
    }
    bottom.hidden = YES;
    bottom.userInteractionEnabled = NO;
}

static void (*OriginalChatGPTLayoutSubviews)(id, SEL) = NULL;
static void ChatGPTLayoutSubviews(id controller, SEL command) {
    if (OriginalChatGPTLayoutSubviews) {
        OriginalChatGPTLayoutSubviews(controller, command);
    }
    ApplyChatChrome((UIViewController *)controller);
}

static BOOL NavigateToChatGPT(UIViewController *controller);

static BOOL NavigateToChatGPT(UIViewController *controller) {
    UIView *addressField = FindView(controller.view, @"AddressBarTextField");
    if (![addressField isKindOfClass:[UITextField class]]) return NO;

    UITextField *field = (UITextField *)addressField;
    field.text = @"https://chatgpt.com/";
    // Call Reynard's own delegate. Do NOT synthesize page JavaScript events.
    // Its addressBarDidSubmit pipeline handles Gecko navigation natively.
    id<UITextFieldDelegate> delegate = field.delegate;
    if (![delegate respondsToSelector:@selector(textFieldShouldReturn:)]) return NO;
    return [delegate textFieldShouldReturn:field];
}


/*
 * Native escape hatch for links opened inside ChatGPT Gecko.
 * No page JavaScript, web content access, or cookies involved.
 * Two compact movable buttons keep the app usable even when Gecko
 * restores an external page as the selected tab after an app restart.
 */
static NSString *const kReturnPositionKey = @"ChatGPTGecko.RecoveryControls.PositionV1";
static const void *kReturnControllerKey = &kReturnControllerKey;

@interface ChatGPTReturnControls : NSObject
@property(nonatomic, weak) UIViewController *browser;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, assign) CGPoint startCenter;
- (void)goBack:(id)sender;
- (void)goHome:(id)sender;
- (void)drag:(UIPanGestureRecognizer *)gesture;
@end

static CGPoint RecoveryClampedCenter(UIViewController *vc, CGPoint candidate) {
    CGRect bounds = vc.view.bounds;
    UIEdgeInsets safe = vc.view.safeAreaInsets;
    CGFloat w = 58, h = 96;
    CGFloat x = MIN(MAX(candidate.x, safe.left + w / 2 + 3),
                    CGRectGetWidth(bounds) - safe.right - w / 2 - 3);
    CGFloat y = MIN(MAX(candidate.y, safe.top + h / 2 + 20),
                    CGRectGetHeight(bounds) - safe.bottom - h / 2 - 90);
    return CGPointMake(x, y);
}

@implementation ChatGPTReturnControls

- (void)goBack:(id)sender {
    UIViewController *vc = self.browser;
    if (!vc || !vc.isViewLoaded) return;
    UIView *chrome = FindView(vc.view, @"BrowserChrome");
    UIView *toolbar = FindView(chrome, @"BottomToolbar");
    SEL action = NSSelectorFromString(@"backTapped");
    if (toolbar && [toolbar respondsToSelector:action]) {
        // Invoke Reynard's real history handler, even though the native
        // toolbar has been hidden to provide the standalone appearance.
        ((void (*)(id, SEL))objc_msgSend)(toolbar, action);
    } else {
        // Last-resort reliable escape: the adjacent Home button also
        // remains available when the current page has no back history.
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"无法返回上一页"
            message:@"可以点击下方的「回GPT」按钮回到 ChatGPT。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
            style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

- (void)goHome:(id)sender {
    UIViewController *vc = self.browser;
    if (!vc || !vc.isViewLoaded) return;
    [vc.view endEditing:YES];
    if (!NavigateToChatGPT(vc)) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"无法打开 ChatGPT"
            message:@"网页导航未成功启动。请把当前页面截图发给我。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
            style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

- (void)drag:(UIPanGestureRecognizer *)gesture {
    UIViewController *vc = self.browser;
    UIView *panel = self.panel;
    if (!vc || !panel) return;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.startCenter = panel.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [gesture translationInView:vc.view];
        panel.center = RecoveryClampedCenter(vc, CGPointMake(
            self.startCenter.x + delta.x, self.startCenter.y + delta.y));
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        CGFloat w = CGRectGetWidth(vc.view.bounds);
        CGFloat h = CGRectGetHeight(vc.view.bounds);
        if (w > 100 && h > 100) {
            panel.center = RecoveryClampedCenter(vc, panel.center);
            [NSUserDefaults.standardUserDefaults setObject:
                @[@(panel.center.x/w), @(panel.center.y/h)]
                forKey:kReturnPositionKey];
        }
    }
}
@end

static UIButton *MakeReturnButton(NSString *title, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.clearColor;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static void InstallChatGPTReturnControls(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view.window) return;
    ChatGPTReturnControls *target =
        objc_getAssociatedObject(vc, kReturnControllerKey);
    if (!target) {
        target = [ChatGPTReturnControls new];
        target.browser = vc;
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 58, 96)];
        panel.layer.cornerRadius = 15;
        panel.layer.masksToBounds = YES;
        panel.layer.zPosition = 990;
        panel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.82];
        panel.accessibilityIdentifier = @"ChatGPTGecko.ReturnPanel";
        UIButton *back = MakeReturnButton(@"↶ 返回",
                            @selector(goBack:), target);
        back.frame = CGRectMake(0, 3, 58, 42);
        back.accessibilityLabel = @"返回上一页";
        [panel addSubview:back];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(9, 47, 40, 0.5)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
        [panel addSubview:line];
        UIButton *home = MakeReturnButton(@"⌂ 回GPT",
                            @selector(goHome:), target);
        home.frame = CGRectMake(0, 51, 58, 42);
        home.accessibilityLabel = @"返回 ChatGPT 聊天主页";
        [panel addSubview:home];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:target action:@selector(drag:)];
        [panel addGestureRecognizer:pan];
        [vc.view addSubview:panel];
        target.panel = panel;
        objc_setAssociatedObject(vc, kReturnControllerKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        CGSize size = vc.view.bounds.size;
        NSArray *pos = [NSUserDefaults.standardUserDefaults
            objectForKey:kReturnPositionKey];
        CGPoint p = CGPointMake(37, size.height * 0.58);
        if ([pos isKindOfClass:NSArray.class] && pos.count == 2 &&
            [pos[0] respondsToSelector:@selector(doubleValue)] &&
            [pos[1] respondsToSelector:@selector(doubleValue)]) {
            p = CGPointMake([pos[0] doubleValue] * size.width,
                            [pos[1] doubleValue] * size.height);
        }
        panel.center = RecoveryClampedCenter(vc, p);
    }
    [vc.view bringSubviewToFront:target.panel];
}

static void ChatGPTViewDidAppear(id controller, SEL command, BOOL animated) {
    if (OriginalViewDidAppear) OriginalViewDidAppear(controller, command, animated);

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = (UIViewController *)controller;
        if (!vc.isViewLoaded || vc.view.window == nil) return;

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (![defaults boolForKey:kStartupDone]) {
            // Only mark initial navigation once Reynard confirms it accepted
            // the URL. On first successful load the tab state is persisted and
            // restored in later launches.
            if (NavigateToChatGPT(vc)) {
                [defaults setBool:YES forKey:kStartupDone];
            }
        }

        ApplyChatChrome(vc);
        ChatGPTInstallFloatingDownloads(vc);
        InstallChatGPTReturnControls(vc);

        // On every cold start, check the restored address only once.
        // Reynard keeps old tabs in SQLite and otherwise restarts into
        // the last external product page indefinitely.
        // Keep a ChatGPT conversation if already selected. If an external
        // origin was restored, return to ChatGPT without clearing cookies.
        static BOOL checkedRestoreForThisProcess = NO;
        if (!checkedRestoreForThisProcess) {
            checkedRestoreForThisProcess = YES;
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(1.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC || !strongVC.view.window) return;
                UIView *addressView = FindView(strongVC.view,
                                               @"AddressBarTextField");
                if (![addressView isKindOfClass:[UITextField class]]) return;
                NSString *address = ((UITextField *)addressView).text.lowercaseString;
                if (address.length == 0) return;
                if ([address containsString:@"chatgpt.com"] ||
                    [address containsString:@"chat.openai.com"]) return;
                NavigateToChatGPT(strongVC);
            });
        }
    });
}

__attribute__((constructor))
static void InitializeChatGPTStandalone(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

        // Standalone chat must not hand ordinary link navigations to external
        // apps. Leave Gecko in charge of navigation and download responses.
        [defaults setBool:NO forKey:@"default.BrowsingSettings.openLinksInExternalApps"];

        // Existing tabs should be restored, not replaced with Reynard's homepage.
        // If the user creates an extra tab, load ChatGPT instead of a new-tab page.
        [defaults setObject:@"lastTab"
                     forKey:@"default.HomepageSettings.openingScreen"];
        [defaults setObject:@"customURL"
                     forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/"
                     forKey:@"default.NewTabSettings.customNewTabURL"];

        Class cls = NSClassFromString(@"Reynard.BrowserViewController");
        if (!cls) {
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name hasSuffix:@".BrowserViewController"]) {
                    cls = classes[i];
                    break;
                }
            }
            free(classes);
        }

        if (cls) {
            Method method = class_getInstanceMethod(cls, @selector(viewDidAppear:));
            if (method) {
                OriginalViewDidAppear =
                    (void (*)(id, SEL, BOOL))method_getImplementation(method);
                method_setImplementation(method, (IMP)ChatGPTViewDidAppear);
            }

            // Repeat the toolbar-only layout repair whenever Gecko
            // recomputes its chrome (navigation, keyboard and rotation).
            Method layoutMethod =
                class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
            if (layoutMethod) {
                OriginalChatGPTLayoutSubviews =
                    (void (*)(id, SEL))method_getImplementation(layoutMethod);
                BOOL added = class_addMethod(
                    cls,
                    @selector(viewDidLayoutSubviews),
                    (IMP)ChatGPTLayoutSubviews,
                    method_getTypeEncoding(layoutMethod)
                );
                if (!added) {
                    Method ownMethod =
                        class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
                    method_setImplementation(ownMethod, (IMP)ChatGPTLayoutSubviews);
                }
            }
        }
    }
}
