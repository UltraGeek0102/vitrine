// Checks what is new in the lyrics sources and their words without the phone or the network: lines in
// Thai and the scripts like it split at the dictionary's words (KaraokeTiming.m), KuGou's KRC unpacked
// and read (KuGou.m, through NetEase.m's parser), and the QQ Music and KuGou asks matching a track
// against made-up search replies. The requests are answered here, by host. Any file named on the
// command line is a real KuGou download or QQ lyrics reply, saved as JSON, and only its line count is
// printed. Exits non-zero on the first wrong answer.
#import <UIKit/UIKit.h>
#import <zlib.h>
#import "Shared/LyricsSources/LyricsSources.h"

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

// What the sources reach outside themselves for: the requests, answered by sg_answer.
@implementation SGLyricsResult
@end
@implementation SGLyricsQuery
@end
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {
    NSMutableArray *at = [NSMutableArray array], *said = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        [at addObject:@(line.start)];
        [said addObject:SGKaraokeLineText(line)];
    }
    *starts = at;
    *texts = said;
}
void SGLyricsNoteReply(NSURLResponse *response, NSError *error) {}
NSURL *SGLyricsURL(NSString *base, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *url = [NSURLComponents componentsWithString:base];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    return url.URL;
}
// Musixmatch.m asks these of a local file, which no check here plays.
BOOL SGLocalFileIs(NSString *uri) { return NO; }
NSDictionary<NSString *, id> *SGLocalFileInfo(NSString *uri) { return nil; }
static id (^sg_answer)(NSURL *url, id body);
void SGLyricsGetJSON(NSURL *url, NSDictionary *headers, void (^done)(id root)) { done(sg_answer(url, nil)); }
void SGLyricsPostJSON(NSURL *url, NSDictionary *headers, id body, void (^done)(id root)) { done(sg_answer(url, body)); }

// LRCLIB reads a Lyricsfile off the main queue and answers back on it, so this runs the main queue
// until the answer comes. answeredAtOnce says whether it came before the ask returned.
static SGLyricsResult *lrclibAnswer(SGLyricsQuery *query, BOOL *answeredAtOnce) {
    __block SGLyricsResult *got = nil;
    __block BOOL answered = NO;
    SGLrcLibAsk(query, ^(SGLyricsResult *result) {
        CHECK(NSThread.isMainThread);
        got = result;
        answered = YES;
    });
    if (answeredAtOnce) *answeredAtOnce = answered;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!answered && deadline.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(answered);
    return got;
}

static NSString *param(NSURL *url, NSString *name) {
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:name]) return item.value;
    }
    return nil;
}

static NSArray<SGKaraokeWord *> *piecesOf(NSString *text) {
    return SGKaraokeStaticLines(@[text]).firstObject.words;
}

// The words of an unspaced token come back flush, so the line reads as it was written.
static void checkSplit(NSString *text, BOOL split) {
    NSArray<SGKaraokeWord *> *words = piecesOf(text);
    printf("%lu pieces: %s\n", (unsigned long)words.count, [[words valueForKey:@"text"] componentsJoinedByString:@"|"].UTF8String);
    CHECK([SGKaraokeLineText(SGKaraokeStaticLines(@[text]).firstObject) isEqualToString:text]);
    CHECK(!split || words.count > 1);
}

// KRC as KuGou packs it: "krc1", then the zlib of the text XORed with the key, all in base64.
static NSString *packed(NSString *krc, NSString *magic) {
    NSData *text = [krc dataUsingEncoding:NSUTF8StringEncoding];
    uLongf length = compressBound(text.length);
    NSMutableData *zipped = [NSMutableData dataWithLength:length];
    compress(zipped.mutableBytes, &length, text.bytes, text.length);
    zipped.length = length;
    static const uint8_t key[16] = {64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105};
    uint8_t *bytes = zipped.mutableBytes;
    for (NSUInteger i = 0; i < zipped.length; i++) bytes[i] ^= key[i % 16];
    NSMutableData *all = [[magic dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [all appendData:zipped];
    return [all base64EncodedStringWithOptions:0];
}

static NSString *const kKRC = @"﻿[id:$00000000]\r\n[ar:Someone]\r\n"
    "[1000,2000]<0,500,0>Hel<500,300,0>lo <800,700,0>world\r\n"
    "[4000,1500]<0,400,0>你<400,400,0>好<800,0,0>啊\r\n"
    "[7000,100]<0,300,0>late\r\n";

// Every line's words read back as its text, the spaces aside, and start in order inside it.
static void checkWordLines(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        CHECK(line.timing != SGKaraokeTimingWords || line.words.count);
        for (NSUInteger i = 0; i < line.words.count; i++) {
            CHECK(line.words[i].start >= line.start && line.words[i].end > line.words[i].start && line.words[i].end <= line.end);
            CHECK(!i || line.words[i].start >= line.words[i - 1].start);
        }
    }
}

static void checkLive(NSString *path) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    if (root[@"lyricsfile"]) {
        // An LRCLIB record: one that times words reads as word timed lines with the text it had.
        NSArray<SGKaraokeLine *> *lines = SGLyricsfileLines(root[@"lyricsfile"]);
        NSUInteger words = 0, timed = 0;
        NSInteger startSum = 0;
        for (SGKaraokeLine *line in lines) {
            words += line.words.count;
            timed += line.timing == SGKaraokeTimingWords;
            startSum += line.start;
        }
        printf("%s: Lyricsfile, %lu lines (%lu word timed), %lu words, starts sum %ld\n", path.lastPathComponent.UTF8String,
               (unsigned long)lines.count, (unsigned long)timed, (unsigned long)words, (long)startSum);
        CHECK(!!lines == [root[@"hasWordSync"] boolValue]);
        checkWordLines(lines);
        return;
    }
    if (root[@"content"]) {
        NSArray<SGKaraokeLine *> *lines = SGKuGouLines(root[@"content"]);
        printf("%s: KRC, %lu word timed lines; first \"%s\" at %ld\n", path.lastPathComponent.UTF8String, (unsigned long)lines.count,
               SGKaraokeLineText(lines.firstObject).UTF8String, (long)lines.firstObject.start);
        CHECK(lines.count);
        return;
    }
    id lyric = root[@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"][@"data"][@"lyric"];
    NSString *lrc = [[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:lyric options:0] encoding:NSUTF8StringEncoding];
    SGLyricsResult *result = SGLyricsLRCResult(lrc);
    printf("%s: QQ LRC, %lu timed lines\n", path.lastPathComponent.UTF8String, (unsigned long)result.karaokeLines.count);
    CHECK(result.synced && result.karaokeLines.count);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Thai, Lao, Khmer and Burmese, long lines with no space, and Thai among Latin and brackets.
        checkSplit(@"ฉันรักเธอมากกว่าสิ่งใดในโลกนี้และจะอยู่เคียงข้างเธอตลอดไป", YES);
        checkSplit(@"วันนี้อากาศดีมากเราไปเดินเล่นที่สวนสาธารณะด้วยกันไหมนะที่รัก", YES);
        checkSplit(@"Baby(ที่รัก)ฉันคิดถึงเธอทุกวันทุกคืนไม่เคยลืมเลย,ok?", YES);
        checkSplit(@"ฉันรักเธอ, เธอรักฉัน... (ด้วยหัวใจ)", YES);
        CHECK([piecesOf(@"(ด้วยหัวใจ)").firstObject.text isEqualToString:@"(ด้วย"]);   // what comes before the first word stays with it
        checkSplit(@"ຂ້ອຍຮັກເຈົ້າຫຼາຍທີ່ສຸດໃນໂລກນີ້ແລະຈະຢູ່ນຳເຈົ້າຕະຫຼອດໄປ", NO);
        checkSplit(@"ខ្ញុំស្រលាញ់អ្នកខ្លាំងណាស់ហើយនឹងនៅជាមួយអ្នកជារៀងរហូត", NO);
        checkSplit(@"ကျွန်တော်မင်းကိုအရမ်းချစ်တယ်ထာဝရမင်းနဲ့အတူရှိနေမယ်", NO);
        CHECK(piecesOf(@"๏๚").count == 1);   // Thai punctuation alone: no word, one piece
        CHECK(piecesOf(@"hello world").count == 2 && !piecesOf(@"hello world")[1].joined);
        CHECK(piecesOf(@"日本語の歌").count == 5 && piecesOf(@"日本語の歌")[4].joined);
        NSArray<SGKaraokeWord *> *thai = piecesOf(@"ฉันรักเธอมากกว่าสิ่งใดในโลกนี้");
        CHECK(!thai[0].joined && thai[1].joined);

        // The keys the two catalogs are matched by.
        CHECK([SGLyricsMatchKey(@"晴天（Live版）") isEqualToString:SGLyricsMatchKey(@"晴天 (Live版)")]);
        CHECK([SGLyricsMatchKey(@"Hello,　World!") isEqualToString:@"helloworld"]);
        CHECK([SGLyricsMatchKey(@"《稻香》") isEqualToString:@"稻香"]);
        CHECK([SGLyricsLeadArtist(@"周杰伦 feat. 费玉清") isEqualToString:@"周杰伦"]);
        CHECK(SGLyricsSameArtist(@"周杰伦、费玉清", @"周杰伦 Feat. Someone") && !SGLyricsSameArtist(@"林俊杰", @"周杰伦"));
        CHECK(!SGLyricsSameArtist(@"", @"周杰伦") && !SGLyricsSameArtist(nil, @"x"));

        // KRC: pieces timed from their line's start, a spaced word's pieces run together, a syllable each
        // in Chinese, a piece of no length shown for 1 ms, a line ending at its last word when that is later.
        NSArray<SGKaraokeLine *> *lines = SGKuGouLines(packed(kKRC, @"krc1"));
        CHECK(lines.count == 3);
        CHECK([SGKaraokeLineText(lines[0]) isEqualToString:@"Hello world"] && lines[0].words.count == 2);
        CHECK(lines[0].words[0].start == 1000 && lines[0].words[0].end == 1800 && lines[0].words[1].start == 1800);
        CHECK(lines[0].start == 1000 && lines[0].end == 3000 && lines[0].timing == SGKaraokeTimingWords);
        CHECK(lines[1].words.count == 3 && [SGKaraokeLineText(lines[1]) isEqualToString:@"你好啊"]);
        CHECK(lines[1].words[1].joined && lines[1].words[2].start == 4800 && lines[1].words[2].end == 4801);
        CHECK(lines[2].end == 7300);
        // NetEase's yrc, timed from the track's start: "wan" runs on into "ted ", and a piece after one
        // with no space after it runs on into it even when it opens with a space of its own.
        lines = SGLyricsPieceLines(@"[1000,3000](1000,200,0)wan(1200,300,0)ted (1500,0,0)to(1600,100,0) go\n"
            "[5000,1000](5000,100,0)你(5100,100,0)好", NO);
        CHECK(lines.count == 2 && [SGKaraokeLineText(lines[0]) isEqualToString:@"wanted togo"]);
        CHECK(lines[0].words[0].start == 1000 && lines[0].words[0].end == 1500 && !lines[0].words[0].joined);
        CHECK(lines[0].words[1].start == 1500 && lines[0].words[1].end == 1700 && !lines[0].words[1].joined);
        CHECK(lines[0].start == 1000 && lines[0].end == 4000);
        CHECK(lines[1].words.count == 2 && lines[1].words[1].joined && lines[1].words[1].start == 5100 && lines[1].end == 6000);
        CHECK(!SGLyricsPieceLines(@"[1000,3000]", NO) && !SGLyricsPieceLines(@"", NO));
        // A piece run on into a word that is sung longer leaves the word's end where it was.
        lines = SGLyricsPieceLines(@"[1000,500](1000,800,0)ab(1200,100,0)cd ", NO);
        CHECK(lines.count == 1 && lines[0].words.count == 1 && lines[0].words[0].end == 1800 && lines[0].end == 1800);

        // Musixmatch's richsync: an entry's offset is from its line's start, and only an entry of spaces
        // ends a word, so "Mil" "ion" is one word and "ab" " cd" another. A word is sung until the next
        // word starts, the last until a space after it or the line's end; a syllable of an unspaced
        // script is a word of its own, joined to the one before.
        SGLyricsResult *rich = SGMusixmatchRichsyncResult(@[
            @{@"ts": @10, @"te": @14, @"x": @"Milion +, go", @"l": @[@{@"c": @"Mil", @"o": @0}, @{@"c": @"ion", @"o": @0.3}, @{@"c": @" ", @"o": @0.6},
                @{@"c": @"+", @"o": @0.8}, @{@"c": @",", @"o": @0.9}, @{@"c": @" ", @"o": @1.0}, @{@"c": @"go", @"o": @1.5}]},
            @{@"ts": @20, @"te": @22, @"l": @[@{@"c": @"a", @"o": @0}, @{@"c": @" ", @"o": @0.5}]},
            @{@"ts": @30, @"te": @31, @"l": @[@{@"c": @"日", @"o": @0}, @{@"c": @"本", @"o": @0}]},
            @{@"ts": @40, @"te": @42, @"l": @[@{@"c": @"ab", @"o": @0}, @{@"c": @" cd", @"o": @0.5}, @{@"c": @5, @"o": @0.7}]},
            @{@"ts": @50, @"te": @51, @"l": @[@{@"c": @" ", @"o": @0}]},
        ]);
        NSArray<SGKaraokeLine *> *rl = rich.karaokeLines;
        CHECK(rich.wordTimed && rl.count == 4);
        CHECK([SGKaraokeLineText(rl[0]) isEqualToString:@"Milion +, go"] && rl[0].start == 10000 && rl[0].end == 14000);
        CHECK(rl[0].words[0].start == 10000 && rl[0].words[0].end == 10800 && rl[0].words[1].start == 10800 && rl[0].words[1].end == 11500);
        CHECK(rl[0].words[2].start == 11500 && rl[0].words[2].end == 14000 && !rl[0].words[1].joined && !rl[0].words[2].joined);
        CHECK(rl[1].words.count == 1 && rl[1].words[0].end == 20500 && rl[1].end == 22000);
        CHECK(rl[2].words.count == 2 && rl[2].words[0].end == 30000 && rl[2].words[1].joined && rl[2].words[1].end == 31000);
        CHECK([SGKaraokeLineText(rl[3]) isEqualToString:@"abcd"] && rl[3].words[0].start == 40000 && rl[3].words[0].end == 42000);
        CHECK(([rich.texts isEqualToArray:@[@"Milion +, go", @"♪", @"a", @"♪", @"日本", @"♪", @"abcd", @""]]));
        CHECK(!SGMusixmatchRichsyncResult(@[]) && !SGMusixmatchRichsyncResult(@"x"));
        // An entry run on into a word after the line's end is sung to its own end, not cut off before it.
        rl = SGMusixmatchRichsyncResult(@[@{@"ts": @60, @"te": @61, @"l": @[@{@"c": @"ab", @"o": @0}, @{@"c": @"cd", @"o": @2}]}]).karaokeLines;
        CHECK(rl.count == 1 && rl[0].words.count == 1 && rl[0].words[0].end == 62000 && rl[0].end == 62000);
        CHECK(!SGKuGouLines(packed(kKRC, @"krc2")) && !SGKuGouLines(@"bm90IGtyYw==") && !SGKuGouLines(nil));
        CHECK(!SGKuGouLines(packed(@"[ar:only tags]", @"krc1")));

        // KuGou: the user uploads, another title, another singer, a length 21 s off and a candidate with
        // no key are passed over; the rest are tried closest in length first, three at most.
        NSArray *candidates = @[
            @{@"id": @"a", @"accesskey": @"k", @"product_from": @"ugc", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @269000},
            @{@"id": @"b", @"accesskey": @"k", @"song": @"晴天 (Live)", @"singer": @"周杰伦", @"duration": @269000},
            @{@"id": @"c", @"accesskey": @"k", @"song": @"晴天", @"singer": @"Other", @"duration": @269000},
            @{@"id": @"d", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @290000},
            @{@"id": @"e", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @265000},
            @{@"id": @7, @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @269500},
            @{@"id": @"g", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @262000},
            @{@"id": @"h", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @270000},
            @{@"id": @"i", @"accesskey": @"k", @"song": @" 晴天！", @"singer": @"周杰伦、费玉清", @"duration": @"268000"},
        ];
        NSMutableArray<NSString *> *tried = [NSMutableArray array];
        __block NSString *keyword, *duration, *good = @"e";
        sg_answer = ^id(NSURL *url, id body) {
            if ([url.host isEqualToString:@"krcs.kugou.com"]) {
                keyword = param(url, @"keyword");
                duration = param(url, @"duration");
                return @{@"status": @200, @"candidates": candidates};
            }
            NSString *song = param(url, @"id");
            [tried addObject:song];
            if ([song isEqualToString:good]) return @{@"status": @200, @"content": packed(kKRC, @"krc1")};
            return [song isEqualToString:@"7"] ? @{@"status": @200, @"content": @"garbage"} : @{@"status": @404};
        };
        SGLyricsQuery *query = [SGLyricsQuery new];
        query.title = @"晴天";
        query.artist = @"周杰伦 feat. Someone";
        query.seconds = 269;
        __block SGLyricsResult *got = nil;
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([keyword isEqualToString:@"周杰伦 - 晴天"] && [duration isEqualToString:@"269000"]);
        CHECK([tried isEqualToArray:(@[@"7", @"i", @"e"])]);
        CHECK(got.synced && got.wordTimed && got.karaokeLines.count == 3 && got.texts.count == 3);
        [tried removeAllObjects];
        good = @"g";   // fourth in line: never asked
        got = [SGLyricsResult new];
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([tried isEqualToArray:(@[@"7", @"i", @"e"])] && !got);
        query.artist = @"";
        got = [SGLyricsResult new];
        [tried removeAllObjects];
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(!got && !tried.count);

        // QQ Music: the first result with the title, a singer and the length is taken, and its LRC read.
        NSString *lrc = @"[ti:x]\n[ar:y]\n[00:01.00]第一行\n[00:03.50]第二行\n";
        __block NSDictionary *asked = nil;
        sg_answer = ^id(NSURL *url, NSDictionary *body) {
            if (body[@"req"]) return @{@"req": @{@"data": @{@"body": @{@"song": @{@"list": @[
                @{@"title": @"晴天", @"interval": @269, @"singer": @[@{@"name": @"Someone Else"}], @"id": @1},
                @{@"title": @"晴天", @"interval": @300, @"singer": @[@{@"name": @"周杰伦"}], @"id": @2},
                @{@"title": @"雨天", @"interval": @269, @"singer": @[@{@"name": @"周杰伦"}], @"id": @3},
                @{@"songname": @"晴天", @"interval": @270, @"singer": @[@{@"name": @"x"}, @{@"name": @"周杰伦"}], @"id": @97773},
            ]}}}}};
            asked = body[@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"][@"param"];
            NSString *encoded = [[lrc dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            return @{@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo": @{@"data": @{@"lyric": encoded}}};
        };
        query.artist = @"周杰伦";
        got = nil;
        SGQQMusicAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([asked[@"songID"] isEqual:@97773] && [asked[@"qrc"] isEqual:@0] && [asked[@"crypt"] isEqual:@0]);
        CHECK(got.synced && !got.wordTimed && got.karaokeLines.count == 2 && got.karaokeLines[1].start == 3500);
        query.seconds = 200;   // no recording that long: nothing asked for lyrics
        asked = nil;
        got = [SGLyricsResult new];
        SGQQMusicAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(!got && !asked);

        // Lyricsfile: the spec's own example, two words timed to the end of each.
        NSArray<SGKaraokeLine *> *lf = SGLyricsfileLines(@"version: '1.0'\n\nmetadata:\n  title: 'Example Song'\n  artist: 'Example Artist'\n"
            "  language: 'en'\n  instrumental: false\n\nlines:\n  - text: 'Hello world'\n    start_ms: 1200\n    end_ms: 2800\n    words:\n"
            "      - text: 'Hello '\n        start_ms: 1200\n        end_ms: 1900\n      - text: 'world'\n        start_ms: 1900\n        end_ms: 2800\n\n"
            "plain: |\n  Hello world\n");
        CHECK(lf.count == 1 && lf[0].words.count == 2 && [SGKaraokeLineText(lf[0]) isEqualToString:@"Hello world"]);
        CHECK(lf[0].start == 1200 && lf[0].end == 2800 && lf[0].timing == SGKaraokeTimingWords);
        CHECK(lf[0].words[0].end == 1900 && lf[0].words[1].start == 1900 && !lf[0].words[1].joined);

        // As LRCLIB writes it: keys in any order, words with no end of their own ending where the next
        // starts and the last one with its line; a segment with no space after it runs into the next
        // one, Japanese syllables stay apart and flush, and a line timed only as a whole is estimated.
        // The rows a sequence's items start on are at its key's indent, quoted the way YAML quotes.
        NSString *lrclib = @"version: \"1.0\"\nmetadata:\n  title: ကမ္ဘာ\n  artist: Someone # a comment\nlines:\n"
            "- text: \"Hold on \"\n  words:\n  - text: \"Hold \"\n    start_ms: 48712\n  - text: \"on \"\n    start_ms: 49109\n  start_ms: 48712\n  end_ms: 52187\n"
            "- text: wanted now\n  start_ms: 53000\n  words:\n    - text: wan\n      start_ms: 53000\n    - text: \"ted \"\n      start_ms: 53200\n      end_ms: 53500\n"
            "    - {text: now}\n";
        CHECK(!SGLyricsfileLines(lrclib));   // a flow mapping is refused, and the whole file with it
        lrclib = [lrclib stringByReplacingOccurrencesOfString:@"    - {text: now}\n" withString:@"    - text: now\n      start_ms: 54000\n"];
        lrclib = [lrclib stringByAppendingString:@"- text: '''Cause I''m-'\n  start_ms: 60000\n  end_ms: 62000\n- text: ''\n  start_ms: 62000\n"
            "- text: \"\\u65e5\\u672c語\"\n  start_ms: 63000\n  end_ms: 64000\n  words:\n  - text: 日本\n    start_ms: 63000\n  - text: 語\n    start_ms: 63500\n"
            "plain: |-\n  Hold on\n\n  wanted now\n"];
        lf = SGLyricsfileLines(lrclib);
        CHECK(lf.count == 4);
        checkWordLines(lf);
        CHECK([SGKaraokeLineText(lf[0]) isEqualToString:@"Hold on"] && lf[0].words[0].end == 49109 && lf[0].words[1].end == 52187);
        CHECK(lf[1].words.count == 2 && [lf[1].words[0].text isEqualToString:@"wanted"] && lf[1].words[0].end == 53500);
        CHECK([lf[1].words[1].text isEqualToString:@"now"] && !lf[1].words[1].joined && lf[1].end == 55000);   // no end anywhere: a second past its last word
        CHECK([SGKaraokeLineText(lf[2]) isEqualToString:@"'Cause I'm-"] && lf[2].timing == SGKaraokeTimingLine && lf[2].start == 60000);
        CHECK(lf[3].words.count == 2 && lf[3].words[1].joined && [SGKaraokeLineText(lf[3]) isEqualToString:@"日本語"]);

        // LRCLIB's Lyricsfile for a record timed by the line alone: nothing the LRC does not have.
        CHECK(!SGLyricsfileLines(@"version: '1.0'\nmetadata:\n  title: a\n  artist: b\nlines:\n- text: Biatch!\n  start_ms: 90\n  end_ms: 960\n"));
        // Refused whole: another version, a key twice, a tab for indent, a negative time, an end before its
        // start, a quote never closed, words not a list, an alias, a stray row, not YAML at all.
        NSString *wordFile = @"version: '1.0'\nlines:\n- text: a\n  start_ms: 10\n  words:\n  - text: a\n    start_ms: 10\n";
        CHECK(SGLyricsfileLines(wordFile).count == 1);
        for (NSArray<NSString *> *swap in @[@[@"'1.0'", @"'2.0'"], @[@"  start_ms: 10\n  words", @"  start_ms: 10\n  start_ms: 11\n  words"],
                                            @[@"  start_ms: 10\n  words", @"\tstart_ms: 10\n  words"], @[@"    start_ms: 10", @"    start_ms: -10"],
                                            @[@"    start_ms: 10", @"    start_ms: 10\n    end_ms: 5"], @[@"- text: a", @"- text: \"a"],
                                            @[@"  - text: a\n    start_ms: 10\n", @"  a\n"], @[@"- text: a", @"- text: *a"],
                                            @[@"lines:", @"  stray\nlines:"], @[@"    start_ms: 10", @"    start_ms: 9223372036854775807"],
                                            @[@"- text: a", @"- text: \"\\u1\U0001F600\""]]) {
            CHECK(!SGLyricsfileLines([wordFile stringByReplacingOccurrencesOfString:swap[0] withString:swap[1]]));
        }
        // An end written as YAML's null, on a line or a word, is no end: the line stops a second past its last word.
        for (NSString *null in @[@"null", @"~", @""]) {
            lf = SGLyricsfileLines([wordFile stringByReplacingOccurrencesOfString:@"    start_ms: 10\n"
                                        withString:[NSString stringWithFormat:@"    start_ms: 10\n    end_ms: %@\n  end_ms: %@\n", null, null]]);
            CHECK(lf.count == 1 && lf[0].words.count == 1 && lf[0].end == 1010);
        }
        // YAML's other escapes, a block whose header gives its indent, and lines listed out of time order.
        lf = SGLyricsfileLines([wordFile stringByAppendingString:@"- text: \"b\\Lc\\N\"\n  start_ms: 5\n  words:\n  - text: \"b\\Lc\"\n    start_ms: 5\nplain: |2\n     a\n    b\n"]);
        CHECK(lf.count == 2 && lf[0].start == 5 && [lf[0].words[0].text isEqualToString:@"b\u2028c"]);
        // A segment that runs into a word sung before it leaves the word's end where it was.
        lf = SGLyricsfileLines(@"version: '1.0'\nlines:\n- text: wanted\n  start_ms: 10\n  words:\n  - text: wan\n    start_ms: 50\n"
            "  - text: ted\n    start_ms: 20\n    end_ms: 30\n");
        CHECK(lf.count == 1 && lf[0].words.count == 1);
        checkWordLines(lf);
        // Nested far past the spec's four levels, or over 256 KB: refused, not followed. The same file
        // with its extra key nested ten deep still reads.
        NSString *(^nested)(NSUInteger) = ^NSString *(NSUInteger levels) {
            NSMutableString *doc = [NSMutableString stringWithString:wordFile];
            for (NSUInteger level = 0; level < levels; level++) {
                [doc appendFormat:@"%@k:\n", [@"" stringByPaddingToLength:level withString:@" " startingAtIndex:0]];
            }
            [doc appendFormat:@"%@x: 1\n", [@"" stringByPaddingToLength:levels withString:@" " startingAtIndex:0]];
            return doc;
        };
        CHECK(SGLyricsfileLines(nested(10)).count == 1);
        CHECK(!SGLyricsfileLines(nested(20)) && !SGLyricsfileLines(nested(1000)));
        CHECK(!SGLyricsfileLines([wordFile stringByAppendingFormat:@"plain: |\n  %@\n", [@"" stringByPaddingToLength:(1 << 18) withString:@"a" startingAtIndex:0]]));
        CHECK(!SGLyricsfileLines(@"[not, yaml") && !SGLyricsfileLines(@"") && !SGLyricsfileLines(nil) && !SGLyricsfileLines((NSString *)@3));

        // LRCLIB: a record with words timed answers with them; one whose Lyricsfile cannot be read, or
        // that says it has no word sync, answers with its LRC; the search picks the record with words over a closer one without.
        NSString *twoLines = @"[00:01.00]a\n[00:02.00]b\n";
        __block NSDictionary *record = @{@"id": @1, @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile};
        __block NSArray *found = nil;
        sg_answer = ^id(NSURL *url, id body) { return [url.path hasSuffix:@"/get"] ? record : found; };
        query.title = @"a";
        query.artist = @"b";
        query.seconds = 200;
        // A Lyricsfile is read off the main queue, so its answer comes later; one without words at once.
        BOOL atOnce = YES;
        got = lrclibAnswer(query, &atOnce);
        CHECK(got.wordTimed && got.synced && got.karaokeLines.count == 1 && got.texts.count && !atOnce);
        record = @{@"id": @1, @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": @"version: '9'"};
        got = lrclibAnswer(query, nil);
        CHECK(!got.wordTimed && got.synced && got.karaokeLines.count == 2);
        record = @{@"id": @1, @"duration": @200, @"hasWordSync": @NO, @"syncedLyrics": twoLines, @"lyricsfile": wordFile};
        got = lrclibAnswer(query, &atOnce);
        CHECK(!got.wordTimed && got.synced && got.karaokeLines.count == 2 && atOnce);
        // An instrumental is answered as one, its Lyricsfile not read.
        record = @{@"id": @1, @"duration": @200, @"instrumental": @YES, @"hasWordSync": @YES, @"lyricsfile": wordFile};
        got = lrclibAnswer(query, &atOnce);
        CHECK(got.instrumental && atOnce);
        record = nil;
        found = @[@{@"id": @2, @"trackName": @"a", @"artistName": @"b", @"duration": @200, @"syncedLyrics": twoLines},
                  @{@"id": @3, @"trackName": @"a", @"artistName": @"b", @"duration": @202, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile}];
        got = lrclibAnswer(query, nil);
        CHECK(got.wordTimed && got.karaokeLines.count == 1);
        // Only a record that is the track can win, however it is timed: not another song of the artist's, nor
        // the song by someone whose name only begins with the artist's. A record that names the artist first of
        // several is theirs, and another version of the song ("a - Live") is still the song.
        NSDictionary *otherSong = @{@"id": @6, @"trackName": @"c", @"artistName": @"b", @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile};
        NSDictionary *otherArtist = @{@"id": @7, @"trackName": @"a", @"artistName": @"b key", @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile};
        found = @[otherSong, otherArtist, found[0]];
        got = lrclibAnswer(query, nil);
        CHECK(got.synced && !got.wordTimed && got.karaokeLines.count == 2);
        found = @[otherSong, otherArtist];
        CHECK(!lrclibAnswer(query, nil));
        found = @[@{@"id": @8, @"trackName": @"a - Live", @"artistName": @"b, x", @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile}];
        got = lrclibAnswer(query, nil);
        CHECK(got.wordTimed && got.karaokeLines.count == 1);
        // The artists joined by a word or by punctuation, in either order, as LRCLIB's records write them.
        for (NSString *joined in @[@"b and x", @"B And X", @"x; b", @"B/X/B/X", @"b x x", @"x • b", @"b vs. x"]) {
            found = @[@{@"id": @12, @"trackName": @"a", @"artistName": joined, @"duration": @200, @"syncedLyrics": twoLines}];
            got = lrclibAnswer(query, nil);
            CHECK(got.synced && got.karaokeLines.count == 2);
        }
        // A record's words count once its Lyricsfile reads: one whose file cannot be read is weighed on its LRC,
        // so the words of a record further off win, and with no file that reads the closer LRC does.
        NSDictionary *unreadable = @{@"id": @9, @"trackName": @"a", @"artistName": @"b", @"duration": @202, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": @"version: '9'"};
        found = @[unreadable, @{@"id": @10, @"trackName": @"a", @"artistName": @"b", @"duration": @204, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile}];
        got = lrclibAnswer(query, nil);
        CHECK(got.wordTimed && got.karaokeLines.count == 1);
        found = @[unreadable, @{@"id": @11, @"trackName": @"a", @"artistName": @"b", @"duration": @200, @"syncedLyrics": @"[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n"}];
        got = lrclibAnswer(query, nil);
        CHECK(!got.wordTimed && got.synced && got.karaokeLines.count == 3);
        // With no length to go on, a record whose LRC is null against one whose LRC is empty: the plain text wins.
        query.seconds = 0;
        found = @[@{@"id": @4, @"trackName": @"a", @"artistName": @"b", @"syncedLyrics": NSNull.null, @"plainLyrics": @"x"},
                  @{@"id": @5, @"trackName": @"a", @"artistName": @"b", @"syncedLyrics": @"", @"plainLyrics": @"y\nz"}];
        got = lrclibAnswer(query, nil);
        CHECK(got && !got.synced);

        for (int i = 1; i < argc; i++) checkLive(@(argv[i]));
        printf("lyrics-sources: all checks passed\n");
    }
    return 0;
}
