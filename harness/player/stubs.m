#import "substrate.h"
// What the player harness does not compile: the Kit's hooks (SGRAccent.x, SGRRepaint.x), the rest of
// the player's hooks, the lyrics store and the haptics. Everything here answers the way the phone would
// for one track with lyrics, so the redesign's own code is what is being looked at. The player itself
// is a mock the harness drives: SGRHarnessSetTrack reports a track change to every observer.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"

#pragma mark - SGRAccent.x, SGRRepaint.x

UIColor *SGRAccentColor(void) { return nil; }
__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;

#pragma mark - Shared/Player/PlayerEvents.x

NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
CFTimeInterval SGPlayerTransitionEnds(void) { return 0; }

#pragma mark - Shared/Player/PlayerState.x

NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSString.class]) return uri;
    if ([uri isKindOfClass:NSURL.class]) return ((NSURL *)uri).absoluteString;
    return nil;
}

// A player that plays what the harness tells it to, reporting on the main thread the way
// Shared/Player/PlayerState.x moves Spotify's reports onto it.
@implementation SPTPlayerTrack
@end
@implementation SPTPlayerOptions
@end
@implementation SPTPlayerState
@end

static NSHashTable *sg_observers;
static SPTPlayerState *sg_state;

void SGAddPlayerStateObserver(id observer) {
    if (!sg_observers) sg_observers = [NSHashTable weakObjectsHashTable];
    [sg_observers addObject:observer];
}
SPTPlayerState *SGPlayerState(void) { return sg_state; }

// `imageURI` is the xlarge picture as Spotify's metadata has it, spotify:image:<40 hex digits>, or nil for
// a track whose metadata names none.
void SGRHarnessSetTrack(NSString *uri, NSString *imageURI, BOOL paused) {
    SPTPlayerTrack *track = [SPTPlayerTrack new];
    [track setValue:uri forKey:@"URI"];
    NSMutableDictionary *metadata = [@{@"title": uri} mutableCopy];
    if (imageURI) {
        // The four sizes share the picture's last 24 digits (out/karaoke-diag.log:174-177 on the phone).
        NSString *hash = [imageURI substringFromIndex:imageURI.length - 24];
        metadata[@"image_xlarge_url"] = imageURI;
        metadata[@"image_large_url"] = imageURI;
        metadata[@"image_url"] = [@"spotify:image:ab67616d00001e02" stringByAppendingString:hash];
        metadata[@"image_small_url"] = [@"spotify:image:ab67616d00004851" stringByAppendingString:hash];
    }
    // HARNESS_ARTIST, HARNESS_ALBUM and HARNESS_CANVAS (a video URL) give Animated artwork something to find.
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    if (env[@"HARNESS_ARTIST"]) [track setValue:env[@"HARNESS_ARTIST"] forKey:@"artistName"];
    if (env[@"HARNESS_ALBUM"]) metadata[@"album_title"] = env[@"HARNESS_ALBUM"];
    if (env[@"HARNESS_CANVAS"]) {
        metadata[@"canvas.type"] = @"VIDEO_LOOPING_RANDOM";
        metadata[@"canvas.url"] = env[@"HARNESS_CANVAS"];
    }
    [track setValue:metadata forKey:@"metadata"];
    SPTPlayerState *state = [SPTPlayerState new];
    [state setValue:track forKey:@"track"];
    [state setValue:@(paused) forKey:@"isPaused"];
    [state setValue:@(!paused) forKey:@"isPlaying"];
    sg_state = state;
    for (id<SGPlayerStateObserver> observer in sg_observers.allObjects) [observer playerStateDidChange:state];
}

#pragma mark - Shared/Haptics

void SGPlayFeedback(NSInteger feedback) {}
void SGPrepareFeedback(NSInteger feedback) {}

#pragma mark - Shared/LyricsSources

NSString *SGLyricsCreditFor(NSString *trackID) { return @"the harness"; }
BOOL SGLyricsCreditRequired(NSString *credit) { return NO; }
NSArray *SGLyricsCreditLinks(NSString *text) { return nil; }
void SGLyricsOpenCreditLinks(NSArray *links, UIView *from) {}

#pragma mark - Shared/Lyrics/KaraokeSource.x

static NSArray<SGKaraokeLine *> *sg_lines;
static NSString *sg_track = @"harness";
static NSInteger sg_position;
static CFTimeInterval sg_started;

NSString *SGKaraokePlayingTrack(void) { return sg_track; }
NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *trackID) { return sg_lines; }
void SGKaraokeKeepLines(NSString *trackID, NSArray<SGKaraokeLine *> *lines) { sg_lines = lines; }
void SGKaraokeRequestLyrics(NSString *trackID) {}
NSNotificationName const SGKaraokeLinesKeptNotification = @"harness.karaokeLinesKept";
BOOL SGKaraokeLooking(NSString *trackID) { return NO; }
id SGKaraokePlayer(void) { return nil; }
SPTPlayerTrack *SGKaraokeTrackFor(NSString *trackID) { return nil; }
void SGKaraokeRememberTrack(SPTPlayerTrack *track) {}

// The song runs on from the moment the harness started it, so the sweep is alive in a screenshot.
NSInteger SGKaraokeDelayMs(void) { return [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsDelay]; }

NSInteger SGKaraokePositionMs(void) {
    if (!sg_started) return sg_position;
    return sg_position + (NSInteger)((CACurrentMediaTime() - sg_started) * 1000);
}
void SGKaraokeSeek(NSInteger ms) {
    sg_position = ms;
    sg_started = CACurrentMediaTime();
}
void SGRHarnessPlayFrom(NSInteger ms) { SGKaraokeSeek(ms); }

// Line meanings: Genius is not asked in the harness. The sheet itself is the real one (MeaningSheet.m).
#import "Shared/LyricsMeanings/Meanings.h"
@implementation SGLyricsMeaning
@end
void SGLyricsMeaningsFor(NSString *trackID, NSArray<SGKaraokeLine *> *lines,
                         void (^done)(NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *byLine)) {}

// AI translation and the settings framework's top controller: not part of the harness.
#import "Shared/LyricsTranslation/LyricsTranslation.h"
BOOL SGAITranslatorReady(void) { return NO; }
NSString *SGLyricsTranslationTarget(void) { return @"en"; }
void SGLyricsTranslateWithAI(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                             void (^done)(NSArray<NSString *> *translations, NSString *error)) { done(nil, @"harness"); }

// Local files: no edits in the harness, so the name is all PlayerLyrics.x needs to watch for one.
#import "Shared/LocalFiles/LocalFiles.h"
NSNotificationName const SGLocalFileEditsDidChangeNotification = @"harness.localFileEditsDidChange";
NSString *SGLocalFileCoverInURL(NSString *url) { return nil; }
UIImage *SGLocalFileFallbackCover(SPTPlayerTrack *track) { return nil; }

// Speed and pitch: a number the harness keeps, with no audio behind it.
static double sg_speed = 1;
double SGPlayerSpeed(void) { return sg_speed; }
BOOL SGPlayerSpeedAllowed(void) { return YES; }
void SGSetPlayerSpeed(double speed) { sg_speed = speed; NSLog(@"[harness] speed %.2f", speed); }

// The audio effects' reader (AudioEffects.x): a song of the harness's own, 120 beats a minute at 48 kHz, a kick on
// every beat, hats between, a bass line, a chord and a tune, handed to the reader in buffers of 1024 on a queue of
// its own, as the render thread would, for as long as one is set.
#import <stdatomic.h>
#import "Shared/AudioEffects/AudioEffects.h"

static _Atomic(SGAudioOutputReader) sg_reader;
static dispatch_source_t sg_audio;

BOOL SGRHarnessReading(void) { return atomic_load(&sg_reader) != NULL; }

static void synthesize(float *out, uint64_t start, int count, double rate) {
    static const double bass[] = {55, 73.42, 65.41, 49}, tune[] = {440, 523.25, 587.33, 659.25, 783.99, 659.25, 587.33, 523.25};
    for (int i = 0; i < count; i++) {
        double t = (start + i) / rate, beat = fmod(t, 0.5), half = fmod(t + 0.25, 0.5);
        int bar = (int)(t / 2) % 4, note = (int)(t / 0.5) % 8;
        double kick = 0.55 * sin(2 * M_PI * 52 * beat) * exp(-9 * beat);
        double hat = 0.12 * (2.0 * arc4random_uniform(1 << 16) / (1 << 16) - 1) * exp(-50 * half);
        double low = 0.22 * sin(2 * M_PI * bass[bar] * t);
        double chord = 0.05 * (0.6 + 0.4 * sin(2 * M_PI * 0.25 * t)) * (sin(2 * M_PI * 220 * t) + sin(2 * M_PI * 277.18 * t) + sin(2 * M_PI * 329.63 * t));
        double lead = 0.08 * sin(2 * M_PI * tune[note] * t) * (1 - exp(-20 * beat));
        out[i] = (float)(kick + hat + low + chord + lead);
    }
}

void SGAudioSetOutputReader(SGAudioOutputReader reader) {
    atomic_store(&sg_reader, reader);
    NSLog(@"[harness] output reader %@", reader ? @"on" : @"off");
    if (sg_audio) return;
    __block uint64_t played = 0;
    sg_audio = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("harness.audio", DISPATCH_QUEUE_SERIAL));
    dispatch_source_set_timer(sg_audio, DISPATCH_TIME_NOW, (uint64_t)(1024 / 48000.0 * NSEC_PER_SEC), NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sg_audio, ^{
        static float buffer[1024];
        synthesize(buffer, played, 1024, 48000);
        played += 1024;
        SGAudioOutputReader now = atomic_load(&sg_reader);
        if (now) now(buffer, 1024, 48000);
    });
    dispatch_resume(sg_audio);
}

// Sing (the mic on the lyrics, SGRSingButton.m): never available, as on a phone that cannot run it.
#import "Shared/Sing/Sing.h"
NSString *const SGSingChangedNotification = @"harness.singChanged";
SGSingState SGSingCurrentState(void) { return SGSingStateUnavailable; }
NSString *SGSingStatusText(void) { return @"Unavailable"; }
NSString *SGSingStatusDetail(void) { return nil; }
NSString *SGSingMissing(void) { return @"the harness"; }
BOOL SGSingOn(void) { return NO; }
void SGSetSingOn(BOOL on) {}
float SGSingLevel(void) { return 0; }
void SGSetSingLevel(float level) {}
NSString *SGSingLevelText(double level) { return @""; }
double SGSingModelProgress(void) { return 0; }
BOOL SGSingModelWaitingForNetwork(void) { return NO; }
NSString *SGSingModelError(void) { return nil; }
NSString *SGSingModelSizeText(void) { return @""; }
void SGSingDownloadModel(void) {}
void SGSingCancelModelDownload(void) {}

// MotionSources.m: the default order, Canvas then Apple Music, over the catalog the harness builds. No
// Canvas service: a track whose metadata names no Canvas goes to Apple Music.
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
NSArray<NSString *> *SGMotionSourceOrder(void) { return @[@"canvas", @"applemusic"]; }
NSURL *SGMotionCanvasIn(NSDictionary *metadata) {
    id address = metadata[@"canvas.url"];
    return [metadata[@"canvas.type"] hasPrefix:@"VIDEO"] && [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
}
void SGMotionClipFor(NSString *uri, NSURL *canvas, NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                     void (^done)(NSURL *file, NSString *source)) {
    void (^apple)(void) = ^{ SGMotionAlbumCover(artist, album, shape, pixels, ^(NSURL *file) { done(file, file ? @"applemusic" : nil); }); };
    if (!canvas) { apple(); return; }
    SGMotionFile(canvas, ^(NSURL *file) { if (file) done(file, @"canvas"); else apple(); });
}
// The Artwork sources row as a link to nowhere, so the Player page's rows under the card can be counted.
#import "Settings/SGModPage.h"
SGModRow *SGMotionSourcesRow(void) { return SGPageRow(@"Artwork sources", ^UIViewController *{ return nil; }); }
BOOL SGMotionAppleMusicOn(void) { return YES; }

// TabBar.x: the Mini player section's Apple Music style switch lays the tab bar out again; there is none here.
void SGRSetTabBarMinimized(BOOL minimized, BOOL animated) {}
void SGRRefreshTabBar(void) {}

// The ⋯'s system menu (PlayerMenu.m, ContextMenu.x), which this harness does not build; PlayerHeader.x hands it
// the ⋯, and with no button of the mod's over it the ⋯'s own touches press its circle.
void SGRPlayerMenuWatch(UIView *button) {}
UIControl *SGRSystemMenuFront(UIView *button) { return nil; }

// Cydia Substrate's hook (substrate.h here), as the runtime does it: the class gets its own copy of an inherited
// method, so its superclass is left alone.
void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old) {
    Method method = class_getInstanceMethod(_class, message);
    if (!method) return;
    if (old) *old = method_getImplementation(method);
    if (!class_addMethod(_class, message, hook, method_getTypeEncoding(method))) method_setImplementation(method, hook);
}
