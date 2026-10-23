// What Mod Settings' main page links to and reads, stood in for: every page is an empty page of its own
// name, the values beside the chevrons are what a fresh install reads, and the update check does nothing.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"

extern BOOL SGHarnessWarning;

static UIViewController *blank(NSString *title) {
    return [[SGModPage alloc] initWithTitle:title intro:nil sections:@[] footer:nil];
}

#define PAGE(name) UIViewController *name(void) { return blank(@#name); }
PAGE(SGAboutPage) PAGE(SGAdsSettingsPage) PAGE(SGAllFlagsPage) PAGE(SGArtistBlockSettingsPage) PAGE(SGDSPSettingsPage) PAGE(SGAutoMixSettingsPage)
PAGE(SGGesturesSettingsPage) PAGE(SGHeadGesturesSettingsPage) PAGE(SGHomeSettingsPage) PAGE(SGLabsPage)
PAGE(SGListeningStatsPage) PAGE(SGLiveActivitySettingsPage) PAGE(SGLockScreenWidgetPage) PAGE(SGNavbarSettingsPage)
PAGE(SGNowPlayingBarSettingsPage) PAGE(SGQueueSettingsPage) PAGE(SGRAlbumSettingsPage) PAGE(SGRArtistSettingsPage)
PAGE(SGRNavbarSettingsPage)
PAGE(SGSingSettingsPage) PAGE(SGSpatialVoiceSettingsPage) PAGE(SGVibrationsSettingsPage)
UIViewController *SGRPlayerSettingsPage(NSArray *more) { return blank(@"SGRPlayerSettingsPage"); }
UIViewController *SGRLyricsSettingsPage(NSString *title, NSString *intro, NSArray<SGModSection *> *sections) { return blank(title); }

#define ROW(name) SGModRow *name(void) { return SGPageRow(@#name, ^UIViewController *{ return nil; }); }
NSArray<SGModRow *> *SGAITranslatorRows(void) { return @[SGPageRow(@"SGAITranslatorRows", ^UIViewController *{ return nil; })]; }
ROW(SGAppIconRow) ROW(SGGlassLyricsRow) ROW(SGLockScreenLyricsRow) ROW(SGLyricsMeaningsRow)
ROW(SGLyricsTranslationLanguageRow) ROW(SGLyricsWordTimingRow) ROW(SGRLyricsTextSizesRow) ROW(SGLyricsDelayRow)
NSArray<SGModRow *> *SGAppFontRows(void) { return @[]; }
NSArray<SGModRow *> *SGNativeAppearanceRows(void) { return @[]; }
NSArray<SGModRow *> *SGRAppearanceRows(void) { return @[]; }
SGModSection *SGLyricsSourcesSection(BOOL namingSource) { return SGSection(nil, @[]); }
NSArray<SGModSection *> *SGNativePlayerScreenSections(void) { return @[]; }
NSArray<NSDictionary *> *SGBlockedArtists(void) { return @[]; }

NSString *SGDSPSummary(void) { return @"Off"; }
NSString *SGAutoMixSummary(void) { return @"Off"; }
NSString *SGSingSummary(void) { return @"Off"; }
// An iPhone that reads headphone motion, with Spatial voice off.
BOOL SGSingSpatialAvailable(void) { return YES; }
BOOL SGSingSpatial(void) { return NO; }

void SGCheckForUpdate(BOOL force) {}
void SGWatchForUpdates(void) {}
// Signing.m is the real one: its row stays away while the harness's own signature is sound, and its
// "Signed until" row shows once the .app holds an embedded.mobileprovision (README).
BOOL SGOnboardingShowing(void) { return NO; }
// Environment.m's red row, as a phone with EeveeSpotify injected too shows it.
NSArray<SGModRow *> *SGEnvironmentWarningRows(void) {
    if (!SGHarnessWarning) return @[];
    return @[SGWarningRow(@"EeveeSpotify is injected too", @"Tap to see what that changes", ^{})];
}
// The Lyrics page's Romanized lyrics row (Shared/Lyrics/Romanise.m).
SGModRow *SGLyricsRomanisedRow(void) { return SGOptionRow(@"Romanized lyrics", nil, @"spotifyglass.harness.romanised"); }
// The lock screen's source order row (MotionSources.m), for AnimatedArtworkSettings.m.
SGModRow *SGMotionSourcesRow(void) { return SGStatRow(@"Sources", ^NSString *{ return @"Canvas, Apple Music"; }); }
