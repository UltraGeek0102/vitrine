// What about the install itself can work against the mod, said once and kept at the top of Mod Settings
// while it lasts: EeveeSpotify injected beside it, a Spotify other than the one it is made for, the redesign without
// the app changes the IPA build makes, and a
// redesign below iOS 26 that did not start (Core/SGUIMode.h), which turned itself off. Also what Chroma, installed
// over the same Spotify before, left behind, offered once for deleting.
#import "Shared/Lyrics/Lyrics.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Onboarding.h"

static NSString *const kTold = @"spotifyglass.environment.told";
static NSString *const kCleanupOffered = @"spotifyglass.environment.chromaCleanupOffered";
static const NSTimeInterval kSettle = 4;   // after the first activation, behind the signing sheet's 3 s
static const NSTimeInterval kRetry = 4;
static const NSInteger kTries = 45;        // three minutes of waiting for the screen, then the rows say it

// A problem is its title and what it means, @[title, body].
typedef NSArray<NSString *> *SGProblem;

NSString *SGSpotifyVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
}

// A Spotify whose version can be read and is not the one the mod is made for; one that cannot be read
// says nothing, rather than "Spotify unknown".
static BOOL otherVersion(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && ![version isEqualToString:SGSpotifyMadeFor] && ![version isEqualToString:SGSpotifyLikelyWorks];
}

static SGProblem eevee(void) {
    return @[@"EeveeSpotify is injected too",
             @"Vitrine already blocks ads and brings lyrics, and EeveeSpotify hooks the same parts of Spotify. With both, Spotify can freeze as it starts or show the wrong lyrics. Sign Spotify again without EeveeSpotify."];
}

static SGProblem version(void) {
    return @[[NSString stringWithFormat:@"Spotify %@ is not the version Vitrine is made for", SGSpotifyVersion()],
             [NSString stringWithFormat:@"Vitrine is made for Spotify %@, and %@ likely works too. On another version some of its changes find nothing to change, and some screens can look wrong or crash. Inject Vitrine into Spotify %@ or %@.",
                 SGSpotifyMadeFor, SGSpotifyLikelyWorks, SGSpotifyMadeFor, SGSpotifyLikelyWorks]];
}

// Installed without the app changes Vitrine's IPA build makes (scripts/pipeline.sh: plist/liquid-glass.plist and the
// Live Activity), as when its .deb is injected by hand: the system keeps its old bars, so the glass tab bar is gone, and
// without MusicHapticsSupported iOS leaves Spotify out of Music Haptics.
static BOOL withoutAppChanges(void) {
    id compatibility = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
    return SGRedesignAvailable() && SGRedesignedUIStored() && !([compatibility isKindOfClass:NSNumber.class] && ![compatibility boolValue]);
}

static SGProblem appChanges(void) {
    return @[@"Installed without Vitrine's app changes",
             @"The redesign needs changes to the app that only Vitrine's IPA build makes, so the tab bar stays Spotify's own, the Live Activity is missing, and iOS does not list Spotify for Music Haptics, which stops vibrations in the background. Build the IPA with Vitrine instead of injecting its .deb."];
}

static SGProblem fellBack(void) {
    return @[@"The redesign did not start",
             [NSString stringWithFormat:@"Spotify did not get going with the redesign on iOS %@, so it is back in Legacy and Redesigned UI is off. Mod Settings can turn it on again.",
                 UIDevice.currentDevice.systemVersion]];
}

// One problem is the alert's title and message; several are a paragraph each under a count.
static void tell(NSArray<SGProblem> *list) {
    NSString *title = list.count == 1 ? list[0][0] : [NSString stringWithFormat:@"%lu things to know", (unsigned long)list.count];
    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    for (SGProblem problem in list) {
        [paragraphs addObject:list.count == 1 ? problem[1] : [NSString stringWithFormat:@"%@.\n%@", problem[0], problem[1]]];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:[paragraphs componentsJoinedByString:@"\n\n"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// What Chroma, installed over the same Spotify before Vitrine, left in the app's storage that Vitrine never
// reads: its Karaoke voice model (about 470 MB) and its saved lock screen videos. Its listening history and
// audio effects are the person's own and stay (AudioEffectsFiles.m moves the effects over).
static NSArray<NSURL *> *chromaLeftovers(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *caches = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    for (NSURL *url in @[[support URLByAppendingPathComponent:@"spoti.pw/Sing" isDirectory:YES],
                         [caches URLByAppendingPathComponent:@"spoti.pw/LockArtwork" isDirectory:YES]]) {
        if ([files fileExistsAtPath:url.path]) [found addObject:url];
    }
    return found;
}

static NSString *sizeOf(NSArray<NSURL *> *urls) {
    long long total = 0;
    for (NSURL *url in urls) {
        for (NSURL *file in [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:nil]) {
            NSNumber *size = nil;
            [file getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
            total += size.longLongValue;
        }
    }
    return [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile];
}

static void offerCleanup(void) {
    NSArray<NSURL *> *leftovers = chromaLeftovers();
    if (!leftovers.count) return;
    NSString *size = sizeOf(leftovers);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Chroma left %@ on this iPhone", size]
                                                                  message:@"Its Karaoke voice model and its saved lock screen videos are still in Spotify's storage, and Vitrine uses neither. Your listening history and audio effects stay."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (NSURL *url in leftovers) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            SGLog(@"environment: deleted %@ Chroma left", size);
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// What about the install is worth saying.
static NSArray<SGProblem> *installProblems(void) {
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGEeveeSpotifyInjected()) [list addObject:eevee()];
    if (otherVersion()) [list addObject:version()];
    if (withoutAppChanges()) [list addObject:appChanges()];
    return list;
}

// The rows stay while the install is so; the fall back is said once and is over.
NSArray<SGModRow *> *SGEnvironmentWarningRows(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    if (SGEeveeSpotifyInjected())
        [rows addObject:SGWarningRow(@"EeveeSpotify is injected too", @"Tap for what that does", ^{ tell(@[eevee()]); })];
    if (otherVersion())
        [rows addObject:SGWarningRow([NSString stringWithFormat:@"Made for Spotify %@", SGSpotifyMadeFor],
                                     [NSString stringWithFormat:@"This is %@. Tap for what that does", SGSpotifyVersion()],
                                     ^{ tell(@[version()]); })];
    if (withoutAppChanges())
        [rows addObject:SGWarningRow(@"Installed without the app changes", @"Tap for what that does", ^{ tell(@[appChanges()]); })];
    if (chromaLeftovers().count)
        [rows addObject:SGWarningRow(@"Chroma left files behind", [NSString stringWithFormat:@"%@ Vitrine never uses. Tap to delete", sizeOf(chromaLeftovers())], ^{ offerCleanup(); })];
    return rows;
}

// Once per install state: the same EeveeSpotify and the same Spotify version say nothing again, a
// change says what it is now.
static NSString *state(void) {
    return [NSString stringWithFormat:@"eevee %d, spotify %@, app changes %d", SGEeveeSpotifyInjected(), SGSpotifyVersion(), !withoutAppChanges()];
}

static void whenClear(NSInteger tries, void (^then)(void)) {
    UIViewController *top = SGTopController();
    // The tour, What's new and the signing sheet own the screen first; an alert presented from one of
    // them lands nowhere, so this one waits its turn. It also waits for the app to be in front, so it is
    // not shown, and counted as told, to someone who sent Spotify away in its first seconds.
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!front || !top || SGOnboardingShowing() || [top isKindOfClass:UIAlertController.class]) {
        if (tries <= 0) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            whenClear(tries - 1, then);
        });
        return;
    }
    then();
}

static void tellProblems(void) {
    // The fall back is news every time; the install's state only when it changed.
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGRedesignFellBack()) [list addObject:fellBack()];
    if (![[store stringForKey:kTold] isEqualToString:state()]) {
        [store setObject:state() forKey:kTold];
        [list addObjectsFromArray:installProblems()];
    }
    if (list.count) tell(list);
    // Chroma's leftovers are offered once, after any problem; the row in Mod Settings stays while they do.
    if (chromaLeftovers().count && ![store boolForKey:kCleanupOffered]) {
        whenClear(kTries, ^{
            [store setBool:YES forKey:kCleanupOffered];
            offerCleanup();
        });
    }
}

void SGCheckEnvironmentOnce(void) {
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                      object:nil
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SGEeveeSpotifyInjected()) SGLog(@"environment: EeveeSpotify is injected too");
            if (otherVersion()) SGLog(@"environment: Spotify %@, made for %@", SGSpotifyVersion(), SGSpotifyMadeFor);
            whenClear(kTries, ^{ tellProblems(); });
        });
    }];
}
