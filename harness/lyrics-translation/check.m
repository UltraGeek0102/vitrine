// Checks the parts of lyrics translation that need no network: Musixmatch's community translations
// matched onto a song's lines as copies, and Gemini's reply read into lines or a reason. Built against
// this checkout's Musixmatch.m, LyricsTranslation.m and KaraokeTiming.m. Exits non-zero on the first
// wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"

// What the files reach outside what is checked here; none of it is called.
@implementation SGLyricsResult
@end
void SGLyricsNoteReply(NSURLResponse *response, NSError *error) {}
NSString *SGLyricsTranslationLanguage(void) { return nil; }
SGModRow *SGStatActionRow(NSString *t, NSString *s, NSString *(^v)(void), void (^a)(void)) { return nil; }
SGModRow *SGOptionRow(NSString *t, NSString *s, NSString *k) { return nil; }
id SGKaraokeTrackFor(NSString *trackID) { return nil; }
UIViewController *SGTopController(void) { return nil; }

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

static NSArray<NSString *> *readReply(NSString *json, NSInteger status, NSUInteger count, NSString **problem) {
    *problem = nil;
    id root = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return SGGeminiTranslationsIn(root, status, nil, count, problem);
}

int main(void) {
    @autoreleasepool {
        // Musixmatch's translations go on copies of the lines they match, by the folded text.
        NSArray<SGKaraokeLine *> *lines = SGKaraokeEstimatedLines(@[@0, @2000, @4000, @6000],
                                                                  @[@"Où est l'amour ?", @"Yeah", @"Rien", @""]);
        CHECK(lines.count >= 3);
        lines[2].translation = @"Nothing";
        NSDictionary *byLine = @{SGMusixmatchLineKey(@"ou est L'AMOUR"): @"Where is love?", SGMusixmatchLineKey(@"rien"): @"None"};
        NSArray<SGKaraokeLine *> *translated = SGMusixmatchTranslatedLines(lines, byLine);
        CHECK(translated && translated != lines && translated.count == lines.count);
        CHECK([translated[0].translation isEqualToString:@"Where is love?"] && translated[0] != lines[0]);
        CHECK(!lines[0].translation);                                  // the lines kept before are left as they were
        CHECK(translated[0].start == lines[0].start && translated[0].end == lines[0].end
              && translated[0].words == lines[0].words && translated[0].timing == lines[0].timing);
        CHECK(translated[1] == lines[1] && !translated[1].translation);  // no match: the same line
        CHECK([translated[2].translation isEqualToString:@"Nothing"]);   // a translation of its own stays
        CHECK(!SGMusixmatchTranslatedLines(lines, @{@"nothing here": @"x"}));

        // Gemini's language by the whole tag, so the script survives.
        NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en"];
        CHECK(![[english localizedStringForLocaleIdentifier:@"zh-Hant"] isEqualToString:[english localizedStringForLocaleIdentifier:@"zh-Hans"]]);

        // Gemini's reply: lines, or why there are none.
        NSString *problem;
        NSArray<NSString *> *got = readReply(@"{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"[\\\"a\\\",\\\"\\\"]\"}]},\"finishReason\":\"STOP\"}]}", 200, 2, &problem);
        CHECK([got isEqualToArray:(@[@"a", @""])] && !problem);
        CHECK(!readReply(@"{\"promptFeedback\":{\"blockReason\":\"PROHIBITED_CONTENT\"}}", 200, 2, &problem) && [problem containsString:@"filters"]);
        CHECK(!readReply(@"{\"candidates\":[{\"finishReason\":\"RECITATION\"}]}", 200, 2, &problem) && [problem containsString:@"repeated"]);
        CHECK(!readReply(@"{\"candidates\":[{\"finishReason\":\"SAFETY\"}]}", 200, 2, &problem) && [problem containsString:@"filters"]);
        CHECK(!readReply(@"{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"[\\\"a\\\"]\"}]},\"finishReason\":\"STOP\"}]}", 200, 2, &problem)
              && [problem containsString:@"1 lines for the song's 2"]);
        CHECK(!readReply(@"{\"error\":{}}", 403, 2, &problem) && [problem containsString:@"key"]);
        CHECK(!readReply(@"{\"error\":{\"message\":\"API key not valid. Please pass a valid API key.\"}}", 400, 2, &problem) && [problem containsString:@"key"]);
        CHECK(!readReply(@"{\"error\":{\"message\":\"Invalid JSON payload\"}}", 400, 2, &problem) && [problem containsString:@"Invalid JSON payload"]);
        CHECK(!readReply(@"{\"error\":{}}", 503, 2, &problem) && [problem containsString:@"busy"]);
        CHECK(!readReply(@"{\"error\":{\"status\":\"UNAUTHENTICATED\"}}", 401, 2, &problem) && [problem containsString:@"key"]);
        CHECK(!readReply(@"{\"error\":{}}", 429, 2, &problem) && [problem containsString:@"limit"]);
        CHECK(!readReply(@"{}", 200, 2, &problem) && [problem containsString:@"could not be read"]);
        puts("lyrics translation: all checks passed");
    }
    return 0;
}
