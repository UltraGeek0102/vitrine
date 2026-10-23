// Checks the Genius lyrics source without the phone: the search's pick of a song for a track
// (SGGeniusSongIn, SongMatch.m) on replies shaped like Genius's, with the titles and artists its search
// really gave for these tracks, and the lines read out of a made-up embed script (Genius.m). With
// `live`, the same tracks are searched on genius.com, the embed of each match is read, and the whole ask
// runs once; only line counts are printed, since the words are real lyrics. Exits non-zero on the first
// wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/LyricsSources/LyricsSources.h"
#import "Settings/SGModPage.h"

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

// What the files reach outside themselves for. The requests go to genius.com in live mode and
// answer nothing otherwise.
@implementation SGLyricsResult
@end
@implementation SGLyricsQuery
@end
NSInteger SGInt(NSString *key, NSInteger fallback) { return fallback; }
SGModRow *SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback) { return nil; }
SPTPlayerTrack *SGKaraokeTrackFor(NSString *trackID) { return nil; }
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {}
NSURL *SGLyricsURL(NSString *base, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *url = [NSURLComponents componentsWithString:base];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    return url.URL;
}
static BOOL sg_live;
static NSData *fetched(NSURL *url) {
    if (!sg_live) return nil;
    __block NSData *body = nil;
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([(NSHTTPURLResponse *)response statusCode] == 200) body = data;
        else fprintf(stderr, "%s answered %ld %s\n", url.absoluteString.UTF8String, (long)[(NSHTTPURLResponse *)response statusCode], error.description.UTF8String ?: "");
        dispatch_semaphore_signal(got);
    }] resume];
    dispatch_semaphore_wait(got, DISPATCH_TIME_FOREVER);
    return body;
}
void SGLyricsGetJSON(NSURL *url, NSDictionary *headers, void (^done)(id root)) {
    NSData *body = fetched(url);
    done(body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil);
}
void SGLyricsPostJSON(NSURL *url, NSDictionary *headers, id body, void (^done)(id root)) { done(nil); }
void SGLyricsGetText(NSURL *url, void (^done)(NSString *text)) {
    NSData *body = fetched(url);
    done(body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil);
}

// A search reply holding these hits, in this order: {id, title, primary artists, instrumental, artist_names}.
static NSDictionary *reply(NSArray<NSArray *> *hits) {
    NSMutableArray *results = [NSMutableArray array];
    for (NSArray *hit in hits) {
        NSMutableArray *primaries = [NSMutableArray array];
        for (NSString *name in hit[2]) [primaries addObject:@{@"name": name}];
        [results addObject:@{@"result": @{@"id": hit[0], @"title": hit[1], @"primary_artists": primaries,
                                          @"instrumental": @(hit.count > 3 && [hit[3] boolValue]),
                                          @"artist_names": hit.count > 4 ? hit[4] : [hit[2] componentsJoinedByString:@" & "]}}];
    }
    return @{@"sections": @[@{@"type": @"song", @"hits": results}]};
}

// Each track with the song it should get, 0 for none. The player names a track by its lead artist alone
// ("Lil Nas X"); a local file can carry the whole list. The hits are what genius.com's search answered
// for the track in October 2026, cut to the ones that matter, a few moved up to make the point.
static void checkPicks(void) {
    NSArray *cohen = @[@1063905, @"Hallelujah", @[@"Leonard Cohen"]];
    NSArray *buckley = @[@84894, @"Hallelujah", @[@"Jeff Buckley"]];
    NSArray *buckleyLive = @[@8723374, @"Hallelujah (Live at Bearsville Studios, New York - 1993)", @[@"Jeff Buckley"]];
    NSArray *buckleySpanish = @[@10518208, @"Jeff Buckley - Hallelujah (Traducción al Español)", @[@"Genius Traducciones al Español"]];
    NSArray *pentatonix = @[@2888288, @"Hallelujah", @[@"Pentatonix"]];
    NSArray *pentatonixFeat = @[@7457112, @"Hallelujah (Feat. The String Mob)", @[@"Pentatonix"]];
    NSDictionary *hallelujah = reply(@[cohen, buckleySpanish, buckleyLive, buckley, pentatonixFeat, pentatonix]);
    NSDictionary *oldTownRoad = reply(@[
        @[@7746352, @"Old Town Road (8-Bit Lil Nas X & Billy Ray Cyrus Emulation)", @[@"8-Bit Arcade"], @YES],
        @[@4486068, @"Lil Nas X & Billy Ray Cyrus - Old Town Road (Young Thug & Mason Ramsey Remix) (Traducción al Español)", @[@"Genius Traducciones al Español"]],
        @[@4514622, @"Old Town Road (Diplo Remix)", @[@"Lil Nas X", @"Billy Ray Cyrus", @"Diplo"]],
        @[@4445394, @"Old Town Road (Remix)", @[@"Lil Nas X"]],
        @[@4133841, @"Old Town Road", @[@"Lil Nas X"]],
    ]);
    NSDictionary *blindingLights = reply(@[
        @[@6181749, @"Blinding Lights (Remix)", @[@"The Weeknd", @"ROSALÍA"]],
        @[@5953339, @"Blinding Lights (Instrumental)", @[@"The Weeknd"], @YES],
        @[@8879997, @"Blinding Lights (Live)", @[@"The Weeknd"]],
        @[@5049949, @"Blinding Lights", @[@"The Weeknd"]],
    ]);
    NSArray *cases = @[
        // A song of the same name by someone featuring a "Queen Key" is not Queen's.
        @[@"Yesterday", @"Queen", reply(@[@[@14401144, @"Yesterday", @[@"HearonTrackz"], @NO, @"HearonTrackz (Ft. Fat Money & Queen Key)"], @[@11550811, @"Yesterday Is Dead", @[@"Josiah Queen"]]]), @0],
        // Covers: the singer's own page, never the song's writer's, and nothing when Genius has no page for the cover.
        @[@"Hallelujah", @"Jeff Buckley", hallelujah, @84894],
        @[@"Hallelujah", @"Pentatonix", hallelujah, @2888288],
        @[@"Hallelujah", @"Some Choir", hallelujah, @0],
        // Remixes: the one named, the plain remix over another's, the song over its remixes.
        @[@"Old Town Road (feat. Billy Ray Cyrus) - Remix", @"Lil Nas X", oldTownRoad, @4445394],
        @[@"Old Town Road (feat. Billy Ray Cyrus) - Remix", @"Lil Nas X, Billy Ray Cyrus", oldTownRoad, @4445394],
        @[@"Old Town Road - Diplo Remix", @"Lil Nas X", oldTownRoad, @4514622],
        @[@"Old Town Road", @"Lil Nas X", oldTownRoad, @4133841],
        @[@"Blinding Lights", @"The Weeknd", blindingLights, @5049949],
        @[@"Blinding Lights - Instrumental", @"The Weeknd", blindingLights, @0],
        // A remaster is the song.
        @[@"Bohemian Rhapsody - Remastered 2011", @"Queen", reply(@[@[@2123526, @"Bohemian Rhapsody", @[@"The Muppets"]], @[@1063, @"Bohemian Rhapsody", @[@"Queen"]]]), @1063],
        // Two leads, a comma inside a name, a name Genius writes twice over either way.
        @[@"Under Pressure", @"Queen, David Bowie", reply(@[@[@6868363, @"Queen & David Bowie - Under Pressure (Traducción al Español)", @[@"Genius Traducciones al Español"]], @[@152350, @"Under Pressure", @[@"Queen", @"David Bowie"]]]), @152350],
        @[@"EARFQUAKE", @"Tyler, The Creator", reply(@[@[@4420287, @"EARFQUAKE", @[@"Tyler, The Creator"]]]), @4420287],
        @[@"Dynamite", @"BTS", reply(@[@[@5813592, @"Dynamite", @[@"BTS (방탄소년단)"]]]), @5813592],
        // A local file's tag naming the guest after the lead.
        @[@"Old Town Road", @"Lil Nas X feat. Billy Ray Cyrus", oldTownRoad, @4133841],
        // A title with no word of its own matches nothing, not every untitled hit.
        @[@"(Untitled)", @"Lil Nas X", reply(@[@[@1, @"[Untitled]", @[@"Lil Nas X"]]]), @0],
        @[@"ЗНАК (SIGN)", @"Dora", reply(@[@[@13935027, @"ЗНАК (SIGN)", @[@"Toxi$", @"Дора (Dora)"]]]), @13935027],
    ];
    // A null where Genius sends a boolean is not instrumental, and does not throw.
    NSDictionary *nullHit = @{@"result": @{@"id": @1063, @"title": @"Bohemian Rhapsody", @"primary_artists": @[@{@"name": @"Queen"}], @"instrumental": NSNull.null}};
    CHECK([SGGeniusSongIn(@{@"sections": @[@{@"hits": @[nullHit]}]}, @"Bohemian Rhapsody", @"Queen") isEqual:@1063]);
    for (NSArray *c in cases) {
        NSNumber *song = SGGeniusSongIn(c[2], c[0], c[1]);
        printf("%s by %s: %s\n", [c[0] UTF8String], [c[1] UTF8String], song ? song.stringValue.UTF8String : "none");
        CHECK((song ?: @0).integerValue == [c[3] integerValue]);
    }
}

// A made-up embed in the shape genius.com/songs/:id/embed.js has: the HTML as a JSON string inside a
// single-quoted JavaScript string, escaped twice over.
static NSString *embedScript(NSString *html) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:html options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *string = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    string = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    string = [string stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    string = [string stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    string = [string stringByReplacingOccurrencesOfString:@"/" withString:@"\\/"];
    return [NSString stringWithFormat:@"if (document.getElementById('rg_embed_link_1')) {\n"
            "  document.write('<link rel=\"stylesheet\" href=\"x.css\" />')\n"
            "  document.write(JSON.parse('%@'))\n}\n", string];
}

static void checkEmbed(void) {
    NSString *html = @"\n  <div class=\"rg_embed music\" id=\"rg_embed_1\">\n    <div class=\"rg_embed_header\">x</div>\n"
        "    <div class=\"rg_embed_body\">\n  <p><a href=\"https://genius.com/1/A\" data-id=\"1\">[Verse 1]</a><br>\n"
        "<a href=\"https://genius.com/2/B\" data-id=\"2\">Filler line one, it&#39;s here<br>\nFiller &amp; line two</a><br>\n"
        "<i>Filler “line” three</i> &quot;quoted&quot; &#x2019;\n words<br>\n<br>\n<br>\n"
        "[Chorus: Someone]<br>\nFiller \\ line four <b>bold</b></p>\n\n</div>\n"
        "    <div class=\"rg_embed_footer\"><div class=\"song_title\">T</div></div>\n  </div>\n";
    NSArray<NSString *> *rows = SGGeniusEmbedRows(embedScript(html));
    printf("embed rows: %s\n", [rows componentsJoinedByString:@" | "].UTF8String);
    NSArray *want = @[@"Filler line one, it's here", @"Filler & line two", @"Filler “line” three \"quoted\" ’ words", @"",
                      @"Filler \\ line four bold"];
    CHECK([rows isEqualToArray:want]);
    // What is not the embed's shape, or an embed of a song whose words are not out yet, has no lines.
    CHECK(!SGGeniusEmbedRows(nil));
    CHECK(!SGGeniusEmbedRows(@"<!DOCTYPE html><title>Genius</title>"));
    CHECK(!SGGeniusEmbedRows(embedScript(@"<div class=\"rg_embed_body\">\n  \n</div>\n<div class=\"rg_embed_footer\"></div>")));
    CHECK(!SGGeniusEmbedRows(@"document.write(JSON.parse('\"unterminated"));
}

// The real thing, each track named as the player names it: searched on genius.com, the song it picks, and that song's embed read.
static void checkLive(void) {
    NSArray *tracks = @[
        @[@"Bohemian Rhapsody - Remastered 2011", @"Queen", @1063],
        @[@"Hallelujah", @"Jeff Buckley", @84894],
        @[@"Hallelujah", @"Pentatonix", @2888288],
        @[@"Old Town Road (feat. Billy Ray Cyrus) - Remix", @"Lil Nas X", @4445394],
        @[@"Blinding Lights", @"The Weeknd", @5049949],
        @[@"Under Pressure", @"Queen", @152350],
        @[@"Yesterday", @"Queen", @0],
        @[@"Blinding Lights - Instrumental", @"The Weeknd", @0],
    ];
    for (NSArray *t in tracks) {
        __block id root = nil;
        SGLyricsGetJSON(SGLyricsURL(SGGeniusSearchURL, SGGeniusSearchQuery(t[0], t[1])), nil, ^(id r) { root = r; });
        CHECK(root);
        NSNumber *song = SGGeniusSongIn(root[@"response"], t[0], t[1]);
        printf("live: %s by %s: %s", [t[0] UTF8String], [t[1] UTF8String], song ? song.stringValue.UTF8String : "none");
        CHECK((song ?: @0).integerValue == [t[2] integerValue]);
        if (!song) {
            printf("\n");
            continue;
        }
        __block NSString *js = nil;
        SGLyricsGetText([NSURL URLWithString:[NSString stringWithFormat:@"https://genius.com/songs/%@/embed.js", song]], ^(NSString *text) { js = text; });
        NSArray<NSString *> *rows = SGGeniusEmbedRows(js);
        NSUInteger stanzas = [rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length == 0"]].count;
        printf(", %lu rows in %lu stanzas\n", (unsigned long)rows.count, (unsigned long)stanzas + 1);
        CHECK(rows.count > 10);
        for (NSString *row in rows) {
            CHECK(![row containsString:@"<"] && ![row containsString:@">"] && ![row hasPrefix:@"["]);
            CHECK([row rangeOfString:@"&[a-z#0-9]+;" options:NSRegularExpressionSearch].location == NSNotFound);
        }
    }
    // The ask as the walk makes it: untimed lines, a ♪ for each gap.
    SGLyricsQuery *query = [SGLyricsQuery new];
    query.title = @"Hallelujah";
    query.artist = @"Jeff Buckley";
    __block SGLyricsResult *result = nil;
    SGGeniusAsk(query, ^(SGLyricsResult *r) { result = r; });
    printf("live ask: %lu lines, synced %d, timing %lu\n", (unsigned long)result.texts.count, result.synced,
           (unsigned long)SGKaraokeLinesTiming(result.karaokeLines));
    // The view's lines leave the ♪ out; Spotify's page keeps it.
    NSUInteger sung = [result.texts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != '♪'"]].count;
    CHECK(result.texts.count > 10 && !result.synced && result.karaokeLines.count == sung);
    CHECK(SGKaraokeLinesTiming(result.karaokeLines) == SGKaraokeTimingNone);
    CHECK([result.starts isEqualToArray:[result.starts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 0"]]]);
    CHECK([result.texts containsObject:@"♪"]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        sg_live = argc > 1 && !strcmp(argv[1], "live");
        checkPicks();
        checkEmbed();
        if (sg_live) checkLive();
        printf("all good\n");
    }
    return 0;
}
