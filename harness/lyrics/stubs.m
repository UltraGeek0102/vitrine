// What SGRKaraokeView.m links against, answering the way the phone would for one track playing on a
// clock of the harness's own: the lines are whatever main.m keeps, the position runs from the launch
// line's -at at -rate, and holds at -pauseAt for -holdFor seconds before it runs on.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"

UIColor *SGRAccentColor(void) { return nil; }

NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
CFTimeInterval SGPlayerTransitionEnds(void) { return 0; }

void SGRPlayFeedback(NSInteger feedback) {}
void SGPlayFeedback(NSInteger feedback) {}   // the name it has had since Haptics moved to Shared
// -credit names the source (Show source is -spotifyglass.lyricsCredit 1); one naming Spicy Lyrics is
// required, so it shows either way, and links to two people, as SpicyLyrics.m's community syncs do.
NSString *SGLyricsCreditFor(NSString *trackID) { return [NSUserDefaults.standardUserDefaults stringForKey:@"credit"] ?: @"the harness"; }
// LyricsSources.h's, declared here: that header's SPTPlayerTrack clashes with the track stub below.
@interface SGLyricsLink : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSURL *url;
@end
@implementation SGLyricsLink
@end
BOOL SGLyricsCreditRequired(NSString *credit) { return [credit hasPrefix:@"Spicy Lyrics"]; }
NSArray<SGLyricsLink *> *SGLyricsCreditLinks(NSString *text) {
    if (![text containsString:@"Spicy Lyrics"]) return nil;
    NSMutableArray<SGLyricsLink *> *links = [NSMutableArray array];
    for (NSString *who in @[@"Uploader", @"Maker"]) {
        SGLyricsLink *link = [SGLyricsLink new];
        link.title = [who stringByAppendingString:@": harness"];
        link.url = [NSURL URLWithString:@"https://example.org/"];
        [links addObject:link];
    }
    return links;
}
void SGLyricsOpenCreditLinks(NSArray<SGLyricsLink *> *links, UIView *from) { NSLog(@"harness: credit opens %lu links", (unsigned long)links.count); }
// -translateTo es: the language the Lyrics page would ask translations for.
NSString *SGLyricsTranslationLanguage(void) { return [NSUserDefaults.standardUserDefaults stringForKey:@"translateTo"]; }

// -gemini 1: a Gemini key is set, and Translate with Gemini answers each line with itself, marked.
BOOL SGGeminiKeySet(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"gemini"]; }
NSString *SGLyricsGeminiLanguage(void) { return SGLyricsTranslationLanguage() ?: @"en"; }
void SGLyricsTranslateWithGemini(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                                 void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    NSMutableArray<NSString *> *translations = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) [translations addObject:[@"Gemini: " stringByAppendingString:SGKaraokeLineText(line)]];
    // -geminiDelay S: as late as a whole song through the real API can be.
    double delay = [NSUserDefaults.standardUserDefaults doubleForKey:@"geminiDelay"];
    if (delay <= 0) {
        done(translations, nil);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ done(translations, nil); });
}

// -onDevice 1 / -intelligence 1: Translate on iPhone and Apple Intelligence are offered, each answering every
// line with itself, marked.
@interface SGOnDeviceTranslation : NSObject
@end
@implementation SGOnDeviceTranslation
+ (BOOL)translationAvailable { return [NSUserDefaults.standardUserDefaults boolForKey:@"onDevice"]; }
+ (BOOL)appleIntelligenceAvailable:(NSString *)languageTag { return [NSUserDefaults.standardUserDefaults boolForKey:@"intelligence"]; }
+ (void)answer:(NSArray<NSString *> *)lines as:(NSString *)mark done:(void (^)(NSArray<NSString *> *, NSString *))done {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in lines) [out addObject:line.length ? [mark stringByAppendingString:line] : @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(out, nil); });
}
+ (void)translate:(NSArray<NSString *> *)lines to:(NSString *)languageTag done:(void (^)(NSArray<NSString *> *, NSString *))done {
    [self answer:lines as:@"iPhone: " done:done];
}
// A batch at a time, as the model works: the first half shows a second before the rest.
+ (void)translateWithAppleIntelligence:(NSArray<NSString *> *)lines to:(NSString *)languageTag song:(NSString *)song progress:(void (^)(NSArray<NSString *> *))progress
                                  done:(void (^)(NSArray<NSString *> *, NSString *))done {
    NSMutableArray<NSString *> *half = [NSMutableArray array];
    [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger i, BOOL *stop) {
        [half addObject:i < lines.count / 2 && line.length ? [@"Intelligence: " stringByAppendingString:line] : @""];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ progress(half); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self answer:lines as:@"Intelligence: " done:done]; });
}
@end
// Nothing is kept between runs of the harness.
void SGLyricsSyncSavedTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines) {}
NSNotificationName const SGLyricsTranslationsDidChangeNotification = @"spotifyglass.lyricsTranslationsDidChange";
void SGLyricsSaveTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines) {}

// Line meanings: -title and -artist name the track Genius is searched for, and the setting's key
// (-spotifyglass.lyricsMeanings 3) turns them on.
@interface SGHarnessTrack : NSObject
@property (nonatomic, copy) NSString *trackTitle, *artistName;
@end
@implementation SGHarnessTrack
@end
id SGKaraokeTrackFor(NSString *trackID) {
    SGHarnessTrack *track = [SGHarnessTrack new];
    track.trackTitle = [NSUserDefaults.standardUserDefaults stringForKey:@"title"];
    track.artistName = [NSUserDefaults.standardUserDefaults stringForKey:@"artist"];
    return track;
}
// lyrics-page links the real Settings/ framework, which has both.
#ifndef SG_HARNESS_SETTINGS
id SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray *choices, NSInteger fallback) { return nil; }
UIViewController *SGTopController(void) {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    UIViewController *top = scene.windows.firstObject.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}
#endif

static NSArray<SGKaraokeLine *> *sg_lines;
static double sg_from = -1, sg_rate = 1, sg_pauseAt = -1, sg_holdFor = 0;
static CFTimeInterval sg_since, sg_heldAt;

void SGHarnessStartClock(double at, double rate, double pauseAt, double holdFor) {
    sg_from = at;
    sg_rate = rate;
    sg_pauseAt = pauseAt;
    sg_holdFor = holdFor;
    sg_since = CACurrentMediaTime();
    sg_heldAt = 0;
}

NSString *SGKaraokePlayingTrack(void) { return @"harness"; }
NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *trackID) { return sg_lines; }
void SGKaraokeKeepLines(NSString *trackID, NSArray<SGKaraokeLine *> *lines) { sg_lines = lines; }

NSInteger SGKaraokeDelayMs(void) { return [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsDelay]; }

NSInteger SGKaraokePositionMs(void) {
    if (sg_from < 0) return -1;
    CFTimeInterval now = CACurrentMediaTime();
    double at = sg_from + (now - sg_since) * 1000 * sg_rate;
    if (sg_pauseAt >= 0 && at >= sg_pauseAt) {
        // Held where it was asked to stop, then on from there as if never stopped.
        if (!sg_heldAt) sg_heldAt = now;
        if (sg_holdFor <= 0 || now - sg_heldAt < sg_holdFor) return (NSInteger)sg_pauseAt;
        SGHarnessStartClock(sg_pauseAt, sg_rate, -1, 0);
        return (NSInteger)sg_pauseAt;
    }
    return (NSInteger)at;
}

// -seekLag S: the player reports a seek S seconds after it is asked for, as Spotify's takes a few frames.
void SGKaraokeSeek(NSInteger ms) {
    double lag = [NSUserDefaults.standardUserDefaults doubleForKey:@"seekLag"];
    if (lag <= 0) {
        SGHarnessStartClock(ms, sg_rate, -1, 0);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lag * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGHarnessStartClock(ms, sg_rate, -1, 0);
    });
}
// "“Title” by Artist" the translators are told.
NSString *SGLyricsSongName(NSString *trackID) { return @"“Sample” by Harness"; }
// Karaoke's settings tell the lyrics to show or hide the mic.
NSNotificationName const SGSingButtonDidChangeNotification = @"SGSingButtonDidChangeNotification";
