#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <OSLog/OSLog.h>
#import <sys/utsname.h>
#import "Core/SGCore.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "Redesigned/Player/Player.h"

// Every key under the prefix travels, the way the reset sweeps them, so a new switch needs nothing
// here. What is left out belongs to this install rather than to its user's choices.
static BOOL isSetting(NSString *key) {
    if (![key hasPrefix:@"spotifyglass."]) return NO;
    for (NSString *local in @[@"spotifyglass.adblock.counts", @"spotifyglass.privacy.counts", @"spotifyglass.update.",
                              @"spotifyglass.signing.", @"spotifyglass.onboarding.", @"spotifyglass.navbar.stock",
                              @"spotifyglass.redesign.navbar.stock"]) {
        if ([key hasPrefix:local]) return NO;
    }
    return YES;
}

static NSDictionary *storedDefaults(void) {
    return [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
}

static void showAlert(NSString *title, NSString *message, UIAlertAction *confirm) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (confirm) [alert addAction:confirm];
    [alert addAction:[UIAlertAction actionWithTitle:confirm ? @"Cancel" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

void SGExportSettings(void) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [storedDefaults() enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (isSetting(key) && [NSJSONSerialization isValidJSONObject:@[value]]) settings[key] = value;
    }];
    NSDictionary *file = @{
        @"mod": @(SG_VERSION),
        @"spotify": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"settings": settings,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spotifyglass-settings.json"]];
    [data writeToURL:url atomically:YES];

    UIViewController *top = SGTopController();
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

void SGShareDiagnostics(void) {
    NSMutableString *text = [NSMutableString string];
    struct utsname machine;
    uname(&machine);
    [text appendFormat:@"Vitrine %s, Spotify %@, iOS %@, %s\n", SG_VERSION,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        UIDevice.currentDevice.systemVersion, machine.machine];
    [text appendFormat:@"look %@, hide ads %d, hide upsells %d, spoof premium %d, EeveeSpotify %d\n\n",
        SGRedesignedUIStored() ? @"redesign" : @"native", SGHidden(SGKeyHideAds), SGHidden(SGKeyHideUpsells),
        SGHidden(SGKeyFakePremium), SGEeveeSpotifyInjected()];
    [text appendString:@"== ads blocked (stopped of checked)\n"];
    for (NSString *label in SGAdBlockLabels()) {
        NSUInteger checked = SGAdBlockChecked(label);
        [text appendFormat:@"%@: %lu%@\n", label, (unsigned long)SGAdBlockCount(label),
            checked == NSNotFound ? @"" : [NSString stringWithFormat:@" of %lu", (unsigned long)checked]];
    }
    // This launch's lines, from the system log: release builds keep none of their own.
    [text appendString:@"\n== log, this launch\n"];
    NSError *error;
    OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
    // FLEX builds dump the screen's views into the log, page after page; the report keeps the lines.
    NSPredicate *ours = [NSPredicate predicateWithFormat:
        @"composedMessage BEGINSWITH '[spotifyglass]' AND NOT composedMessage BEGINSWITH '[spotifyglass] screen dump'"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (OSLogEntry *entry in [store entriesEnumeratorWithOptions:0 position:nil predicate:ours error:&error]) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", entry.date, [entry.composedMessage substringFromIndex:15]]];
    }
    // ponytail: the last 1500 lines only; a whole day's launch can hold tens of thousands.
    NSUInteger keep = MIN(lines.count, 1500);
    [text appendString:[[lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)] componentsJoinedByString:@"\n"]];
    if (!lines.count) [text appendFormat:@"(none: %@)", error.localizedDescription ?: @"the log is empty"];
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *config = [NSString stringWithContentsOfURL:[caches URLByAppendingPathComponent:@"Vitrine/live-config.txt"]
                                                encoding:NSUTF8StringEncoding error:nil];
    [text appendFormat:@"\n\n== config Spotify's server last sent\n%@", config ?: @"(none yet: Spoof Premium is off, or no fetch so far)\n"];

    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vitrine-diagnostics.txt"]];
    [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIViewController *top = SGTopController();
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = top.view;
    [top presentViewController:sheet animated:YES completion:nil];
}

static Class kindOf(id value) {
    for (Class kind in @[NSNumber.class, NSString.class, NSArray.class, NSDictionary.class]) {
        if ([value isKindOfClass:kind]) return kind;
    }
    return Nil;
}

// A key already stored keeps its type: the hooks send boolValue to whatever they find at launch, and
// an array there would crash Spotify before the reset row could be reached.
// Settings exported by Chroma (spoti.pw 0.50) under its own names, in ours. Its player background knows only
// Fluid (0) and Animated (1); its artwork sources call Spotify's clips "spotify". Its menu row cache and
// one-time notices have no counterpart and are left out.
static NSDictionary *fromChroma(NSDictionary *settings) {
    NSDictionary<NSString *, NSString *> *renamed = @{
        @"spotifyglass.redesign.sing": @"spotifyglass.sing",
        @"spotifyglass.redesign.sing.ignoreHeat": @"spotifyglass.sing.ignoreHeat",
        @"spotifyglass.redesign.spatialVoice": @"spotifyglass.sing.spatial",
        @"spotifyglass.redesign.player.hideVideoSwitch": @"spotifyglass.hide.videoSwitch",
        @"spotifyglass.gestures.head": @"spotifyglass.headgestures",
        @"spotifyglass.redesign.inlinePlayer": @"spotifyglass.redesign.navbar.minimize",
    };
    NSSet<NSString *> *dropped = [NSSet setWithArray:@[@"spotifyglass.redesign.menuNumbers", @"spotifyglass.eevee.warned",
                                                       @"spotifyglass.spotifyversion.warned", @"spotifyglass.lockscreen.lyricsartwork"]];
    NSMutableDictionary *ours = [NSMutableDictionary dictionary];
    for (NSString *key in settings) {
        id value = settings[key];
        if ([dropped containsObject:key]) continue;
        if ([key isEqualToString:@"spotifyglass.redesign.player.backdrop"]) {
            ours[@"spotifyglass.redesign.player.background"] = @([value integerValue] == 1 ? SGRPlayerBackgroundAnimated : SGRPlayerBackgroundFluid);
        } else if ([key isEqualToString:@"spotifyglass.redesign.player.artworksources"] && [value isKindOfClass:NSArray.class]) {
            NSMutableArray *sources = [NSMutableArray array];
            for (NSString *source in value) [sources addObject:[source isEqual:@"spotify"] ? @"canvas" : source];
            ours[@"spotifyglass.motion.sources"] = sources;
        } else {
            ours[renamed[key] ?: key] = value;
        }
    }
    return ours;
}

static void importSettings(NSDictionary *settings) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    settings = fromChroma(settings);
    NSDictionary *stored = storedDefaults();
    for (NSString *key in stored) {
        if (isSetting(key)) [store removeObjectForKey:key];
    }
    NSUInteger skipped = 0;
    for (NSString *key in settings) {
        id value = settings[key];
        id current = stored[key];
        BOOL fits = isSetting(key)
            && [NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0]
            && (!current || kindOf(current) == kindOf(value));
        if (fits) [store setObject:value forKey:key];
        else skipped++;
    }
    SGLog(@"import: set %lu keys, skipped %lu", (unsigned long)(settings.count - skipped), (unsigned long)skipped);
    SGRestartSpotify();
}

@interface SGSettingsPicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation SGSettingsPicker

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = [NSData dataWithContentsOfURL:urls.firstObject];
    id file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *settings = [file isKindOfClass:NSDictionary.class] ? file[@"settings"] : nil;
    if (![settings isKindOfClass:NSDictionary.class]) {
        showAlert(@"Not a settings file", @"Pick a file made by Export settings.", nil);
        return;
    }
    NSString *mod = [file[@"mod"] isKindOfClass:NSString.class] ? file[@"mod"] : @"unknown";
    NSString *message = [NSString stringWithFormat:@"Your settings are replaced by the file's, exported from version %@. Anything it does not have goes back to its default, and Spotify restarts.", mod];
    showAlert(@"Import settings?", message, [UIAlertAction actionWithTitle:@"Import and restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        importSettings(settings);
    }]);
}

@end

void SGImportSettings(void) {
    static SGSettingsPicker *delegate;
    if (!delegate) delegate = [SGSettingsPicker new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}
