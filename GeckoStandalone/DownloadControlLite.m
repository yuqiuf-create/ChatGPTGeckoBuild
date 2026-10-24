// ChatGPT Gecko: simple floating downloads launcher.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
extern NSUInteger ChatGPTGeckoActiveDownloadCount(void);
static const void *kDLTargetKey = &kDLTargetKey;
@interface CGDownloadTarget : NSObject
@property(nonatomic, weak) UIViewController *vc;
@property(nonatomic, weak) UIButton *button;
@property(nonatomic) CGPoint origin;
- (void)open:(id)sender;
- (void)pan:(UIPanGestureRecognizer *)gesture;
@end
@implementation CGDownloadTarget
- (void)open:(id)sender {
    UIViewController *vc=self.vc;
    if (!vc || vc.presentedViewController) return;
    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:vc.view];
    SEL selector=NSSelectorFromString(@"downloadsTapped");
    while (queue.count) {
        UIView *v=queue.lastObject;
        [queue removeLastObject];
        if ([NSStringFromClass(v.class) hasSuffix:@".BottomToolbar"] &&
            [v respondsToSelector:selector]) {
            ((void (*)(id,SEL))objc_msgSend)(v,selector);
            return;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"下载管理"
        message:@"暂时无法打开下载管理页面。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIViewController *vc=self.vc;
    UIButton *b=self.button;
    if (!vc || !b) return;
    if (g.state==UIGestureRecognizerStateBegan) self.origin=b.center;
    if (g.state==UIGestureRecognizerStateChanged || g.state==UIGestureRecognizerStateEnded) {
        CGPoint delta=[g translationInView:vc.view];
        UIEdgeInsets insets=vc.view.safeAreaInsets;
        CGFloat w=CGRectGetWidth(vc.view.bounds), h=CGRectGetHeight(vc.view.bounds);
        b.center=CGPointMake(MIN(MAX(self.origin.x+delta.x, 26), w-26),
                             MIN(MAX(self.origin.y+delta.y, insets.top+92),h-insets.bottom-115));
    }
}
@end
void ChatGPTInstallFloatingDownloads(UIViewController *vc) {
    if (!vc.isViewLoaded || !vc.view.window) return;
    CGDownloadTarget *target=objc_getAssociatedObject(vc,kDLTargetKey);
    if (target) {
        NSUInteger count=ChatGPTGeckoActiveDownloadCount();
        [target.button setTitle:(count ? [NSString stringWithFormat:@"%lu",(unsigned long)count] : @"↓")
                       forState:UIControlStateNormal];
        [vc.view bringSubviewToFront:target.button];
        return;
    }
    target=[CGDownloadTarget new];
    target.vc=vc;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];
    button.frame=CGRectMake(CGRectGetWidth(vc.view.bounds)-56, 300, 44, 44);
    button.backgroundColor=[UIColor colorWithWhite:0.2 alpha:0.86];
    button.layer.cornerRadius=22;
    button.layer.zPosition=999;
    button.accessibilityIdentifier=@"GeckoStandalone.FloatingDownloads";
    [button setTitle:@"↓" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont boldSystemFontOfSize:24];
    [button addTarget:target action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:target action:@selector(pan:)];
    [button addGestureRecognizer:pan];
    target.button=button;
    [vc.view addSubview:button];
    objc_setAssociatedObject(vc,kDLTargetKey,target,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
