#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

@interface ISHATextureQualityPickerController : UIViewController
@property (nonatomic, assign) NSInteger selectedQuality;
@property (nonatomic, copy) void (^onFinish)(NSInteger choice);
@property (nonatomic, strong) NSMutableArray<UIButton *> *qualityButtons;
@end

@implementation ISHATextureQualityPickerController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.layer.cornerRadius = 20.0;
    self.view.clipsToBounds = YES;
    self.preferredContentSize = CGSizeMake(360.0, 300.0);
    self.selectedQuality = 0;
    self.qualityButtons = [NSMutableArray array];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Texture Quality";
    title.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"Choose ASTC compression for this conversion.";
    subtitle.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    UIStackView *options = [[UIStackView alloc] init];
    options.axis = UILayoutConstraintAxisHorizontal;
    options.alignment = UIStackViewAlignmentFill;
    options.distribution = UIStackViewDistributionFillEqually;
    options.spacing = 8.0;
    options.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:options];

    NSArray<NSString *> *labels = @[@"High\nASTC 4×4", @"Balanced\nASTC 6×6", @"Small\nASTC 8×8"];
    for (NSInteger index = 0; index < labels.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = index;
        button.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        button.titleLabel.numberOfLines = 2;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.8;
        [button setTitle:labels[index] forState:UIControlStateNormal];
        button.layer.cornerRadius = 10.0;
        button.layer.borderWidth = 1.0;
        button.contentEdgeInsets = UIEdgeInsetsMake(10.0, 3.0, 10.0, 3.0);
        [button addTarget:self action:@selector(selectQuality:) forControlEvents:UIControlEventTouchUpInside];
        [options addArrangedSubview:button];
        [self.qualityButtons addObject:button];
    }

    UIButton *continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [continueButton setTitle:@"Use Selected Quality" forState:UIControlStateNormal];
    [continueButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    continueButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    continueButton.backgroundColor = UIColor.systemBlueColor;
    continueButton.layer.cornerRadius = 11.0;
    continueButton.translatesAutoresizingMaskIntoConstraints = NO;
    [continueButton addTarget:self action:@selector(confirmSelection) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:continueButton];

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton addTarget:self action:@selector(cancelSelection) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancelButton];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:22.0],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:7.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [subtitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [options.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:22.0],
        [options.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [options.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [options.heightAnchor constraintEqualToConstant:74.0],
        [continueButton.topAnchor constraintEqualToAnchor:options.bottomAnchor constant:20.0],
        [continueButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16.0],
        [continueButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [continueButton.heightAnchor constraintEqualToConstant:46.0],
        [cancelButton.topAnchor constraintEqualToAnchor:continueButton.bottomAnchor constant:5.0],
        [cancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [cancelButton.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-7.0]
    ]];
    [self refreshQualityButtons];
}

- (void)refreshQualityButtons {
    for (NSInteger index = 0; index < self.qualityButtons.count; index++) {
        UIButton *button = self.qualityButtons[index];
        BOOL active = (index == self.selectedQuality);
        button.backgroundColor = active ? [UIColor.systemBlueColor colorWithAlphaComponent:0.16] : UIColor.secondarySystemBackgroundColor;
        button.layer.borderColor = (active ? UIColor.systemBlueColor : UIColor.separatorColor).CGColor;
        button.layer.borderWidth = active ? 1.5 : 1.0;
        [button setTitleColor:active ? UIColor.labelColor : UIColor.secondaryLabelColor forState:UIControlStateNormal];
    }
}
- (void)selectQuality:(UIButton *)sender {
    self.selectedQuality = sender.tag;
    [self refreshQualityButtons];
}
- (void)confirmSelection { if (self.onFinish) self.onFinish(self.selectedQuality); }
- (void)cancelSelection { if (self.onFinish) self.onFinish(-1); }
@end

static UIViewController *ISHAFindTopController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) return ISHAFindTopController(controller.presentedViewController);
    if ([controller isKindOfClass:[UINavigationController class]]) return ISHAFindTopController(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:[UITabBarController class]]) return ISHAFindTopController(((UITabBarController *)controller).selectedViewController);
    return controller;
}

static UIViewController *ISHAActivePresenter(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow && window.rootViewController) return ISHAFindTopController(window.rootViewController);
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *legacyWindow = application.keyWindow;
#pragma clang diagnostic pop
    return legacyWindow.rootViewController ? ISHAFindTopController(legacyWindow.rootViewController) : nil;
}

// Returns: 0 = High 4x4, 1 = Balanced 6x6, 2 = Small 8x8, -1 = cancelled, -2 = UI unavailable/timeout.
__attribute__((visibility("default")))
int isha_show_texture_quality_picker(void) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block int selected = -2;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = ISHAActivePresenter();
        if (!presenter || presenter.isBeingDismissed || presenter.view.window == nil) {
            selected = -2;
            dispatch_semaphore_signal(semaphore);
            return;
        }
        ISHATextureQualityPickerController *picker = [[ISHATextureQualityPickerController alloc] init];
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        picker.onFinish = ^(NSInteger choice) {
            selected = (int)choice;
            [picker dismissViewControllerAnimated:YES completion:^{ dispatch_semaphore_signal(semaphore); }];
        };
        [presenter presentViewController:picker animated:YES completion:nil];
    });
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * 60 * NSEC_PER_SEC)));
    return waitResult == 0 ? selected : -2;
}
