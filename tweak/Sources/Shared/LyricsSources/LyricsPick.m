// A source picked for one track (issue #67). The walk stops at the first source with timed lyrics, so a source
// lower in the order that has the song better timed is never asked; the redesigned player's ⋯ asks them all for
// the track playing, lists the ones with lines, and keeps the one picked as the track's lyrics.
//
// A pick keeps the source's answer as the track's, marked picked, and records what the track showed before it.
// A later walk asks the pick first: lines keep it, nothing drops it, a failed request leaves it and keeps the
// walk's answer unmarked. A pick made while a walk runs stands, and the walk's answer is recorded as the
// order's only when the walk ran the order as it is. Automatic puts the record back, or with the record gone
// has the lyrics asked for again as on a first play.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"

NSNotificationName const SGLyricsSourceChosenNotification = @"spotifyglass.lyricsSourceChosen";

// Each track's asks are kept for the menu opened on it again; the picks are kept for the replays, and what
// Automatic puts back, which holds lines, for as many tracks as the walk keeps.
static const NSUInteger kAskedTracks = 10, kChosenTracks = 200, kAutomaticTracks = 40;

// Every source asked for one track, and who waits for them all.
@interface SGLyricsOfferAsk : NSObject
@property (nonatomic, copy) NSString *trackID;
// A result with lines, else NSNull. A source unasked for want of a name, or whose request may have failed, has
// none, and is asked again the next time the menu opens, as is one switched on since.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *answers;
@property (nonatomic, strong) NSMutableSet<NSString *> *asking;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *waiting;
@end

@implementation SGLyricsOfferAsk
@end

// What a track showed before its first pick, the order's choice, for Automatic to put back.
@interface SGLyricsAutomatic : NSObject
@property (nonatomic, strong) id kept;   // the walk's kept answer, as SGLyricsKeptAnswer reads it
@property (nonatomic, copy) NSString *credit;
@property (nonatomic, copy) NSArray<SGKaraokeLine *> *lines;
@end

@implementation SGLyricsAutomatic
@end

static NSMutableDictionary<NSString *, SGLyricsOfferAsk *> *sg_asks;
static NSMutableDictionary<NSString *, NSString *> *sg_chosen;
static NSMutableDictionary<NSString *, SGLyricsAutomatic *> *sg_automatic;   // the last tracks in sg_chosen

NSString *SGLyricsChosenSource(NSString *trackID) {
    return trackID ? sg_chosen[trackID] : nil;
}

static NSDictionary<NSString *, SGLyricsResult *> *offersIn(SGLyricsOfferAsk *ask) {
    NSMutableDictionary<NSString *, SGLyricsResult *> *offers = [NSMutableDictionary dictionary];
    [ask.answers enumerateKeysAndObjectsUsingBlock:^(NSString *key, id answer, BOOL *stop) {
        if (answer != NSNull.null) offers[key] = answer;
    }];
    return offers;
}

// Asks every source in the order without an answer kept and not being asked already.
static void askMissing(SGLyricsOfferAsk *ask) {
    NSString *trackID = ask.trackID;
    NSMutableDictionary<NSString *, SGLyricsQuery *> *queries = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *key in SGLyricsOrder()) {
        if (ask.answers[key] || [ask.asking containsObject:key]) continue;
        // A query each, so what one source learns does not change what the next is asked.
        SGLyricsQuery *query = SGLyricsQueryFor(trackID);
        if (SGLyricsProviderFor(key).needsName && !(query.title.length && query.artist.length)) continue;
        queries[key] = query;
        [keys addObject:key];
    }
    if (!keys.count) return;
    SGLog(@"lyrics: asking %@ at once for %@, for the player's ⋯", [keys componentsJoinedByString:@", "], trackID);
    [ask.asking addObjectsFromArray:keys];
    for (NSString *key in keys) {
        SGLyricsProvider *provider = SGLyricsProviderFor(key);
        SGLyricsQuery *query = queries[key];
        NSUInteger failures = SGLyricsFailures();
        provider.ask(query, ^(SGLyricsResult *result) {
            if (result.karaokeLines.count && !result.provider) result.provider = provider.name;
            // As in the walk: nothing, while a request failed, may be a busy server rather than no lyrics.
            BOOL failed = !result.karaokeLines.count && SGLyricsFailures() != failures;
            SGLog(@"lyrics: %@ offers %lu lines for %@%@", key, (unsigned long)result.karaokeLines.count, trackID,
                  failed ? @", a request failed on the way; not kept" : @"");
            if (!failed) ask.answers[key] = result.karaokeLines.count ? result : NSNull.null;
            [ask.asking removeObject:key];
            if (ask.asking.count) return;
            NSArray *waiting = [ask.waiting copy];
            [ask.waiting removeAllObjects];
            for (void (^done)(void) in waiting) done();
        });
    }
}

void SGLyricsOffers(NSString *trackID, NSTimeInterval wait, void (^done)(NSDictionary<NSString *, SGLyricsResult *> *offers)) {
    if (!sg_asks) sg_asks = [NSMutableDictionary dictionary];
    SGLyricsOfferAsk *ask = sg_asks[trackID];
    if (!ask) {
        if (sg_asks.count >= kAskedTracks) [sg_asks removeAllObjects];
        ask = sg_asks[trackID] = [SGLyricsOfferAsk new];
        ask.trackID = trackID;
        ask.answers = [NSMutableDictionary dictionary];
        ask.asking = [NSMutableSet set];
        ask.waiting = [NSMutableArray array];
    }
    askMissing(ask);
    __block BOOL called = NO;
    void (^once)(void) = ^{
        if (called) return;
        called = YES;
        done(offersIn(ask));
    };
    if (!ask.asking.count) {
        once();
        return;
    }
    [ask.waiting addObject:once];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), once);
}

// The track's lines and credit everywhere they show, at once.
static void show(NSString *trackID, NSString *credit, NSArray<SGKaraokeLine *> *lines) {
    // The credit before the lines, which the lyrics page asks for once it has them.
    SGLyricsSetCredit(trackID, credit);
    SGKaraokeKeepLines(trackID, lines);
    // Queued behind the keep above, so a page that drops its lines on this finds the new ones kept.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsSourceChosenNotification object:trackID];
    });
}

void SGLyricsChooseSource(NSString *trackID, NSString *key) {
    id result = sg_asks[trackID].answers[key];
    if (![result isKindOfClass:SGLyricsResult.class]) return;
    SGLyricsResult *lyrics = result;
    if (!sg_chosen) {
        sg_chosen = [NSMutableDictionary dictionary];
        sg_automatic = [NSMutableDictionary dictionary];
    }
    if (sg_chosen.count >= kChosenTracks) [sg_chosen removeAllObjects];
    if (sg_automatic.count >= kAutomaticTracks && !sg_automatic[trackID]) [sg_automatic removeAllObjects];
    if (!sg_chosen[trackID]) {
        SGLyricsAutomatic *automatic = [SGLyricsAutomatic new];
        automatic.kept = SGLyricsKeptAnswer(trackID);
        automatic.credit = SGLyricsCreditFor(trackID);
        automatic.lines = SGKaraokeLinesForTrack(trackID);
        sg_automatic[trackID] = automatic;
    }
    sg_chosen[trackID] = key;
    SGLog(@"lyrics: %@ picked for %@, %lu lines", key, trackID, (unsigned long)lyrics.karaokeLines.count);
    SGLyricsKeepChosen(trackID, lyrics);
    show(trackID, lyrics.provider, lyrics.karaokeLines);
}

void SGLyricsNoteOrderChoice(NSString *trackID, SGLyricsResult *lyrics) {
    SGLyricsAutomatic *automatic = sg_automatic[trackID];
    if (!automatic || automatic.kept) return;
    automatic.kept = lyrics;
    automatic.credit = lyrics.provider;
    automatic.lines = lyrics.karaokeLines;
}

void SGLyricsDropChoice(NSString *trackID, NSString *key) {
    if (!trackID || ![sg_chosen[trackID] isEqualToString:key]) return;
    SGLog(@"lyrics: %@ gave %@ nothing or is off, back to Automatic", key, trackID);
    [sg_chosen removeObjectForKey:trackID];
    [sg_automatic removeObjectForKey:trackID];
}

void SGLyricsChooseAutomatic(NSString *trackID) {
    if (!trackID || !sg_chosen[trackID]) return;
    SGLyricsAutomatic *automatic = sg_automatic[trackID];
    [sg_chosen removeObjectForKey:trackID];
    [sg_automatic removeObjectForKey:trackID];
    // The order's answer when it was learned, else nothing, so the next request walks the order again.
    SGLyricsRestoreKept(trackID, automatic.kept);
    if (!automatic.lines) {
        // What the track showed is gone with its record, or was nothing while its walk ran: the lyrics are
        // asked for as on a first play, the order's answer weighed against Spotify's own where that is done.
        SGLog(@"lyrics: pick dropped for %@, asking again", trackID);
        SGKaraokeAskAgain(trackID);
        // The lyrics page drops the pick's lines on this and takes the answer as it comes.
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsSourceChosenNotification object:trackID];
        return;
    }
    SGLog(@"lyrics: pick dropped for %@, back to %@, %lu lines", trackID, automatic.credit, (unsigned long)automatic.lines.count);
    show(trackID, automatic.credit, automatic.lines);
}
