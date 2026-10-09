// The Live Activity (Mod Settings > Live Activity), on the lock screen and in the Dynamic
// Island (iOS 17+), under either look: it draws on no Spotify screen of its own. In one of three views: the line being sung with the next one under it, the tracks
// up next (a tap on one skipping ahead to it), or the control menu, tabs of Controls (previous, play and
// pause, next, shuffle, repeat), Queue and a sleep Timer of the mod's own (Shared/Player/SleepTimer.h)
// that fades the sound out (over the page's Fade out choice) and pauses Spotify, at a time or at the end of
// the track, album or playlist.
//
//     LiveActivity.x              polls the player, sends the activity a new state when what it shows changes
//     LiveActivityBridge.swift    ActivityKit, which is Swift only
//     LiveActivityShared.swift    the attributes and the taps' intents, compiled into the extension too, and
//                                 the shortcuts' intents: Like This Song, Play or Pause, Next and Previous Track,
//                                 Sing and Sleep Timer, for Siri, the Shortcuts app, the Action button and the
//                                 controls (extension/LiveActivity/Controls.swift), answered by LiveActivity.x
//                                 with the activity on or off; checked in the simulator (harness/shortcuts)
//     AppShortcuts.swift          Spotify's App Shortcuts, tweak only
//     LiveActivitySettings.m      its page, opened from the root of Mod Settings
//     SGLiveActivityPreview.m     the page's preview, a mock of the card on a slice of the lock screen
//
// Every tap in the card runs an intent inside Spotify and takes a second or two to show on the card.
//
// The widget is extension/LiveActivity, built into the IPA by scripts/build-extension.sh; the tap's
// intent runs in Spotify, so scripts/merge-appintents.py adds it to Spotify's App Intents metadata. The lines and
// the clock come from Shared/Lyrics, the queue from the player's state. The switch and the view apply at
// once: iOS lets an activity start only while the app is in front, which it is when the switch is flipped.
// The page's other options are read on every tick and sent in the state, so they apply within a tick too.
//
// The Swift names crossing into the widget (SGLyricsAttributes, the intents and their enums, the notifications)
// are a contract with extension/LiveActivity and with the App Intents metadata merged into Spotify:
// ActivityKit and App Intents pair the two processes by type name, so a change here is a change there.
// Threading: main thread only.
#import <Foundation/Foundation.h>

#define SGKeyLiveActivity @"spotifyglass.liveActivity"
// Which view it shows, the index into the page's list.
#define SGKeyLiveActivityView @"spotifyglass.liveActivity.view"
// The lyrics view's: the line's translation under it (off until switched on), and the line's size, an
// SGLiveActivityTextSize.
#define SGKeyLiveActivityTranslation @"spotifyglass.liveActivity.translation"
#define SGKeyLiveActivityTextSize @"spotifyglass.liveActivity.textSize"
// The lyrics view's too: what it shows on a track with no timed lyrics, an SGLiveActivityWithoutLyrics, and
// the lines' alignment, an SGLiveActivityAlignment.
#define SGKeyLiveActivityWithoutLyrics @"spotifyglass.liveActivity.withoutLyrics"
#define SGKeyLiveActivityAlignment @"spotifyglass.liveActivity.alignment"
// Every view's: the cover beside the track and in the Dynamic Island (on until switched off), the card's
// colors, an SGLiveActivityColors, and the progress bar (on until switched off).
#define SGKeyLiveActivityArtwork @"spotifyglass.liveActivity.artwork"
#define SGKeyLiveActivityColors @"spotifyglass.liveActivity.colors"
#define SGKeyLiveActivityProgressBar @"spotifyglass.liveActivity.progressBar"
// What the keys were called while this was the redesign's alone; LiveActivity.x's %ctor moves them over.
#define SGKeyLiveActivityWas @"spotifyglass.redesign.liveActivity"
#define SGKeyLiveActivityViewWas @"spotifyglass.redesign.liveActivity.view"

typedef NS_ENUM(NSInteger, SGLiveActivityView) {
    SGLiveActivityLyrics = 0,
    SGLiveActivityQueue,
    SGLiveActivityPanel,   // the control menu
};

// SGLyricsAttributes.ContentState's textSize; the widget gives each a text style.
typedef NS_ENUM(NSInteger, SGLiveActivityTextSize) {
    SGLiveActivityTextSmall = 0,
    SGLiveActivityTextMedium,
    SGLiveActivityTextLarge,
};

// SGLyricsAttributes.ContentState's withoutLyrics: a note under the track, or the track large in place of the lines.
typedef NS_ENUM(NSInteger, SGLiveActivityWithoutLyrics) {
    SGLiveActivityWithoutLyricsNote = 0,
    SGLiveActivityWithoutLyricsTrack,
};

// SGLyricsAttributes.ContentState's alignment, of the lyric lines.
typedef NS_ENUM(NSInteger, SGLiveActivityAlignment) {
    SGLiveActivityAlignLeft = 0,
    SGLiveActivityAlignCenter,
};

// SGLyricsAttributes.ContentState's colors: Spotify's (the cover's color darkened behind Spotify's green),
// the cover's (the same behind the cover's color lightened) or plain (white on the system's background).
typedef NS_ENUM(NSInteger, SGLiveActivityColors) {
    SGLiveActivityColorsSpotify = 0,
    SGLiveActivityColorsArtwork,
    SGLiveActivityColorsPlain,
};

// From the switch: starts following the player (and the activity, the app being in front) or ends both.
void SGSetLiveActivityEnabled(BOOL on);

@class UIViewController;
// The Live Activity page: a preview of the card (SGLiveActivityPreview.m), its switch, which view it shows, the
// lyrics' options and the card's.
UIViewController *SGLiveActivitySettingsPage(void);
// Whether this install lets Spotify start a Live Activity: NSSupportsLiveActivities, which only Vitrine's IPA
// build writes into Info.plist. Without it iOS turns every one down.
BOOL SGLiveActivityAllowedByInstall(void);
