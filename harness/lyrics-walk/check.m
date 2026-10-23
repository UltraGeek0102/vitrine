// Checks the walk down the sources' order and a source picked from the player's ⋯ (LyricsSources.m,
// LyricsPick.m) without the phone or the network: every source is answered here, by key, so a walk, a pick,
// a later walk with the pick's request failing or answering nothing, a pick landing while the walk runs, and
// Automatic after each can be driven on the Mac. Exits non-zero on the first wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Settings/SGSourcesPage.h"
#import "Settings/SGPageStyle.h"
#import "Core/SGFlagForce.h"
#import "Headers/SPTPlayer.h"

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

// What the walk and the pick reach outside themselves for. Every track is a named local file, so the sources
// that search by name are asked at once.
NSString *const SGSpicyLyricsKey = @"spicylyrics";
NSString *const SGImportedLRCKey = @"importedLRC";
NSString *SGSpicyLyricsStatus(void) { return nil; }
BOOL SGLocalFileIs(NSString *uri) { return NO; }
NSDictionary<NSString *, id> *SGLocalFileInfo(NSString *uri) { return @{@"title": @"a", @"artist": @"b", @"seconds": @200}; }
SPTPlayerTrack *SGKaraokeTrackFor(NSString *trackID) { return nil; }
BOOL SGLyricsStandAsideForEevee(void) { return NO; }
void SGRegisterFlagForcer(BOOL beatsOverride, SGFlagForcer atLaunch, SGFlagForcer locked) {}
UIViewController *SGTopController(void) { return nil; }
UIViewController *SGSourcesPageMake(NSString *title, NSString *note, NSArray<SGSource *> *all,
                                    NSArray<NSString *> *(^order)(void), void (^setOrder)(NSArray<NSString *> *keys)) { return nil; }
@implementation SGSource
+ (instancetype)sourceWithKey:(NSString *)key name:(NSString *)name detail:(NSString *)detail { return nil; }
@end

// The lyrics view: the lines kept for each track, NSNull once kept as none, and the tracks asked for again.
static NSMutableDictionary<NSString *, id> *sg_shown;
static NSMutableArray<NSString *> *sg_askedAgain;
void SGKaraokeKeepLines(NSString *track, NSArray<SGKaraokeLine *> *lines) { sg_shown[track] = lines ?: NSNull.null; }
NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *track) {
    id lines = sg_shown[track];
    return lines == NSNull.null ? nil : lines;
}
void SGKaraokeAskAgain(NSString *track) {
    [sg_askedAgain addObject:track];
    [sg_shown removeObjectForKey:track];
}

// The sources, answered by key: a fresh result each ask, nil for none. One key may be held until release()
// runs, for what lands while the walk waits on it. Every ask is listed as "key:track".
typedef SGLyricsResult *(^SGAnswer)(void);
static NSMutableDictionary<NSString *, SGAnswer> *sg_answers;
static NSMutableArray<NSString *> *sg_asked;
static NSString *sg_held;
static void (^sg_release)(void);

static void answer(NSString *key, SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    [sg_asked addObject:[NSString stringWithFormat:@"%@:%@", key, query.trackID]];
    void (^now)(void) = ^{
        SGAnswer answer = sg_answers[key];
        done(answer ? answer() : nil);
    };
    if ([key isEqualToString:sg_held]) sg_release = now;
    else now();
}
#define ASK(name, key) SGLyricsAsk name = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) { answer(key, query, done); };
ASK(SGBiniLyricsAsk, @"binilyrics")
ASK(SGMusixmatchAsk, @"musixmatch")
ASK(SGUnisonAsk, @"unison")
ASK(SGNetEaseAsk, @"netease")
ASK(SGLrcLibAsk, @"lrclib")
ASK(SGSpicyLyricsAsk, @"spicylyrics")
ASK(SGQQMusicAsk, @"qqmusic")
ASK(SGKuGouAsk, @"kugou")
ASK(SGImportedLRCAsk, @"importedLRC")
ASK(SGGeniusAsk, @"genius")

// Two lines, timed by the line or not at all, with the page's text made from them as a source would.
static SGAnswer lines(BOOL timed) {
    return ^SGLyricsResult *{
        SGLyricsResult *result = [SGLyricsResult new];
        result.karaokeLines = timed ? SGKaraokeEstimatedLines(@[@1000, @2000], @[@"a", @"b"]) : SGKaraokeStaticLines(@[@"a", @"b"]);
        result.synced = timed;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(result.karaokeLines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        return result;
    };
}

// A request lost on the way: counted as every source's are, so the walk knows nothing was not no lyrics.
static SGAnswer failing(void) {
    return ^SGLyricsResult *{
        SGLyricsNoteReply(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
        return nil;
    };
}

static void pump(BOOL (^until)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!until() && deadline.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    CHECK(until());
}

static SGLyricsResult *fetch(NSString *track) {
    __block BOOL answered = NO;
    __block SGLyricsResult *got = nil;
    SGLyricsFetch(track, ^(SGLyricsResult *result) {
        got = result;
        answered = YES;
    });
    pump(^BOOL { return answered; });
    return got;
}

static NSDictionary<NSString *, SGLyricsResult *> *offers(NSString *track) {
    __block NSDictionary<NSString *, SGLyricsResult *> *got = nil;
    SGLyricsOffers(track, 0, ^(NSDictionary<NSString *, SGLyricsResult *> *offered) { got = offered; });
    pump(^BOOL { return got != nil; });
    return got;
}

// The walk keeps its answers for 40 tracks and then forgets them all: 40 other tracks walked forget the ones
// before. The same 40 picked forget what Automatic puts back for the ones before.
static NSUInteger sg_others;
static void walkOthers(BOOL picked) {
    sg_answers[@"musixmatch"] = lines(YES);
    for (NSUInteger i = 0; i < 40; i++) {
        NSString *track = [NSString stringWithFormat:@"other%lu", (unsigned long)++sg_others];
        if (!picked) {
            fetch(track);
            continue;
        }
        offers(track);
        SGLyricsChooseSource(track, @"musixmatch");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        sg_shown = [NSMutableDictionary dictionary];
        sg_askedAgain = [NSMutableArray array];
        sg_answers = [NSMutableDictionary dictionary];
        sg_asked = [NSMutableArray array];
        // The order, read from the defaults, without writing the Mac's.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{SGKeyLyricsProviders: @[@"musixmatch", @"lrclib", @"netease", @"genius"]}
                                                       forName:NSArgumentDomain];
        sg_answers[@"musixmatch"] = lines(YES);
        sg_answers[@"lrclib"] = lines(YES);
        sg_answers[@"netease"] = lines(YES);
        sg_answers[@"genius"] = lines(NO);

        // The walk stops at the first timed answer, the order's first, and its answer is nobody's pick.
        SGLyricsResult *got = fetch(@"t1");
        CHECK([got.provider isEqualToString:@"Musixmatch"] && got.synced && !got.picked);
        CHECK([sg_asked isEqualToArray:@[@"musixmatch:t1"]]);

        // A pick from the player's ⋯: the source's answer is the track's, marked as the pick's, and shows.
        NSDictionary *offered = offers(@"t1");
        CHECK(offered[@"musixmatch"] && offered[@"lrclib"] && offered[@"netease"]);
        SGLyricsChooseSource(@"t1", @"lrclib");
        got = fetch(@"t1");
        CHECK([got.provider isEqualToString:@"LRCLIB"] && got.picked && [SGLyricsChosenSource(@"t1") isEqualToString:@"lrclib"]);
        CHECK(sg_shown[@"t1"] == got.karaokeLines && [SGLyricsCreditFor(@"t1") isEqualToString:@"LRCLIB"]);

        // A later walk asks the pick first, and its lines are the walk's answer, as the pick's.
        walkOthers(NO);
        [sg_asked removeAllObjects];
        got = fetch(@"t1");
        CHECK([sg_asked isEqualToArray:@[@"lrclib:t1"]]);
        CHECK([got.provider isEqualToString:@"LRCLIB"] && got.picked);

        // The pick's request fails: the pick stands, the walk goes on, and its answer is kept as the order's
        // rather than as the pick's, so Spotify's own lines weigh against it. The next walk asks the pick again.
        walkOthers(NO);
        sg_answers[@"lrclib"] = failing();
        [sg_asked removeAllObjects];
        got = fetch(@"t1");
        CHECK([sg_asked isEqualToArray:(@[@"lrclib:t1", @"musixmatch:t1"])]);
        CHECK([got.provider isEqualToString:@"Musixmatch"] && !got.picked && [SGLyricsChosenSource(@"t1") isEqualToString:@"lrclib"]);
        CHECK(fetch(@"t1") == got);   // kept
        sg_answers[@"lrclib"] = lines(YES);
        walkOthers(NO);
        got = fetch(@"t1");
        CHECK([got.provider isEqualToString:@"LRCLIB"] && got.picked);

        // The pick has nothing: dropped, and the walk's answer is the order's.
        walkOthers(NO);
        sg_answers[@"lrclib"] = nil;
        got = fetch(@"t1");
        CHECK([got.provider isEqualToString:@"Musixmatch"] && !got.picked && !SGLyricsChosenSource(@"t1"));
        sg_answers[@"lrclib"] = lines(YES);

        // A pick made while the walk runs stands, with the walk begun on an earlier pick. That walk asked the
        // earlier pick first, so its answer is not what the order would choose: Automatic puts back what the
        // track showed before any pick, and the next request walks the order again.
        NSArray<SGKaraokeLine *> *spotify = SGKaraokeStaticLines(@[@"s"]);
        sg_shown[@"t2"] = spotify;
        offers(@"t2");
        SGLyricsChooseSource(@"t2", @"lrclib");
        CHECK(![sg_shown[@"t2"] isEqualToArray:spotify]);
        walkOthers(NO);
        sg_held = @"lrclib";
        __block SGLyricsResult *late = nil;
        SGLyricsFetch(@"t2", ^(SGLyricsResult *result) { late = result; });
        pump(^BOOL { return sg_release != nil; });
        SGLyricsChooseSource(@"t2", @"netease");
        sg_held = nil;
        sg_release();
        sg_release = nil;
        pump(^BOOL { return late != nil; });
        CHECK([late.provider isEqualToString:@"NetEase"] && late.picked && [SGLyricsChosenSource(@"t2") isEqualToString:@"netease"]);
        SGLyricsChooseAutomatic(@"t2");
        CHECK(!SGLyricsChosenSource(@"t2") && [sg_shown[@"t2"] isEqualToArray:spotify] && [SGLyricsCreditFor(@"t2") isEqualToString:@"Spotify"]);
        [sg_asked removeAllObjects];
        got = fetch(@"t2");
        CHECK([sg_asked isEqualToArray:@[@"musixmatch:t2"]] && [got.provider isEqualToString:@"Musixmatch"] && !got.picked);

        // Automatic once what it puts back is forgotten, 40 picks later: the track is asked for again as on a
        // first play, and the lines it shows are never dropped for none.
        offers(@"t3");
        SGLyricsChooseSource(@"t3", @"lrclib");
        walkOthers(YES);
        CHECK([SGLyricsChosenSource(@"t3") isEqualToString:@"lrclib"]);
        [sg_answers removeAllObjects];
        SGLyricsChooseAutomatic(@"t3");
        pump(^BOOL { return sg_askedAgain.count > 0; });
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        CHECK(!SGLyricsChosenSource(@"t3") && [sg_askedAgain isEqualToArray:@[@"t3"]] && !sg_shown[@"t3"]);
        CHECK(!fetch(@"t3"));

        printf("lyrics-walk: all checks passed\n");
    }
    return 0;
}
