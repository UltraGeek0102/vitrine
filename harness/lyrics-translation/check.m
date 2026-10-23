// Checks the parts of lyrics translation that need no network: Musixmatch's community translations
// matched onto a song's lines as copies, each AI provider's request and reply (read into lines or a reason),
// and saved translation files with and without their source. Built against
// this checkout's Musixmatch.m, LyricsTranslation.m, SavedTranslations.m and KaraokeTiming.m. Exits non-zero on the first
// wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"

// What the files reach outside what is checked here; none of it is called.
@implementation SGLyricsResult
@end
void SGLyricsNoteReply(NSURLResponse *response, NSError *error) {}
SGLyricsResult *SGLyricsPlainResult(NSArray<NSString *> *rows) { return nil; }
NSString *SGLyricsTranslationLanguage(void) { return nil; }
SGModRow *SGStatActionRow(NSString *t, NSString *s, NSString *(^v)(void), void (^a)(void)) { return nil; }
SGModRow *SGOptionRow(NSString *t, NSString *s, NSString *k) { return nil; }
id SGKaraokeTrackFor(NSString *trackID) { return nil; }
UIViewController *SGTopController(void) { return nil; }
SGModRow *SGMenuRow(NSString *t, NSArray<NSString *> *c, NSString *(^v)(void), void (^ch)(NSInteger)) { return nil; }
void SGPresentDark(UIViewController *controller) {}

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

static NSArray<NSString *> *readReply(NSString *json, NSInteger status, NSUInteger count, NSString **problem) {
    *problem = nil;
    id root = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return SGAITranslationsIn(@"gemini", root, status, nil, count, problem);
}

static NSArray<NSString *> *readFrom(NSString *provider, NSString *json, NSInteger status, NSUInteger count, NSString **problem) {
    *problem = nil;
    id root = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return SGAITranslationsIn(provider, root, status, nil, count, problem);
}

static NSDictionary *bodyOf(NSURLRequest *request) {
    return [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
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
        // Gemini's errors name Gemini; a request that never arrived is not the key's fault.
        CHECK(!SGAITranslationsIn(@"gemini", nil, 0, [NSError errorWithDomain:NSURLErrorDomain code:-1009 userInfo:nil], 2, &problem)
              && [problem isEqualToString:@"Gemini could not be reached."]);

        // OpenAI-compatible: choices[0].message.content holds {"lines": [...]}, or a bare array, or JSON in a fence.
        NSString *openAI = @"{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"{\\\"lines\\\":[\\\"a\\\",\\\"b\\\"]}\"}}]}";
        CHECK([readFrom(@"openai", openAI, 200, 2, &problem) isEqualToArray:(@[@"a", @"b"])] && !problem);
        CHECK([readFrom(@"openai", @"{\"choices\":[{\"message\":{\"content\":\"```json\\n[\\\"a\\\",\\\"b\\\"]\\n```\"}}]}", 200, 2, &problem)
               isEqualToArray:(@[@"a", @"b"])]);
        CHECK(!readFrom(@"openai", openAI, 200, 3, &problem) && [problem containsString:@"2 lines for the song's 3"]
              && [problem hasPrefix:@"api.openai.com"]);
        CHECK(!readFrom(@"openai", @"{\"choices\":[{\"message\":{\"content\":null,\"refusal\":\"I can't\"}}]}", 200, 2, &problem)
              && [problem containsString:@"declined"]);
        CHECK(!readFrom(@"openai", @"{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"{\\\"lines\\\":[\"}}]}", 200, 2, &problem)
              && [problem containsString:@"too long"]);
        CHECK(!readFrom(@"openai", @"{\"choices\":[{\"finish_reason\":\"content_filter\",\"message\":{\"content\":\"\"}}]}", 200, 2, &problem)
              && [problem containsString:@"filters"]);
        CHECK(!readFrom(@"openai", @"{\"error\":{\"message\":\"Incorrect API key provided\",\"type\":\"invalid_request_error\"}}", 401, 2, &problem)
              && [problem containsString:@"turned the key down"]);
        CHECK(!readFrom(@"openai", @"{\"error\":\"model 'x' not found\"}", 404, 2, &problem) && [problem containsString:@"model 'x' not found"]);

        // Anthropic: the text blocks of content, a refusal or a length stop named.
        NSString *anthropic = @"{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\"},{\"type\":\"text\",\"text\":\"{\\\"lines\\\":[\\\"a\\\",\\\"\\\"]}\"}]}";
        CHECK([readFrom(@"anthropic", anthropic, 200, 2, &problem) isEqualToArray:(@[@"a", @""])] && !problem);
        CHECK(!readFrom(@"anthropic", @"{\"stop_reason\":\"refusal\",\"content\":[]}", 200, 2, &problem) && [problem isEqualToString:@"Anthropic declined to translate the song."]);
        CHECK(!readFrom(@"anthropic", @"{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"{\"}]}", 200, 2, &problem) && [problem containsString:@"too long"]);
        CHECK(!readFrom(@"anthropic", @"{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}", 401, 2, &problem)
              && [problem isEqualToString:@"Anthropic turned the key down. Check it on the Lyrics page."]);
        CHECK(!readFrom(@"anthropic", @"{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", 529, 2, &problem) && [problem containsString:@"busy"]);

        // The requests: where each goes, the key in its header and never in the body, and what plain leaves out.
        NSURLRequest *gemini = SGAITranslationRequest(@"gemini", @"gemini-3.6-flash", @"P", @"k1", NO);
        CHECK([gemini.URL.absoluteString isEqualToString:@"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent"]);
        CHECK([[gemini valueForHTTPHeaderField:@"x-goog-api-key"] isEqualToString:@"k1"] && bodyOf(gemini)[@"generationConfig"][@"thinkingConfig"]);
        CHECK(!bodyOf(SGAITranslationRequest(@"gemini", @"gemini-3.6-flash", @"P", @"k1", YES))[@"generationConfig"][@"thinkingConfig"]);
        NSURLRequest *chat = SGAITranslationRequest(@"openai", @"gpt-6-astra", @"P", @"k2", NO);
        CHECK([chat.URL.absoluteString isEqualToString:@"https://api.openai.com/v1/chat/completions"]);
        CHECK([[chat valueForHTTPHeaderField:@"Authorization"] isEqualToString:@"Bearer k2"]);
        CHECK([bodyOf(chat)[@"model"] isEqualToString:@"gpt-6-astra"] && [bodyOf(chat)[@"messages"][0][@"content"] isEqualToString:@"P"]);
        CHECK([bodyOf(chat)[@"response_format"][@"json_schema"][@"strict"] boolValue]
              && [bodyOf(chat)[@"response_format"][@"json_schema"][@"schema"][@"required"] isEqualToArray:(@[@"lines"])]);
        NSDictionary *plainChat = bodyOf(SGAITranslationRequest(@"openai", @"gpt-6-astra", @"P", @"k2", YES));
        CHECK(!plainChat[@"response_format"] && !plainChat[@"reasoning_effort"] && plainChat[@"messages"]);
        // A server of the user's own, kept in the Keychain beside its key: a pasted /chat/completions is not
        // doubled, a URL that could carry a secret is not used at all (and not swapped for OpenAI's), and a server
        // in the settings, as an imported settings file could hold, is never read.
        [NSUserDefaults.standardUserDefaults setObject:@"https://attacker.example/v1" forKey:@"spotifyglass.lyrics.openai.url"];
        CHECK([SGAITranslationRequest(@"openai", @"x", @"P", @"k", NO).URL.host isEqualToString:@"api.openai.com"]);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.lyrics.openai.url"];
        CHECK([SGAIServerIn(@"http://192.168.1.5:11434/v1/chat/completions") isEqualToString:@"http://192.168.1.5:11434/v1"]);
        CHECK(!SGAIServerIn(@"https://openrouter.ai/api/v1?key=secret") && !SGAIServerIn(@"https://u:p@example.com/v1"));
        CHECK(!SGAIServerIn(@"ftp://example.com") && !SGAIServerIn(@""));
        NSURLRequest *messages = SGAITranslationRequest(@"anthropic", @"claude-haiku-5-5", @"P", @"k3", NO);
        CHECK([messages.URL.absoluteString isEqualToString:@"https://api.anthropic.com/v1/messages"]);
        CHECK([[messages valueForHTTPHeaderField:@"x-api-key"] isEqualToString:@"k3"] && [messages valueForHTTPHeaderField:@"anthropic-version"]);
        CHECK([bodyOf(messages)[@"max_tokens"] integerValue] > 0 && [bodyOf(messages)[@"output_config"][@"format"][@"type"] isEqualToString:@"json_schema"]);
        CHECK(!bodyOf(SGAITranslationRequest(@"anthropic", @"claude-haiku-5-5", @"P", @"k3", YES))[@"output_config"]);
        CHECK(![[[NSString alloc] initWithData:messages.HTTPBody encoding:NSUTF8StringEncoding] containsString:@"k3"]);
        CHECK(!SGAITranslationRequest(@"nobody", @"m", @"P", @"k", NO));

        // Saved files: the new shape with its source, and one from before sources were kept, as unknown.
        SGTranslationSource *source = nil;
        NSDictionary *saved = SGSavedTranslationLines(@{@"by": @"anthropic", @"model": @"claude-haiku-5-5", @"made": @1792000000,
                                                        @"lines": @{@"Hola": @"Hello"}}, &source);
        CHECK([saved isEqualToDictionary:(@{@"Hola": @"Hello"})] && [source.name isEqualToString:@"Anthropic (claude-haiku-5-5)"]
              && source.made.timeIntervalSince1970 == 1792000000 && source.deletable);
        saved = SGSavedTranslationLines(@{@"Hola": @"Hello", @"lines": @"a lyric that reads lines"}, &source);
        CHECK(saved.count == 2 && !source.by && [source.name isEqualToString:@"Unknown"] && !source.made && source.deletable);
        saved = SGSavedTranslationLines(@{@"by": @"translate", @"lines": @{}}, &source);
        CHECK(saved && [source.name isEqualToString:@"Translate on iPhone"] && !source.deletable);
        CHECK(!SGSavedTranslationLines(@[@"not", @"a", @"file"], &source));
        puts("lyrics translation: all checks passed");
    }
    return 0;
}
