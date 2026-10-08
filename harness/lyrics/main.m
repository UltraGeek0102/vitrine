// The lyrics harness: SGRKaraokeView playing a song on a clock of its own (stubs.m), for looking at
// what it does with lines sung over each other, instrumental breaks, translations and pronunciations
// without the phone. The songs are TTML read by the real SGTTML.m, or LRC timed by the real estimate.
//
// Launch arguments (the argument domain of NSUserDefaults, so a setting's key works as one too):
//   -song NAME     fixtures/NAME.ttml, .lrc, .json (Spotify's own) or .txt (plain) in the app, or rtl,
//                  built here (default duet); scripts (built here) is a line in each of many alphabets
//                  and two in English, the second line of each script translated, for romanized lyrics
//   -file PATH     a TTML or LRC file on the Mac instead
//   -at MS         where the clock starts (default 0)
//   -rate X        how fast it runs (default 1)
//   -pauseAt MS    where it stops, for -holdFor seconds (default for good)
//   -sharp 1       no distance blur, so every line can be read in one screenshot
//   -player 1      the view in a stage the size of the player's instead of the whole lyrics page
//   -light 1       the window in light mode, for the glass's appearance
//   -perf LABEL    logs the cost of the view's frames every 240 of them, under LABEL
//   -dump 1        prints the lines as read, with their pronunciations and translations, and quits
//   -romanise 1    asserts romanized lyrics' readings (Shared/Lyrics/Romanise.m), prints PASS and FAIL
//                  lines and quits with the number of failures
//   -openMenu S    opens the pronunciation and translation menu S seconds in, as a tap on its button would
//   -toggleAt S    switches the pronunciation and the translation over S seconds in, as the menu would
//   -translateIn S keeps copies of the lines S seconds in with every other one translated, as
//                  Musixmatch's community translations come in after the lines on the phone
//   -gemini 1      a Gemini key is set, so the menu offers Translate with Gemini (stubs.m answers it)
//   -geminiDelay S stubs.m's Gemini answers S seconds later instead of at once
//   -onDevice 1    Translate on iPhone is offered (stubs.m answers it)
//   -intelligence 1 Translate with Apple Intelligence is offered (stubs.m answers it)
//   -seekLag S     the player reports a seek S seconds after it is asked for (stubs.m)
//   -check 1       asserts the view's fixes (see runChecks), prints PASS and FAIL lines and quits with the
//                  number of failures; run it with -song duet -at 20000 -gemini 1 -geminiDelay 1 -seekLag 0.4
// and the lyrics' own settings by their keys: -spotifyglass.lyricsSimulateWords 1 (sweep line timed
// lines on the estimate), -spotifyglass.redesign.lyricsPronunciation 1,
// -spotifyglass.redesign.lyricsTranslation 1, -spotifyglass.lyricsRomanised 1, -spotifyglass.redesign.lyricsTextOrder '(translation, lyrics, pronunciation)'.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#import "Redesigned/Lyrics/SGRSingButton.h"
#import "Shared/Sing/Sing.h"
// HEAD's sources (build.sh old) may be from before the lyrics had anything but their words.
#if __has_include("Redesigned/Lyrics/LyricsText.h")
#import "Redesigned/Lyrics/LyricsText.h"
#endif

NSArray<SGKaraokeLine *> *SGTTMLLines(NSString *xml);
void SGHarnessStartClock(double at, double rate, double pauseAt, double holdFor);

static const NSInteger kWordMs = 500;

static SGKaraokeLine *timed(NSInteger start, NSString *text, NSString *voice) {
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    NSInteger at = start;
    for (NSString *piece in [text componentsSeparatedByString:@" "]) {
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = piece;
        word.start = at;
        word.end = at + kWordMs - 50;
        at += kWordMs;
        [words addObject:word];
    }
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start;
    line.end = at;
    line.voice = voice;
    return line;
}

// Issue 28's song: right to left lines among left to right ones, a second voice and a backing row,
// with a break of ten seconds before the last line.
static NSArray<SGKaraokeLine *> *rightToLeftSong(void) {
    SGKaraokeLine *backed = timed(22000, @"قلبي معك دائما", @"v1");
    backed.backing = timed(22500, @"(oh oh)", @"v1");
    NSArray<SGKaraokeLine *> *lines = @[
        timed(1000, @"Hello from the other side", @"v1"),
        timed(4000, @"שלום עולם, אני שר לך הלילה", @"v1"),
        timed(8000, @"يا حبيبي تعال الليلة نرقص حتى الصباح ونغني للقمر", @"v1"),
        timed(14000, @"دوستت دارم تا ابد", @"v1"),
        timed(17000, @"أنا أحب Spotify!", @"v1"),
        timed(19500, @"2 לבבות אחד", @"v1"),
        backed,
        timed(25000, @"وأنا أيضا يا حبيبي", @"v2"),
        timed(28000, @"And me too my love", @"v2"),
        timed(41000, @"שלום", @"v1"),
    ];
    SGKaraokeAlignVoices(lines);
    return lines;
}

// The same with a translation under two lines and a romanization under a third (rtlx), to see the
// texts under a line keep to its edge.
static NSArray<SGKaraokeLine *> *rightToLeftSongWithExtras(void) {
    NSArray<SGKaraokeLine *> *lines = rightToLeftSong();
#ifdef SGRKeyLyricsTextOrder
    lines[1].translation = @"Hello world, I sing to you tonight";
    lines[2].translation = @"My love, come tonight, let us dance until morning and sing to the moon";
    SGKaraokeLine *spoken = timed(lines[3].start, @"dustat daram ta abad", nil);
    spoken.align = lines[3].align;
    lines[3].pronunciation = spoken;
    lines[7].translation = @"And me too, my love";
#endif
    return lines;
}

// A line in each of the alphabets romanized lyrics reads, among English ones, written here: every
// other one translated, to see the order of the three; a Hebrew and an Arabic line keep their edge.
static NSArray<SGKaraokeLine *> *scriptsSong(void) {
    NSArray<NSArray<NSString *> *> *texts = @[
        @[@"Hello again, my old friend", @""],
        @[@"君の名前を 呼んでいた", @"I was calling your name"],
        @[@"東京の 夜空に 星が 見えない", @""],
        @[@"사랑해요 너를 영원히", @"I love you forever"],
        @[@"我 爱 你 直到 永远", @""],
        @[@"Привет, как дела сегодня?", @"Hi, how are you today?"],
        @[@"Καλημέρα κόσμε", @""],
        @[@"สวัสดี ครับ ฉัน รัก เธอ", @"Hello, I love you"],
        @[@"नमस्ते दुनिया", @""],
        @[@"مرحبا بالعالم", @"Hello world"],
        @[@"שלום עולם", @""],
        @[@"Ich möchte einen Café", @""],
    ];
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < texts.count; i++) {
        SGKaraokeLine *line = timed(1000 + (NSInteger)i * 3500, texts[i][0], nil);
        if (texts[i][1].length) line.translation = texts[i][1];
        [lines addObject:line];
    }
    return lines;
}

#ifdef SGKeyLyricsRomanised
// The readings Apple's transforms give, as the phone shows them. Failures are counted for the exit code.
static int checkRomanised(void) {
    NSArray<NSArray *> *cases = @[
        @[@"君の名前を呼んでいた", @NO, @"kimi no namae wo yon de i ta"],   // kana: Japanese readings of its kanji
        @[@"東京", @YES, @"toukyou"],                                       // kanji alone in a Japanese song
        @[@"東京", @NO, @"dong jing"],                                      // ...and in a Chinese one, pinyin
        @[@"我爱你，中国！", @NO, @"wǒ ài nǐ, zhōng guó!"],                   // tones kept, punctuation made ASCII
        @[@"사랑해요 너를", @NO, @"salanghaeyo neoleul"],
        @[@"Привет, как дела?", @NO, @"Privet, kak dela?"],
        @[@"Καλημέρα κόσμε", @NO, @"Kalemera kosme"],
        @[@"สวัสดีครับ", @NO, @"swasdi khrab"],
        @[@"नमस्ते दुनिया", @NO, @"namaste duniya"],
        @[@"I love 東京 tonight", @YES, @"I love toukyou tonight"],         // English words kept as they are
        @[@"Ich möchte Café", @NO, NSNull.null],                            // Latin already: nothing to show
        @[@"Tôi yêu em", @NO, NSNull.null],
        @[@"♪", @NO, NSNull.null],
        @[@"", @NO, NSNull.null],
    ];
    int failures = 0;
    for (NSArray *c in cases) {
        NSString *got = SGLyricsRomanised(c[0], [c[1] boolValue]);
        // dong jing is checked without its tones, which ICU may mark differently between versions.
        if ([c[2] isEqual:@"dong jing"]) got = [got stringByApplyingTransform:@"Latin-ASCII" reverse:NO];
        BOOL ok = c[2] == NSNull.null ? got == nil : [got isEqualToString:c[2]];
        failures += !ok;
        printf("%s %s -> %s\n", ok ? "PASS" : "FAIL", [c[0] UTF8String], got ? got.UTF8String : "(none)");
    }
    BOOL japanese = SGLyricsLooksJapanese(@[timed(0, @"Hello", nil), timed(0, @"ラーメン", nil)]);
    BOOL korean = SGLyricsLooksJapanese(@[timed(0, @"사랑해요", nil), timed(0, @"東京", nil)]);
    failures += !japanese + korean;
    printf("%s a song with kana reads as Japanese, one without does not\n", japanese && !korean ? "PASS" : "FAIL");
    return failures;
}
#endif

// [mm:ss.xx] text, as LRCLIB and Spotify's own line-synced lyrics come: timed by the line, the words
// estimated, a ♪ or an empty line a break.
static NSArray<SGKaraokeLine *> *linesOfLRC(NSString *lrc) {
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSRegularExpression *stamp = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]\\s?(.*)$" options:0 error:nil];
    for (NSString *row in [lrc componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *match = [stamp firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!match) continue;
        double seconds = [row substringWithRange:[match rangeAtIndex:1]].doubleValue * 60 + [row substringWithRange:[match rangeAtIndex:2]].doubleValue;
        [starts addObject:@((NSInteger)llround(seconds * 1000))];
        [texts addObject:[row substringWithRange:[match rangeAtIndex:3]]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

static NSArray<SGKaraokeLine *> *songNamed(NSString *name, NSString *file) {
    if (!file && [name isEqualToString:@"rtl"]) return rightToLeftSong();
    if (!file && [name isEqualToString:@"rtlx"]) return rightToLeftSongWithExtras();
    if (!file && [name isEqualToString:@"scripts"]) return scriptsSong();
    NSString *path = file;
    for (NSString *type in @[@"ttml", @"lrc", @"json", @"txt"]) path = path ?: [NSBundle.mainBundle pathForResource:name ofType:type];
    NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text) NSLog(@"harness: no song at %@", path ?: name);
    NSString *type = path.pathExtension;
    // Spotify's own color-lyrics JSON, read by the real parser, and plain text as the sources hand it on.
    if ([type isEqualToString:@"json"]) return SGKaraokeLinesFromBody([text dataUsingEncoding:NSUTF8StringEncoding]);
#ifdef SGKeyLyricsSimulateWords
    if ([type isEqualToString:@"txt"]) return SGKaraokeStaticLines([text componentsSeparatedByString:@"\n"]);
#endif
    return [type isEqualToString:@"lrc"] ? linesOfLRC(text) : SGTTMLLines(text);
}

static void dump(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
#ifdef SGKeyLyricsSimulateWords
        const char *timing = line.timing == SGKaraokeTimingWords ? "W" : line.timing == SGKaraokeTimingLine ? "~" : "-";
#else
        const char *timing = "?";
#endif
        printf("%7ld-%7ld %s%s %s\n", (long)line.start, (long)line.end, timing, line.align ? "R" : "L", SGKaraokeLineText(line).UTF8String);
        if (line.backing) printf("                  bg %s\n", SGKaraokeLineText(line.backing).UTF8String);
#ifdef SGRKeyLyricsTextOrder
        // A pronunciation's words with the time each starts, "+" before one joined to the word before.
        for (SGKaraokeLine *spoken in @[line.pronunciation ?: (id)NSNull.null, line.backing.pronunciation ?: (id)NSNull.null]) {
            if (spoken == (id)NSNull.null) continue;
            NSMutableArray<NSString *> *words = [NSMutableArray array];
            for (SGKaraokeWord *word in spoken.words) [words addObject:[NSString stringWithFormat:@"%@%@@%ld", word.joined ? @"+" : @"", word.text, (long)word.start]];
            printf("                  %s %s\n", spoken == line.pronunciation ? "pr" : "bp", [words componentsJoinedByString:@" "].UTF8String);
        }
        if (line.translation) printf("                  tr %s\n", line.translation.UTF8String);
#endif
#ifdef SGKeyLyricsRomanised
        NSString *romanised = SGLyricsRomanised(SGKaraokeLineText(line), SGLyricsLooksJapanese(lines));
        if (romanised) printf("                  ro %s\n", romanised.UTF8String);
#endif
    }
    fflush(stdout);
}

#pragma mark - the cost of a frame

static IMP sg_tick;
static NSString *sg_perfLabel;
static double sg_samples[240];
static NSUInteger sg_sampleCount;

static int compareDoubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void timedTick(id self, SEL _cmd) {
    uint64_t begin = mach_absolute_time();
    ((void (*)(id, SEL))sg_tick)(self, _cmd);
    uint64_t took = mach_absolute_time() - begin;
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    sg_samples[sg_sampleCount++] = took * base.numer / base.denom / 1000.0;
    if (sg_sampleCount < 240) return;
    double sorted[240];
    memcpy(sorted, sg_samples, sizeof(sorted));
    qsort(sorted, 240, sizeof(double), compareDoubles);
    double sum = 0;
    for (NSUInteger i = 0; i < 240; i++) sum += sorted[i];
    printf("perf %s at %ld ms: tick mean %.1f us, median %.1f, p95 %.1f, max %.1f\n", sg_perfLabel.UTF8String,
           (long)SGKaraokePositionMs(), sum / 240, sorted[120], sorted[228], sorted[239]);
    fflush(stdout);
    sg_sampleCount = 0;
}

#pragma mark - the checks

static int sg_failures;

static void expect(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
    if (!ok) sg_failures++;
}

static id findView(UIView *root, Class cls) {
    if ([root isKindOfClass:cls]) return root;
    for (UIView *view in root.subviews) {
        id found = findView(view, cls);
        if (found) return found;
    }
    return nil;
}

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// Where the line the stack is arranged around starts, against where the anchor puts it for the page's height.
static CGFloat anchorMiss(SGRKaraokeView *karaoke) {
    NSInteger focus = [[karaoke valueForKey:@"focus"] integerValue];
    UIView *view = [karaoke valueForKey:@"shown"][@(focus)];
    if (!view) return CGFLOAT_MAX;
    return fabs(view.center.y - view.bounds.size.height / 2 - karaoke.bounds.size.height * 0.28);
}

static NSString *textsOf(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line)];
    return [texts componentsJoinedByString:@" "];
}

// The tops of the line views there are, by line, as laid out (the scale a line is shown at left out).
static NSArray<NSNumber *> *shownLines(SGRKaraokeView *karaoke) {
    return [[[karaoke valueForKey:@"shown"] allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

static CGFloat topOf(UIView *view) {
    return view.center.y - view.bounds.size.height / 2;
}

// The smallest and the largest room between two line views one after the other.
static void gapsBetween(SGRKaraokeView *karaoke, CGFloat *least, CGFloat *most) {
    NSDictionary<NSNumber *, UIView *> *shown = [karaoke valueForKey:@"shown"];
    NSArray<NSNumber *> *lines = shownLines(karaoke);
    *least = CGFLOAT_MAX;
    *most = -CGFLOAT_MAX;
    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        if (lines[i + 1].integerValue != lines[i].integerValue + 1) continue;
        UIView *a = shown[lines[i]], *b = shown[lines[i + 1]];
        CGFloat gap = topOf(b) - topOf(a) - a.bounds.size.height;
        *least = MIN(*least, gap);
        *most = MAX(*most, gap);
    }
}

// A tap on a line three ahead, more than the song moving on: the stack is arranged around it (or around a
// line still sung over it) from the first frame, gliding there, and stays so while the player is slow to
// report the seek and after it has.
static void checkGlide(SGRKaraokeView *karaoke, dispatch_block_t then) {
    NSInteger focus = [[karaoke valueForKey:@"focus"] integerValue], target = focus + 3;
    NSArray<SGKaraokeLine *> *lines = [karaoke valueForKey:@"lines"];
    UIView *view = [karaoke valueForKey:@"shown"][@(target)];
    if (!view || target >= (NSInteger)lines.count) {
        expect(NO, @"a line three ahead of the sung one has a view to tap");
        then();
        return;
    }
    // HEAD's sources (build.sh old) seek and follow the song, as their tap did.
    if ([karaoke respondsToSelector:NSSelectorFromString(@"glideTo:")]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(karaoke, NSSelectorFromString(@"glideTo:"), lines[(NSUInteger)target].start);
    } else {
        SGKaraokeSeek(lines[(NSUInteger)target].start);
        ((void (*)(id, SEL))objc_msgSend)(karaoke, NSSelectorFromString(@"followSong"));
    }
    NSInteger goal = [[karaoke valueForKey:@"focus"] integerValue];
    expect(goal > focus && goal <= target && view.layer.animationKeys.count > 0,
           [NSString stringWithFormat:@"a tapped line is arranged around at once, and glides there (line %ld to %ld for %ld)", (long)focus, (long)goal, (long)target]);
    __block BOOL held = YES;
    for (int i = 1; i <= 5; i++) {
        after(i * 0.06, ^{ held = held && [[karaoke valueForKey:@"focus"] integerValue] == goal; });
    }
    after(0.8, ^{
        expect(held && [[karaoke valueForKey:@"focus"] integerValue] == goal,
               @"it stays arranged around it while the player is slow to report the seek, and after");
        then();
    });
}

// A tap as the view's recognizer reports it, at a point in the window.
@interface SGHarnessTap : UITapGestureRecognizer
@property (nonatomic) CGPoint point;
@end

@implementation SGHarnessTap
- (CGPoint)locationInView:(UIView *)view {
    return [view convertPoint:self.point fromView:nil];
}
@end

// The Lyrics page's Delay of 500 ms: the view times its lines against the song's position less it, and a
// tap on a line three ahead seeks to that line's start plus it, so once the seek lands the line tapped is
// the one sung, on the delayed clock.
static void checkDelay(SGRKaraokeView *karaoke, dispatch_block_t then) {
    const NSInteger delay = 500;
    [NSUserDefaults.standardUserDefaults setInteger:delay forKey:SGKeyLyricsDelay];
    NSArray<SGKaraokeLine *> *lines = [karaoke valueForKey:@"lines"];
    NSInteger before = SGKaraokePositionMs();
    NSInteger shown = ((NSInteger (*)(id, SEL))objc_msgSend)(karaoke, NSSelectorFromString(@"positionMs"));
    NSInteger later = SGKaraokePositionMs();
    expect(shown >= before - delay && shown <= later - delay,
           [NSString stringWithFormat:@"with 500 ms of delay the lines are timed at %ld ms, the song at %ld ms", (long)shown, (long)before]);
    // Two lines, at 1 s and 3 s: at 3.2 s into the song the line shown is still the first.
    NSArray<SGKaraokeLine *> *pair = @[timed(1000, @"a", nil), timed(3000, @"b", nil)];
    expect(SGKaraokeLeadLine(pair, 3200 - delay) == 0 && SGKaraokeLeadLine(pair, 3600 - delay) == 1,
           @"at 3.2 s the line from 1 s shows, at 3.6 s the one from 3 s");

    NSInteger focus = [[karaoke valueForKey:@"focus"] integerValue], target = focus + 3;
    UIView *view = [karaoke valueForKey:@"shown"][@(target)];
    if (!view || target >= (NSInteger)lines.count) {
        expect(NO, @"a line three ahead has a view to tap");
        then();
        return;
    }
    SGHarnessTap *tap = [SGHarnessTap new];
    tap.point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds)) toView:nil];
    ((void (*)(id, SEL, id))objc_msgSend)(karaoke, NSSelectorFromString(@"tapped:"), tap);
    NSInteger start = lines[(NSUInteger)target].start;
    after(0.8, ^{
        // The player reports the seek -seekLag (0.4 s) after it, so it has run on about 0.4 s since.
        NSInteger song = SGKaraokePositionMs();
        expect(song >= start + delay && song <= start + delay + 600,
               [NSString stringWithFormat:@"a tap on the line at %ld ms seeks the song to %ld ms (now at %ld ms)", (long)start, (long)(start + delay), (long)song]);
        NSInteger sung = [[karaoke valueForKey:@"focus"] integerValue];
        expect(sung > focus && sung <= target, [NSString stringWithFormat:@"and the line tapped (or one sung over it) is the one sung (line %ld for %ld)", (long)sung, (long)target]);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLyricsDelay];
        then();
    });
}

// Scrolled by hand, the page's room grows (the controls go) and the scroll goes on up: the lines made for
// the view meanwhile keep the room between them that the lines already there have.
static void checkBrowse(SGRKaraokeView *karaoke, UIView *host, dispatch_block_t then) {
    UIScrollView *scroll = [karaoke valueForKey:@"scroll"];
    CGFloat gap = [[karaoke valueForKey:@"lineGap"] doubleValue];
    [(id<UIScrollViewDelegate>)karaoke scrollViewWillBeginDragging:scroll];
    CGRect frame = host.frame;
    host.frame = CGRectMake(frame.origin.x, frame.origin.y - 150, frame.size.width, frame.size.height + 300);
    [karaoke layoutIfNeeded];
    scroll.contentOffset = CGPointMake(0, -700);
    after(0.5, ^{
        CGFloat least, most;
        gapsBetween(karaoke, &least, &most);
        expect(least >= gap - 1 && least < CGFLOAT_MAX, [NSString stringWithFormat:@"scrolled by hand while the room grows, no two lines run into each other (least room %.1f, most %.1f, %lu views)",
                                                   least, most, (unsigned long)shownLines(karaoke).count]);
        [karaoke setValue:@NO forKey:@"browsing"];
        scroll.contentOffset = CGPointZero;
        host.frame = frame;
        [karaoke layoutIfNeeded];
        after(0.6, then);   // the lines around the sung one are made again, a few a frame
    });
}

static void runChecks(SGRKaraokeView *karaoke, UIView *host) {
    // Lines listed out of time order are estimated up to the line sung after it, and kept in time order.
    NSArray<SGKaraokeLine *> *estimated = SGKaraokeInTimeOrder(SGKaraokeEstimatedLines(@[@1000, @8000, @6000, @3000, @6000], @[@"a", @"b", @"c", @"d", @"e"]));
    expect([textsOf(estimated) isEqualToString:@"a d c e b"] && estimated[1].end <= 6000,
           [NSString stringWithFormat:@"lines going back in time are read in time order (%@)", textsOf(estimated)]);
    NSArray<SGKaraokeLine *> *listed = @[timed(5000, @"x", nil), timed(2000, @"y", nil), timed(5000, @"z", nil), timed(1000, @"w", nil)];
    NSArray<SGKaraokeLine *> *ordered = SGKaraokeInTimeOrder(listed);
    expect([textsOf(ordered) isEqualToString:@"w y x z"] && SGKaraokeInTimeOrder(ordered) == ordered,
           [NSString stringWithFormat:@"kept lines are put in time order, the same array once they are (%@)", textsOf(ordered)]);

    // A held last word keeps its glow as its line goes dim, and loses it once the line has.
    SGKaraokeLine *line = timed(0, @"hold this", @"v1");
    line.words.lastObject.end = line.words.lastObject.start + 3000;
    line.end = line.words.lastObject.end;
#ifdef SGKeyLyricsRomanised
    id style = ((id (*)(id, SEL, CGFloat, NSArray *, BOOL, BOOL, BOOL))objc_msgSend)([NSClassFromString(@"SGRKaraokeStyle") alloc],
        NSSelectorFromString(@"initWithSize:order:pronunciation:translation:romanised:"), 30, SGRLyricsTextOrder(), NO, NO, NO);
#else
    id style = ((id (*)(id, SEL, CGFloat, NSArray *, BOOL, BOOL))objc_msgSend)([NSClassFromString(@"SGRKaraokeStyle") alloc],
        NSSelectorFromString(@"initWithSize:order:pronunciation:translation:"), 30, SGRLyricsTextOrder(), NO, NO);
#endif
    UIView *lineView = ((id (*)(id, SEL, id, CGFloat, id, id, BOOL, BOOL))objc_msgSend)([NSClassFromString(@"SGRKaraokeLineView") alloc],
        NSSelectorFromString(@"initWithLine:width:style:under:blurred:sweepsEstimates:"), line, 300, style, nil, NO, NO);
    [karaoke.window addSubview:lineView];
    [lineView setValue:@YES forKey:@"active"];
    ((void (*)(id, SEL, double))objc_msgSend)(lineView, NSSelectorFromString(@"showTime:"), line.words.lastObject.start + 2500.0);
    UIView *lit = [[[lineView valueForKey:@"words"] lastObject] valueForKey:@"lit"];
    float glow = lit.layer.shadowOpacity;
    expect(glow > 0.3, [NSString stringWithFormat:@"a word held 3 s glows (%.2f)", glow]);
    // Its letters rise one after another: most of the way through, the first are up and the last on its way.
    NSArray<UIView *> *letters = lit.subviews;
    CGFloat first = letters.firstObject.transform.ty, last = letters.lastObject.transform.ty;
    expect(letters.count == 4 && first < -1.5 && last > first + 0.25,
           [NSString stringWithFormat:@"its %lu letters rise in a wave (first %.2f, last %.2f)", (unsigned long)letters.count, first, last]);
    [lineView setValue:@NO forKey:@"active"];
    expect(lit.layer.shadowOpacity == glow, @"the glow stays on as its line goes out, for the fade to carry it");
    after(0.8, ^{
        expect(lit.layer.shadowOpacity == 0 && lit.hidden, @"the glow is off once the line is dim");
        BOOL landed = YES;
        for (UIView *letter in letters) landed = landed && CGAffineTransformIsIdentity(letter.transform);
        expect(landed, @"and its letters are back down");
        [lineView removeFromSuperview];
    });

    // The sung line stays on the anchor through a change of height, and is placed for the new one at once.
    expect(anchorMiss(karaoke) < 2, [NSString stringWithFormat:@"the sung line is at the anchor (off by %.1f)", anchorMiss(karaoke)]);
    CGRect frame = host.frame;
    host.frame = CGRectMake(frame.origin.x, frame.origin.y - 75, frame.size.width, frame.size.height + 300);
    [karaoke layoutIfNeeded];
    expect(anchorMiss(karaoke) < 2, [NSString stringWithFormat:@"after 300 pt more height it is at the new anchor (off by %.1f)", anchorMiss(karaoke)]);
    host.frame = frame;
    [karaoke layoutIfNeeded];
    expect(anchorMiss(karaoke) < 2, [NSString stringWithFormat:@"and back (off by %.1f)", anchorMiss(karaoke)]);

    // The mic to VoiceOver: one adjustable button, two of the slider's steps a swipe.
    SGRSingButton *mic = findView(karaoke, SGRSingButton.class);
    expect(mic.isAccessibilityElement && (mic.accessibilityTraits & UIAccessibilityTraitAdjustable), @"the mic is adjustable");
    float level = SGSingLevel();
    [mic accessibilityIncrement];
    expect(fabsf(SGSingLevel() - (level + 0.1f)) < 0.001f, [NSString stringWithFormat:@"a swipe up takes the level from %.2f to %.2f", level, SGSingLevel()]);
    expect([mic.accessibilityValue containsString:SGSingLevelText(SGSingLevel())], [NSString stringWithFormat:@"its value reads the level: %@", mic.accessibilityValue]);
    [mic accessibilityDecrement];
    expect(fabsf(SGSingLevel() - level) < 0.001f, @"a swipe down takes it back");

    // The corner buttons go by their glass's effect, never an alpha over the glass.
    UIView *box = [karaoke valueForKey:@"extrasBox"];
    UIButton *extras = [karaoke valueForKey:@"extras"];
    UIVisualEffectView *micGlass = mic.subviews.firstObject, *extrasGlass = box.subviews.firstObject;
    expect([micGlass isKindOfClass:UIVisualEffectView.class] && [extrasGlass isKindOfClass:UIVisualEffectView.class], @"both have the Kit's glass behind them");
    karaoke.extrasHidden = YES;
    expect(!micGlass.effect && !extrasGlass.effect && mic.alpha == 1 && box.alpha == 1, @"hidden, their glass has no effect and nothing over it fades");
    expect(extras.alpha == 0 && !mic.userInteractionEnabled && !box.userInteractionEnabled, @"hidden, the glyphs are gone and take no touches");
    karaoke.extrasHidden = NO;
    expect(micGlass.effect && extrasGlass.effect && extras.alpha == 1 && mic.userInteractionEnabled, @"shown again, all of it is back");

    // Gemini: the item says where the lyrics go, a spinner while it works and no second request.
    UIAction *gemini = nil;
    for (UIMenuElement *item in extras.menu.children) {
        if ([item.title isEqualToString:@"Translate with Gemini"]) gemini = (UIAction *)item;
    }
    expect(gemini.subtitle.length > 0, [NSString stringWithFormat:@"the Gemini item says: %@", gemini.subtitle]);
    ((void (*)(id, SEL))objc_msgSend)(karaoke, NSSelectorFromString(@"translateWithGemini"));
    BOOL offered = NO;
    for (UIMenuElement *item in extras.menu.children) offered |= [item.title isEqualToString:@"Translate with Gemini"];
    expect(extras.configuration.showsActivityIndicator && !offered, @"while Gemini works the button spins and the item is gone");
    after([NSUserDefaults.standardUserDefaults doubleForKey:@"geminiDelay"] + 0.5, ^{
        expect(!extras.configuration.showsActivityIndicator, @"once it answers the spinner is gone");
        after(0.5, ^{
            checkBrowse(karaoke, host, ^{
                checkGlide(karaoke, ^{
                    checkDelay(karaoke, ^{
                        printf("%d failed\n", sg_failures);
                        fflush(stdout);
                        exit(sg_failures);
                    });
                });
            });
        });
    });
}

#pragma mark - the app

@interface SGHarnessDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGHarnessDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
#ifdef SGRKeyLyricsTextOrder
    // Each launch starts from its own arguments, not from what the menu stored on the last one.
    for (NSString *key in @[SGRKeyLyricsPronunciation, SGRKeyLyricsTranslation, SGRKeyLyricsTextOrder]) [args removeObjectForKey:key];
#endif
#ifdef SGKeyLyricsRomanised
    if ([args boolForKey:@"romanise"]) exit(checkRomanised());
#endif
    NSString *song = [args stringForKey:@"song"] ?: @"duet";
    SGKaraokeKeepLines(@"harness", songNamed(song, [args stringForKey:@"file"]));
    // -dumpTo PATH: the dump into a file on the Mac, for when simctl launch --console shows nothing.
    if ([args stringForKey:@"dumpTo"]) freopen([args stringForKey:@"dumpTo"].fileSystemRepresentation, "w", stdout);
    if ([args boolForKey:@"dump"] || [args stringForKey:@"dumpTo"]) {
        dump(SGKaraokeLinesForTrack(@"harness"));
        exit(0);
    }
    SGHarnessStartClock([args doubleForKey:@"at"], [args objectForKey:@"rate"] ? [args doubleForKey:@"rate"] : 1,
                        [args objectForKey:@"pauseAt"] ? [args doubleForKey:@"pauseAt"] : -1, [args doubleForKey:@"holdFor"]);
    if ((sg_perfLabel = [args stringForKey:@"perf"])) {
        Method tick = class_getInstanceMethod(SGRKaraokeView.class, NSSelectorFromString(@"tick"));
        sg_tick = method_setImplementation(tick, (IMP)timedTick);
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    // -light 1: the system in light mode, as a phone set to it would put the player's panes.
    self.window.overrideUserInterfaceStyle = [args boolForKey:@"light"] ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.blackColor;
    CGRect bounds = root.view.bounds;
    // The full screen page has the header above the lines and the controls below; the player's own
    // lines sit between its title row and its progress bar.
    CGRect stage = [args boolForKey:@"player"] ? CGRectMake(0, 200, bounds.size.width, 440)
                                                : CGRectMake(0, 110, bounds.size.width, bounds.size.height - 300);
    UIView *host = [[UIView alloc] initWithFrame:stage];
    [root.view addSubview:host];
    SGRKaraokeView *karaoke = [[SGRKaraokeView alloc] initWithFrame:host.bounds];
    karaoke.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if ([args boolForKey:@"sharp"]) [karaoke setValue:@0 forKey:@"maxBlur"];
    [host addSubview:karaoke];
    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(24, 60, bounds.size.width - 48, 20)];
    caption.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    caption.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    [root.view addSubview:caption];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        caption.text = [NSString stringWithFormat:@"%@  %.1f s", song, SGKaraokePositionMs() / 1000.0];
    }];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    if ([args boolForKey:@"check"]) after(2, ^{ runChecks(karaoke, host); });
    if ([args objectForKey:@"openMenu"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([args doubleForKey:@"openMenu"] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // The button sits in a box with its glass, as the mic does.
            for (UIView *view in [karaoke.subviews valueForKeyPath:@"@unionOfArrays.subviews"]) {
                if (![view isKindOfClass:UIButton.class]) continue;
                UIContextMenuInteraction *menu = ((UIButton *)view).contextMenuInteraction;
                SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
                if ([menu respondsToSelector:present]) ((void (*)(id, SEL, CGPoint))objc_msgSend)(menu, present, CGPointMake(22, 22));
            }
        });
    }
    if ([args objectForKey:@"translateIn"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([args doubleForKey:@"translateIn"] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableArray<SGKaraokeLine *> *translated = [SGKaraokeLinesForTrack(@"harness") mutableCopy];
            for (NSUInteger i = 0; i < translated.count; i += 2) {
                SGKaraokeLine *line = [translated[i] copy];
                line.translation = [@"Translated: " stringByAppendingString:SGKaraokeLineText(line)];
                translated[i] = line;
            }
            SGKaraokeKeepLines(@"harness", translated);
        });
    }
#ifdef SGRKeyLyricsTextOrder
    if ([args objectForKey:@"toggleAt"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([args doubleForKey:@"toggleAt"] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRSetLyricsTextShown(SGRLyricsTextPronunciation, ![args boolForKey:SGRKeyLyricsPronunciation]);
            SGRSetLyricsTextShown(SGRLyricsTextTranslation, ![args boolForKey:SGRKeyLyricsTranslation]);
        });
    }
#endif
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessDelegate.class));
    }
}
