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

static id stringsAsset(NSBundle *bundle, NSString *name) {
    NSData *data = [[NSDataAsset alloc] initWithName:name bundle:bundle].data;
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// The region dialog's title as Spotify words it, in English and in the app's language, from Spotify's own strings:
// SPTStrings.bundle's _i18n.KEYS lists every key, _i18n.INDEX names each language's file, and each _i18n.<file>
// holds the values at the keys' indexes. Read once, at the first pop-up.
static NSSet<NSString *> *regionTitles(void) {
    static NSSet<NSString *> *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *strings = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"SPTStrings" ofType:@"bundle"]];
        NSArray *keys = stringsAsset(strings, @"_i18n.KEYS");
        NSDictionary *files = stringsAsset(strings, @"_i18n.INDEX");
        NSUInteger at = [keys isKindOfClass:NSArray.class] ? [keys indexOfObject:@"SPTEndless_DJMusicImpl:sDJMRegionUnavailableDialogTitle"] : NSNotFound;
        NSMutableSet<NSString *> *found = [NSMutableSet set];
        for (NSString *language in [NSBundle.mainBundle.preferredLocalizations arrayByAddingObject:@"en"]) {
            if (at == NSNotFound) break;
            NSString *file = [files isKindOfClass:NSDictionary.class] && [files[language] isKindOfClass:NSString.class] ? files[language] : language;
            NSArray *values = stringsAsset(strings, [@"_i18n." stringByAppendingString:file]);
            id value = [values isKindOfClass:NSArray.class] && at < values.count ? values[at] : nil;
            if ([value isKindOfClass:NSString.class]) [found addObject:value];
        }
        SGLog(@"DJ: the region dialog's titles in Spotify's strings: %@", found.count ? [found.allObjects componentsJoinedByString:@" | "] : @"none, so it stays");
        titles = found;
    });
    return titles;
}

// The dialog comes in a window of its own, with no SPTEncorePopUpPresenter call to catch, and its title is set only
// by its first layout.
%hook PopUpContainer
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *container = (UIViewController *)self;
    if (container.view.window.hidden) return;
    static char kTitleKey;
    NSString *title = ((UILabel *)SGFindIdentifier(container.view, @"PopUp.Dialog.Title-internal", &kTitleKey)).text;
    if (!title || ![regionTitles() containsObject:title]) return;
    container.view.window.hidden = YES;
    id presenter = [(id)%c(SPTEncorePopUpPresenter) valueForKey:@"shared"];
    [presenter dismissPopupWithAnimate:NO clearQueue:NO completion:nil];
    SGLog(@"DJ: closed \"%@\"", title);
}
%end

%ctor {
    if (!SGHidden(SGKeyFakePremium)) return;
    %init(PopUpContainer = objc_getClass("_TtC29EncoreConsumerMobile_Wrappers25PopUpPresentableContainer"));
    SGRequireClasses(@[@"_TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl", @"_TtC29EncoreConsumerMobile_Wrappers25PopUpPresentableContainer"]);
}
