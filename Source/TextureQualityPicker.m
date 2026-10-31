#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

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
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Texture Quality"
            message:@"Piliin ang ASTC compression para sa conversion na ito."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"High — ASTC 4×4 · Best detail" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            selected = 0; dispatch_semaphore_signal(semaphore);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Balanced — ASTC 6×6" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            selected = 1; dispatch_semaphore_signal(semaphore);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Small — ASTC 8×8 · Smaller size" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            selected = 2; dispatch_semaphore_signal(semaphore);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            selected = -1; dispatch_semaphore_signal(semaphore);
        }]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * 60 * NSEC_PER_SEC)));
    return waitResult == 0 ? selected : -2;
}
