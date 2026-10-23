#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Headers/SPTPlayer.h"
#import "LyricsTranslation.h"

static NSString *const kDefaultPrompt =
    @"Translate the lines of this song into {language}: exactly {count} translations, one per input line and in "
    @"the same order. Translate the meaning naturally, keep each line short like a lyric, and keep an empty line "
    @"empty. A line already in {language} stays as it is.";
static NSString *const kOpenAIDefaultURL = @"https://api.openai.com/v1";
// The OpenAI-compatible server is kept beside its key, never in the settings: a settings file from someone
// else could otherwise point a key stored here at their own server.
static NSString *const kKeyAccount = @"api-key", *const kServerAccount = @"server";
// A macro, not a constant: the provider table below needs a literal.
#define kLinesFormat @"Answer with a JSON object whose \"lines\" array holds the {count} translations as strings."


#pragma mark - the providers

// One entry per provider: adding one is a row here, its request and its reply's reader.
typedef struct {
    // Literals only, which live as long as the app.
    __unsafe_unretained NSString *tag, *name, *company, *service, *keyNote, *format;
    // Presets, nil-ended, the first being the default; none: the user names the model.
    __unsafe_unretained NSString *models[4], *modelNames[4];
    BOOL modelInURL;   // the id goes into the URL's path, so only the characters of an id are let through
    // Words of a 400 that send the plain request instead: the optional fields a model may not know.
    __unsafe_unretained NSString *plainWhen[4];
    NSMutableURLRequest *(*request)(NSString *model, NSString *prompt, NSString *key, BOOL plain);
    // The answer's text, or nil and in `stopped` why the model stopped short.
    NSString *(*answer)(NSDictionary *reply, NSString *speaker, NSString **stopped);
} SGAIProvider;

static NSString *filtered(NSString *speaker) { return [NSString stringWithFormat:@"%@'s filters blocked this song's lyrics.", speaker]; }
static NSString *tooLong(NSString *speaker) { return [NSString stringWithFormat:@"The song is too long for one answer from %@.", speaker]; }
static NSString *declined(NSString *speaker) { return [NSString stringWithFormat:@"%@ declined to translate the song.", speaker]; }

static id dig(id root, NSArray *path) {
    for (id step in path) {
        if ([step isKindOfClass:NSNumber.class]) root = [root isKindOfClass:NSArray.class] && [root count] > [step unsignedIntegerValue] ? root[[step unsignedIntegerValue]] : nil;
        else root = [root isKindOfClass:NSDictionary.class] ? root[step] : nil;
    }
    return root;
}

static NSString *string(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSMutableURLRequest *post(NSString *url, NSDictionary *body) {
    NSURL *endpoint = url ? [NSURL URLWithString:url] : nil;
    if (!endpoint) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return request;
}

// What OpenAI's strict schema and Anthropic's ask for: an object at the top, the lines under "lines".
static NSDictionary *linesSchema(void) {
    return @{@"type": @"object", @"properties": @{@"lines": @{@"type": @"array", @"items": @{@"type": @"string"}}},
             @"required": @[@"lines"], @"additionalProperties": @NO};
}

// Gemini: generateContent, the key in x-goog-api-key, a bare array forced by responseSchema.
static NSMutableURLRequest *geminiRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    // Lyrics are often explicit, and translating them is what the user asked for, so every filter that can
    // be lowered is. Recitation cannot be switched off, and is named when it stops an answer.
    NSMutableArray *safety = [NSMutableArray array];
    for (NSString *category in @[@"HARM_CATEGORY_HARASSMENT", @"HARM_CATEGORY_HATE_SPEECH",
                                 @"HARM_CATEGORY_SEXUALLY_EXPLICIT", @"HARM_CATEGORY_DANGEROUS_CONTENT"]) {
        [safety addObject:@{@"category": category, @"threshold": @"BLOCK_NONE"}];
    }
    NSMutableDictionary *config = [@{@"responseMimeType": @"application/json",
                                     @"responseSchema": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}}} mutableCopy];
    // Gemini 3 thinks at length by default, which a whole song's translation does not need and which made it
    // slow enough to time out. Plain: a model behind gemini-flash-latest that does not know the field.
    if (!plain) config[@"thinkingConfig"] = @{@"thinkingLevel": @"low"};
    NSMutableURLRequest *request = post([NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", model],
                                        @{@"contents": @[@{@"parts": @[@{@"text": prompt}]}], @"safetySettings": safety, @"generationConfig": config});
    [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
    return request;
}

// Why Gemini stopped short, as finishReason or promptFeedback.blockReason name it.
static NSString *geminiStop(NSString *reason, NSString *speaker) {
    if ([reason isEqualToString:@"RECITATION"]) return [NSString stringWithFormat:@"%@ stopped because its answer repeated published lyrics.", speaker];
    if ([@[@"SAFETY", @"PROHIBITED_CONTENT", @"BLOCKLIST", @"SPII"] containsObject:reason]) return filtered(speaker);
    if ([reason isEqualToString:@"MAX_TOKENS"]) return tooLong(speaker);
    return [NSString stringWithFormat:@"%@ stopped before translating the song (%@).", speaker, reason];
}

static NSString *geminiAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *blocked = string(dig(reply, @[@"promptFeedback", @"blockReason"]));
    NSString *finished = string(dig(reply, @[@"candidates", @0, @"finishReason"]));
    if (blocked) *stopped = geminiStop(blocked, speaker);
    else if (finished && ![finished isEqualToString:@"STOP"]) *stopped = geminiStop(finished, speaker);
    return *stopped ? nil : string(dig(reply, @[@"candidates", @0, @"content", @"parts", @0, @"text"]));
}

// A server URL as typed or stored: http or https with a host, no user, password or query (which could carry a
// secret into the log and the key row), and without /chat/completions if it was pasted whole.
NSString *SGAIServerIn(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *url = trimmed.length ? [NSURLComponents componentsWithString:trimmed] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
        || url.user || url.password || url.query || url.fragment) return nil;
    NSString *path = url.path;
    if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if ([path hasSuffix:@"/chat/completions"]) path = [path substringToIndex:path.length - 17];
    url.path = path;
    return url.string;
}

static const SGAIProvider *providerFor(NSString *tag);
static NSString *storedSecret(const SGAIProvider *p, NSString *account);

// Unset: OpenAI's own. Set to something unusable: none, so a key meant for another server never goes to OpenAI.
static NSString *openAIServer(void) {
    NSString *stored = storedSecret(providerFor(@"openai"), kServerAccount);
    return stored.length ? SGAIServerIn(stored) : kOpenAIDefaultURL;
}

// OpenAI-compatible: chat completions with a bearer key, the lines forced into {"lines": [...]} by a strict
// schema. Plain: no schema and no reasoning effort, for servers and models that take neither.
static NSMutableURLRequest *openAIRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    NSString *server = openAIServer();
    NSMutableDictionary *body = [@{@"model": model, @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
    if (!plain) {
        body[@"response_format"] = @{@"type": @"json_schema",
                                     @"json_schema": @{@"name": @"translation", @"strict": @YES, @"schema": linesSchema()}};
        body[@"reasoning_effort"] = @"low";
    }
    NSMutableURLRequest *request = post(server ? [server stringByAppendingString:@"/chat/completions"] : nil, body);
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    return request;
}

static NSString *openAIAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *finished = string(dig(reply, @[@"choices", @0, @"finish_reason"]));
    if (string(dig(reply, @[@"choices", @0, @"message", @"refusal"])).length) *stopped = declined(speaker);
    else if ([finished isEqualToString:@"length"]) *stopped = tooLong(speaker);
    else if ([finished isEqualToString:@"content_filter"]) *stopped = filtered(speaker);
    return *stopped ? nil : string(dig(reply, @[@"choices", @0, @"message", @"content"]));
}

// Anthropic: the Messages API, the lines forced by output_config.format, thinking kept short by a low effort.
// max_tokens is required; output is billed as made, so a high cap costs nothing. Plain: without output_config,
// for a model that knows neither field.
static NSMutableURLRequest *anthropicRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    NSMutableDictionary *body = [@{@"model": model, @"max_tokens": @16000,
                                   @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
    if (!plain) body[@"output_config"] = @{@"effort": @"low", @"format": @{@"type": @"json_schema", @"schema": linesSchema()}};
    NSMutableURLRequest *request = post(@"https://api.anthropic.com/v1/messages", body);
    [request setValue:key forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"2026-10-21" forHTTPHeaderField:@"anthropic-version"];
    return request;
}

static NSString *anthropicAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *finished = string(reply[@"stop_reason"]);
    if ([finished isEqualToString:@"refusal"]) *stopped = declined(speaker);
    else if ([finished isEqualToString:@"max_tokens"]) *stopped = tooLong(speaker);
    if (*stopped) return nil;
    NSMutableString *text = [NSMutableString string];
    id blocks = reply[@"content"];
    for (id block in [blocks isKindOfClass:NSArray.class] ? blocks : @[]) {
        if ([string(dig(block, @[@"type"])) isEqualToString:@"text"]) [text appendString:string(dig(block, @[@"text"])) ?: @""];
    }
    return text.length ? text : nil;
}

static const SGAIProvider kProviders[] = {
    {@"gemini", @"Gemini", @"Google", @"Vitrine.Gemini",
     @"Translate with Gemini sends the song's lyrics to Google, on your own key from Google AI Studio. The key stays on this iPhone.",
     @"Answer with a JSON array of the {count} translations as strings.",
     // gemini-flash-latest follows each Flash release; Google gives two weeks' notice of a breaking change.
     {@"gemini-flash-latest", @"gemini-3.6-flash", @"gemini-3.5-flash-lite"}, {@"Flash (latest)", @"3.6 Flash", @"3.5 Flash-Lite"},
     YES, {@"thinking"}, geminiRequest, geminiAnswer},
    {@"openai", @"OpenAI-compatible", nil, @"Vitrine.OpenAI",
     @"Sends the song's lyrics to the server below: OpenAI's own unless you name another, such as OpenRouter, or an "
     @"Ollama on your network (http works for local addresses). The key stays on this iPhone; for a server without "
     @"keys, copy any word and paste that.",
     kLinesFormat,
     {nil}, {nil}, NO, {@"response_format", @"json_schema", @"reasoning"}, openAIRequest, openAIAnswer},
    {@"anthropic", @"Anthropic", @"Anthropic", @"Vitrine.Anthropic",
     @"Translate with Anthropic sends the song's lyrics to Anthropic, on your own key from the Claude Console. The key stays on this iPhone.",
     kLinesFormat,
     // The cheapest current model first: the reason a model is picked at all is what translating costs.
     {@"claude-haiku-5-5", @"claude-sonnet-5-5", @"claude-opus-5-5"}, {@"Haiku 5.5", @"Sonnet 5.5", @"Opus 5.5"},
     NO, {@"output_config", @"effort", @"json_schema"}, anthropicRequest, anthropicAnswer},
};
static const NSUInteger kProviderCount = sizeof(kProviders) / sizeof(kProviders[0]);

static const SGAIProvider *providerFor(NSString *tag) {
    for (NSUInteger i = 0; i < kProviderCount; i++) if ([kProviders[i].tag isEqualToString:tag]) return &kProviders[i];
    return NULL;
}

// The chosen one; unset or unknown (a restored backup): Gemini, the first.
static const SGAIProvider *chosen(void) {
    return providerFor([NSUserDefaults.standardUserDefaults stringForKey:SGKeyAITranslator]) ?: &kProviders[0];
}

static BOOL isOpenAI(const SGAIProvider *p) { return [p->tag isEqualToString:@"openai"]; }

static NSString *serverHost(void) {
    return [NSURL URLWithString:openAIServer() ?: @""].host;
}

// Who the messages name: the provider, or for an OpenAI-compatible one its server's host.
static NSString *speaker(const SGAIProvider *p) {
    return isOpenAI(p) ? serverHost() ?: @"The server" : p->name;
}

#pragma mark - the keys

static NSDictionary *keyQuery(const SGAIProvider *p, NSString *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: p->service, (__bridge id)kSecAttrAccount: account};
}

static NSString *storedSecret(const SGAIProvider *p, NSString *account) {
    NSMutableDictionary *query = [keyQuery(p, account) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) return nil;
    NSString *value = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
    return value.length ? value : nil;
}

static void storeSecret(const SGAIProvider *p, NSString *account, NSString *value) {
    SecItemDelete((__bridge CFDictionaryRef)keyQuery(p, account));
    if (!value.length) return;
    NSMutableDictionary *item = [keyQuery(p, account) mutableCopy];
    item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) SGLog(@"ai: the %@ %@ could not be kept (%d)", p->tag, account, (int)status);
}


#pragma mark - the model and the prompt

static NSString *storedString(NSString *key) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return value.length ? value : nil;
}

static NSString *modelKey(const SGAIProvider *p) {
    return [NSString stringWithFormat:@"spotifyglass.lyrics.%@.model", p->tag];
}

// A model id as the provider writes them, or nil: Gemini's goes into the request's URL, and a restored backup
// can bring any text under its key. Ids in the body may have / and : (OpenRouter's, Ollama's).
static NSString *modelIDIn(NSString *text, const SGAIProvider *p) {
    static NSCharacterSet *strict, *loose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *idChars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_";
        strict = [NSCharacterSet characterSetWithCharactersInString:idChars].invertedSet;
        loose = [NSCharacterSet characterSetWithCharactersInString:[idChars stringByAppendingString:@"/:@"]].invertedSet;
    });
    NSString *modelID = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (p->modelInURL && [modelID hasPrefix:@"models/"]) modelID = [modelID substringFromIndex:7];
    return modelID.length && modelID.length <= 200 && [modelID rangeOfCharacterFromSet:p->modelInURL ? strict : loose].location == NSNotFound ? modelID : nil;
}

static NSString *model(const SGAIProvider *p) {
    return modelIDIn(storedString(modelKey(p)), p) ?: p->models[0];
}

static NSString *promptTemplate(void) {
    return storedString(SGKeyAIPrompt) ?: kDefaultPrompt;
}

// The first 8 hex digits of the template's SHA-256, for the log: which prompt went, never what the lyrics were.
static NSString *fingerprint(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3]];
}

BOOL SGAITranslatorReady(void) {
    const SGAIProvider *p = chosen();
    return storedSecret(p, kKeyAccount) && model(p) && (!isOpenAI(p) || openAIServer());
}

NSString *SGAITranslatorName(void) {
    const SGAIProvider *p = chosen();
    return isOpenAI(p) && model(p) ? model(p) : p->name;
}

NSString *SGAITranslatorRecipient(void) {
    const SGAIProvider *p = chosen();
    return p->company ?: speaker(p);
}

SGTranslationSource *SGAITranslatorSource(void) {
    const SGAIProvider *p = chosen();
    return [SGTranslationSource by:p->tag model:model(p) made:nil];
}

@implementation SGTranslationSource

+ (instancetype)by:(NSString *)by model:(NSString *)model made:(NSDate *)made {
    SGTranslationSource *source = [self new];
    source->_by = [by copy];
    source->_model = [model copy];
    source->_made = made;
    return source;
}

- (NSString *)name {
    const SGAIProvider *p = providerFor(_by);
    if (p) return _model.length ? [NSString stringWithFormat:@"%@ (%@)", p->name, _model] : p->name;
    if ([_by isEqualToString:SGTranslatedOnDevice]) return @"Translate on iPhone";
    if ([_by isEqualToString:SGTranslatedByAppleIntelligence]) return @"Apple Intelligence";
    return @"Unknown";
}

// Asking the iPhone again costs nothing, and its translation is the same.
- (BOOL)deletable {
    return ![_by isEqualToString:SGTranslatedOnDevice] && ![_by isEqualToString:SGTranslatedByAppleIntelligence];
}
@end

#pragma mark - asking

NSString *SGLyricsSongName(NSString *trackID) {
    NSDictionary *local = trackID ? SGLocalFileInfo(trackID) : nil;
    SPTPlayerTrack *track = trackID && !local ? SGKaraokeTrackFor(trackID) : nil;
    NSString *title = local ? local[@"title"] : track.trackTitle, *artist = local ? local[@"artist"] : track.artistName;
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    return [artist isKindOfClass:NSString.class] && artist.length ? [NSString stringWithFormat:@"“%@” by %@", title, artist]
                                                                     : [NSString stringWithFormat:@"“%@”", title];
}

NSString *SGLyricsTranslationTarget(void) {
    return SGLyricsTranslationLanguage() ?: NSLocale.preferredLanguages.firstObject ?: @"en";
}

NSURLRequest *SGAITranslationRequest(NSString *provider, NSString *modelID, NSString *prompt, NSString *key, BOOL plain) {
    const SGAIProvider *p = providerFor(provider);
    return p && modelID && key ? p->request(modelID, prompt, key, plain) : nil;
}

// The lines out of an answer: a bare array or {"lines": [...]}, whichever the request forced or the prompt asked
// for, and inside a Markdown fence or a sentence when a model without a schema added one.
static id linesIn(NSString *text) {
    if (!text) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!parsed) {
        NSRange open = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"[{"]];
        NSRange close = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"]}"] options:NSBackwardsSearch];
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
            NSString *inner = [text substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
            parsed = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
    }
    if ([parsed isKindOfClass:NSDictionary.class]) parsed = parsed[@"lines"];
    return [parsed isKindOfClass:NSArray.class] ? parsed : nil;
}

NSArray<NSString *> *SGAITranslationsIn(NSString *provider, id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem) {
    const SGAIProvider *p = providerFor(provider) ?: &kProviders[0];
    NSString *who = speaker(p);
    NSDictionary *reply = [root isKindOfClass:NSDictionary.class] ? root : nil;
    NSString *stopped = nil;
    NSArray *lines = status == 200 ? linesIn(p->answer(reply, who, &stopped)) : nil;
    if (lines.count == count) {
        NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:count];
        for (id line in lines) [clean addObject:[line isKindOfClass:NSString.class] ? line : @""];
        return clean;
    }
    // {"error": {"message": ...}} from all three; a bare string from some compatible servers.
    NSString *says = string(dig(reply, @[@"error", @"message"])) ?: string(reply[@"error"]);
    if (error) {
        *problem = [NSString stringWithFormat:@"%@ could not be reached.", who];
    } else if (status == 401 || status == 403 || (status == 400 && [says localizedCaseInsensitiveContainsString:@"API key"])) {
        *problem = [NSString stringWithFormat:@"%@ turned the key down. Check it on the Lyrics page.", who];
    } else if (status == 400 || status == 404) {
        *problem = says.length ? [NSString stringWithFormat:@"%@ did not take the request: %@", who, says]
                               : [NSString stringWithFormat:@"%@ did not take the request (%ld).", who, (long)status];
    } else if (status == 429) {
        *problem = [NSString stringWithFormat:@"%@'s limit for this key is reached for now.", who];
    } else if (status >= 500) {
        *problem = [NSString stringWithFormat:@"%@ is busy right now. Try again in a minute.", who];
    } else if (status != 200) {
        *problem = [NSString stringWithFormat:@"%@ did not translate the song (%ld).", who, (long)status];
    } else if (stopped) {
        *problem = stopped;
    } else if (lines) {
        *problem = [NSString stringWithFormat:@"%@ answered %lu lines for the song's %lu. Try again.", who,
                    (unsigned long)lines.count, (unsigned long)count];
    } else {
        *problem = [NSString stringWithFormat:@"%@'s answer could not be read. Try again.", who];
    }
    return nil;
}

// The providers' advice for a busy model or a full minute's quota (408, 429, 5xx): ask again after about 1, 2
// and 4 s, spread a little so phones do not all come back at once. A key turned down or a request that timed
// out is not asked again. plain is the same request without the optional fields, sent once if a 400 names one.
static void send(const SGAIProvider *p, NSURLRequest *request, NSURLRequest *plain, NSUInteger attempt,
                 void (^finished)(NSData *data, NSInteger status, NSError *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *reply = status == 400 && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        for (NSUInteger i = 0; plain && reply && i < 4 && p->plainWhen[i]; i++) {
            if (![reply localizedCaseInsensitiveContainsString:p->plainWhen[i]]) continue;
            SGLog(@"ai: %@ turned down %@, asking without the optional fields", p->tag, p->plainWhen[i]);
            send(p, plain, nil, attempt, finished);
            return;
        }
        if (attempt < 3 && !error && (status == 408 || status == 429 || status >= 500)) {
            double delay = (double)(1 << attempt) * (0.75 + arc4random_uniform(500) / 1000.0);
            SGLog(@"ai: %ld, asking again in %.1f s", (long)status, delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                send(p, request, plain, attempt + 1, finished);
            });
            return;
        }
        finished(data, status, error);
    }] resume];
}

// Per launch, by "track|language|" and then the provider, server, model and prompt: a translation asked again
// after any of them changed is a new one.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_done;

void SGLyricsForgetAITranslation(NSString *trackID, NSString *languageTag) {
    if (!trackID) {
        [sg_done removeAllObjects];
        return;
    }
    NSString *song = [NSString stringWithFormat:@"%@|%@|", trackID, languageTag];
    for (NSString *memo in sg_done.allKeys) if ([memo hasPrefix:song]) [sg_done removeObjectForKey:memo];
}

void SGLyricsTranslateWithAI(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                             void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    const SGAIProvider *p = chosen();
    NSString *key = storedSecret(p, kKeyAccount), *modelID = model(p), *template = promptTemplate();
    if (!key || !modelID) {
        done(nil, [NSString stringWithFormat:@"Add a %@ API key%@ on the Lyrics page first.", p->name, modelID ? @"" : @" and a model"]);
        return;
    }
    if (!sg_done) sg_done = [NSMutableDictionary dictionary];
    NSString *memo = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@", trackID, languageTag, p->tag,
                      isOpenAI(p) ? openAIServer() : @"", modelID, template];
    if (trackID && sg_done[memo].count == lines.count) {
        done(sg_done[memo], nil);
        return;
    }
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line) ?: @""];
    // By the whole tag, so the script stays: zh-Hant is "Chinese, Traditional" where its language alone is "Chinese".
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLocaleIdentifier:languageTag] ?: languageTag;
    NSData *input = [NSJSONSerialization dataWithJSONObject:texts options:0 error:nil];
    // Filled in by replacing, never as a format: the template is the user's own text. The provider's own
    // sentence on the answer's shape follows it, so an edited prompt cannot ask for the wrong one.
    NSString *instructions = [NSString stringWithFormat:@"%@ %@", template, p->format];
    instructions = [[instructions stringByReplacingOccurrencesOfString:@"{language}" withString:language]
                    stringByReplacingOccurrencesOfString:@"{count}" withString:@(texts.count).stringValue];
    NSString *prompt = [NSString stringWithFormat:@"%@\n\n%@", instructions, [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding]];
    NSURLRequest *request = p->request(modelID, prompt, key, NO), *plain = p->request(modelID, prompt, key, YES);
    if (!request) {
        done(nil, @"The OpenAI-compatible server's URL is not usable. Check it on the Lyrics page.");
        return;
    }
    SGLog(@"ai: asking %@ %@ at %@, prompt %@%@", p->tag, modelID, request.URL.host, fingerprint(template),
          storedString(SGKeyAIPrompt) ? @" (edited)" : @"");
    send(p, request, plain, 0, ^(NSData *data, NSInteger status, NSError *error) {
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *problem = nil;
        NSArray *translations = SGAITranslationsIn(p->tag, root, status, error, texts.count, &problem);
        SGLog(@"ai: %@ %@ lines into %@: %@", p->tag, @(texts.count), languageTag, translations ? @"translated" : problem);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translations && trackID) sg_done[memo] = translations;
            done(translations, problem);
        });
    });
}

#pragma mark - the rows

NSNotificationName const SGLyricsTranslationsDidChangeNotification = @"spotifyglass.lyricsTranslationsDidChange";

SGModRow *SGTranslateEverySongRow(void) {
    SGModRow *row = SGOptionRow(@"Translate any song", @"The lyrics' translate menu for songs that already read as your language",
                                SGKeyLyricsTranslateEverySong);
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
    };
    return row;
}

// The provider, its key, server or model changed: an open lyrics menu names who gets the lyrics, so it is built again.
static void translatorChanged(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
}

void SGAIForgetKeys(void) {
    // One delete per provider's own service, every account in it (key and server), never another app's items.
    for (NSUInteger i = 0; i < kProviderCount; i++) {
        SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                  (__bridge id)kSecAttrService: kProviders[i].service});
    }
    translatorChanged();
}

static void configure(UITextField *field, NSString *placeholder) {
    field.placeholder = placeholder;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
}

// The key comes from the clipboard and is never shown: a text field showed it on screen, where a screenshot
// catches it, and a secure field made iOS offer to save it in Passwords, which syncs it through iCloud. An
// OpenAI-compatible provider's server is typed above. Says what leaves the phone, not only where the key stays:
// each song translated goes to the provider whole.
static void askForKey(void) {
    const SGAIProvider *p = chosen();
    BOOL server = isOpenAI(p), stored = storedSecret(p, kKeyAccount) != nil;
    NSString *message = [p->keyNote stringByAppendingString:@"\n\nCopy the key, then tap Paste Key."];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ API key", p->name]
                                                                   message:message preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;   // over the dark settings, whatever the system's
    __weak UIAlertController *weakAlert = alert;
    void (^saveServer)(void) = ^{
        if (!server) return;
        NSString *url = SGAIServerIn(weakAlert.textFields.firstObject.text);
        storeSecret(p, kServerAccount, [url isEqualToString:kOpenAIDefaultURL] ? nil : url);
    };
    UIAlertAction *paste = [UIAlertAction actionWithTitle:@"Paste Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // A key copied with the quotes around it, as from a code sample, is turned down as it stands.
        NSMutableCharacterSet *around = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [around addCharactersInString:@"\"'“”‘’"];
        UIPasteboard *board = UIPasteboard.generalPasteboard;
        NSString *key = [board.string stringByTrimmingCharactersInSet:around];
        if (!key.length || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
            UIAlertController *none = [UIAlertController alertControllerWithTitle:@"No key on the clipboard"
                                                                          message:@"Copy the API key, then tap Paste Key again."
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            none.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            [none addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [SGTopController() presentViewController:none animated:YES completion:nil];
            return;
        }
        saveServer();
        storeSecret(p, kKeyAccount, key);
        // Left on the clipboard, Universal Clipboard would hand the key on to the user's other devices.
        board.items = @[];
        translatorChanged();
    }];
    UIAlertAction *save = server && stored ? [UIAlertAction actionWithTitle:@"Save Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        saveServer();
        translatorChanged();
    }] : nil;
    if (server) {
        __weak UIAlertAction *weakPaste = paste, *weakSave = save;
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            configure(field, kOpenAIDefaultURL);
            field.text = storedSecret(p, kServerAccount);
            field.keyboardType = UIKeyboardTypeURL;
            field.textContentType = UITextContentTypeURL;
            [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
                NSString *url = weakAlert.textFields.firstObject.text;
                BOOL usable = !url.length || SGAIServerIn(url);
                weakPaste.enabled = usable;
                weakSave.enabled = usable;
            }] forControlEvents:UIControlEventEditingChanged];
        }];
    }
    [alert addAction:paste];
    if (save) [alert addAction:save];
    if (stored) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeSecret(p, kKeyAccount, nil);
            storeSecret(p, kServerAccount, nil);
            translatorChanged();
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void askForModel(void) {
    const SGAIProvider *p = chosen();
    NSString *example = p->models[1] ?: p->models[0] ?: @"gpt-6-astra, or a model your server lists";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ model", p->name]
        message:[NSString stringWithFormat:@"A model id, such as %@.", example] preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *modelID = modelIDIn(weakAlert.textFields.firstObject.text, p);
        if (modelID) [NSUserDefaults.standardUserDefaults setObject:modelID forKey:modelKey(p)];
        translatorChanged();
    }];
    save.enabled = NO;
    __weak UIAlertAction *weakSave = save;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        configure(field, p->models[0] ?: @"Model id");
        field.text = storedString(modelKey(p));
        __weak UITextField *weakField = field;
        [field addAction:[UIAction actionWithHandler:^(UIAction *action) { weakSave.enabled = modelIDIn(weakField.text, p) != nil; }]
        forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:save];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static NSArray<NSString *> *modelMenu(const SGAIProvider *p) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4 && p->modelNames[i]; i++) [names addObject:p->modelNames[i]];
    [names addObject:@"Other…"];
    return names;
}

// The prompt in a sheet: the checkmark stores it, Default puts Vitrine's back in the field. Stored equal to the
// default, or empty, it is removed, so a later change to the default reaches it.
@interface SGPromptEditor : UIViewController
@end

@implementation SGPromptEditor {
    UITextView *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Translation prompt";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _text = [UITextView new];
    _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _text.adjustsFontForContentSizeCategory = YES;
    _text.backgroundColor = UIColor.clearColor;
    _text.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    _text.alwaysBounceVertical = YES;
    _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _text.text = promptTemplate();
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_text];
    UILabel *note = [UILabel new];
    note.text = @"For every AI translator. {language} and {count} are filled in for each song; the translator is then "
                @"told the shape of its answer, and the song's lines follow as a JSON array.";
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.adjustsFontForContentSizeCategory = YES;
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:note];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [note.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_text.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:4],
        [_text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    // Plain: Spotify's white tint fills a Done item's glass and hides its glyph.
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"] style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    done.accessibilityLabel = @"Save";
    UIBarButtonItem *reset = [[UIBarButtonItem alloc] initWithTitle:@"Default" style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    self.navigationItem.rightBarButtonItems = @[done, reset];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reset {
    _text.text = kDefaultPrompt;
}

- (void)save {
    NSString *prompt = [_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!prompt.length || [prompt isEqualToString:kDefaultPrompt]) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAIPrompt];
    else [NSUserDefaults.standardUserDefaults setObject:prompt forKey:SGKeyAIPrompt];
    SGLog(@"ai: prompt %@", storedString(SGKeyAIPrompt) ? [@"edited, " stringByAppendingString:fingerprint(prompt)] : @"default");
    [self close];
}
@end

NSArray<SGModRow *> *SGAITranslatorRows(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < kProviderCount; i++) [names addObject:kProviders[i].name];
    // A pick in a menu row reloads the page's rows; the model row's menu is the chosen provider's presets.
    SGModRow *models = SGMenuRow(@"Model", modelMenu(chosen()), ^NSString *{
        const SGAIProvider *p = chosen();
        NSString *current = model(p);
        for (NSUInteger i = 0; i < 4 && p->models[i]; i++) if ([p->models[i] isEqualToString:current]) return p->modelNames[i];
        return current ?: @"Not set";
    }, nil);
    __weak SGModRow *weakModels = models;
    models.chosen = ^(NSInteger index) {
        const SGAIProvider *p = chosen();
        if (index == 0 && p->models[0]) [NSUserDefaults.standardUserDefaults removeObjectForKey:modelKey(p)];
        else if (index < 4 && p->models[index]) [NSUserDefaults.standardUserDefaults setObject:p->models[index] forKey:modelKey(p)];
        else askForModel();
        translatorChanged();
    };
    SGModRow *provider = SGMenuRow(@"AI translator", names, ^NSString *{ return chosen()->name; }, ^(NSInteger index) {
        if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAITranslator];
        else [NSUserDefaults.standardUserDefaults setObject:kProviders[index].tag forKey:SGKeyAITranslator];
        weakModels.menu = modelMenu(chosen());
        SGLog(@"ai: translator %@", chosen()->tag);
        translatorChanged();
    });
    SGModRow *key = SGStatActionRow(@"API key", @"Translate any song from the lyrics' corner menu", ^NSString *{
        const SGAIProvider *p = chosen();
        if (!storedSecret(p, kKeyAccount)) return @"Off";
        return isOpenAI(p) ? serverHost() ?: @"Server not usable" : @"Set";
    }, ^{ askForKey(); });
    SGModRow *prompt = SGStatActionRow(@"Translation prompt", @"What the AI translator is told to do with a song's lines",
                                       ^NSString *{ return storedString(SGKeyAIPrompt) ? @"Edited" : @"Default"; }, ^{
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SGPromptEditor new]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        SGPresentDark(nav);
        [SGTopController() presentViewController:nav animated:YES completion:nil];
    });
    return @[provider, key, models, prompt];
}
