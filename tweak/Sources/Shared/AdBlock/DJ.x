// The DJ under Spoof Premium: Spotify offers it only where its playlist (spotify:playlist:37i9dQZF1EYkqdzj48dyYq)
// loads, which the checker below tries first. Answering yes gives the full DJ, requests included. A Free account
// is still told "DJ is not available in your country" at each start (DJMRegionUnavailableDialogEffectHandler, pure
// Swift) while the DJ plays on, so that dialog is closed before it shows.
#import "Core/SGCore.h"
#import "AdBlock.h"

@interface SPTEncorePopUpPresenter : NSObject
- (void)dismissPopupWithAnimate:(BOOL)animate clearQueue:(BOOL)clearQueue completion:(id)completion;
@end

%hook _TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl
- (void)isEligibleForDJWithCompletion:(void (^)(BOOL))completion {
    if (completion) completion(YES);
}
%end

static NSString *dialogTitle(UIView *root) {
    __block NSString *title;
    SGForEachView(root, ^(UIView *view) {
        if (!title && [view isKindOfClass:UILabel.class] && [view.accessibilityIdentifier isEqualToString:@"PopUp.Dialog.Title-internal"]) {
            title = ((UILabel *)view).text;
        }
    });
    return title;
}

// The dialog comes in a window of its own, with no SPTEncorePopUpPresenter call to catch, and its title is set only
// by its first layout.
%hook PopUpContainer
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *container = (UIViewController *)self;
    if (container.view.window.hidden) return;
    // shortcut: the title is localized, and "DJ" is the one word every language keeps.
    if (![dialogTitle(container.view) containsString:@"DJ"]) return;
    container.view.window.hidden = YES;
    id presenter = [(id)%c(SPTEncorePopUpPresenter) valueForKey:@"shared"];
    [presenter dismissPopupWithAnimate:NO clearQueue:NO completion:nil];
    SGLog(@"DJ: closed \"%@\"", dialogTitle(container.view));
}
%end

%ctor {
    if (!SGHidden(SGKeyFakePremium)) return;
    %init(PopUpContainer = objc_getClass("_TtC29EncoreConsumerMobile_Wrappers25PopUpPresentableContainer"));
    SGRequireClasses(@[@"_TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl", @"_TtC29EncoreConsumerMobile_Wrappers25PopUpPresentableContainer"]);
}
