#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Headers/SPTPlayer.h"
#import "LyricsTranslation.h"

// gemini-flash-latest follows each Flash release; Google gives two weeks' notice of a breaking change.
static NSString *const kEndpoint = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent";
static NSString *const kService = @"Vitrine.Gemini", *const kAccount = @"api-key";

#pragma mark - the key

static NSDictionary *keyQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: kService, (__bridge id)kSecAttrAccount: kAccount};
}

static NSString *storedKey(void) {
    NSMutableDictionary *query = [keyQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) return nil;
    NSString *key = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
    return key.length ? key : nil;
}

static void storeKey(NSString *key) {
    SecItemDelete((__bridge CFDictionaryRef)keyQuery());
    if (!key.length) return;
    NSMutableDictionary *item = [keyQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) SGLog(@"gemini: the key could not be kept (%d)", (int)status);
}

BOOL SGGeminiKeySet(void) {
    return storedKey() != nil;
}

#pragma mark - asking

NSString *SGLyricsSongName(NSString *trackID) {
    NSDictionary *local = trackID ? SGLocalFileInfo(trackID) : nil;
    SPTPlayerTrack *track = trackID && !local ? SGKaraokeTrackFor(trackID) : nil;
    NSString *title = local ? local[@"title"] : track.trackTitle, *artist = local ? local[@"artist"] : track.artistName;
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    return [artist isKindOfClass:NSString.class] && artist.length ? [NSString stringWithFormat:@"\u201C%@\u201D by %@", title, artist]
                                                                     : [NSString stringWithFormat:@"\u201C%@\u201D", title];
}

NSString *SGLyricsGeminiLanguage(void) {
    return SGLyricsTranslationLanguage() ?: NSLocale.preferredLanguages.firstObject ?: @"en";
}

// Why Gemini stopped short, as finishReason or promptFeedback.blockReason name it.
static NSString *blockedBecause(NSString *reason) {
    if ([reason isEqualToString:@"RECITATION"]) return @"Gemini stopped because its answer repeated published lyrics.";
    if ([@[@"SAFETY", @"PROHIBITED_CONTENT", @"BLOCKLIST", @"SPII"] containsObject:reason]) return @"Gemini's filters blocked this song's lyrics.";
    if ([reason isEqualToString:@"MAX_TOKENS"]) return @"The song is too long for one answer from Gemini.";
    return [NSString stringWithFormat:@"Gemini stopped before translating the song (%@).", reason];
}

NSArray<NSString *> *SGGeminiTranslationsIn(id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem) {
    NSDictionary *reply = [root isKindOfClass:NSDictionary.class] ? root : nil;
    id candidates = reply[@"candidates"];
    id first = [candidates isKindOfClass:NSArray.class] ? [candidates firstObject] : nil;
    id parts = [first isKindOfClass:NSDictionary.class] && [first[@"content"] isKindOfClass:NSDictionary.class] ? first[@"content"][@"parts"] : nil;
    id text = [parts isKindOfClass:NSArray.class] && [[parts firstObject] isKindOfClass:NSDictionary.class] ? [parts firstObject][@"text"] : nil;
    id parsed = [text isKindOfClass:NSString.class] ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if ([parsed isKindOfClass:NSArray.class] && [parsed count] == count) {
        NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:count];
        for (id line in parsed) [clean addObject:[line isKindOfClass:NSString.class] ? line : @""];
        return clean;
    }
    id feedback = reply[@"promptFeedback"];
    id blocked = [feedback isKindOfClass:NSDictionary.class] ? feedback[@"blockReason"] : nil;
    id finished = [first isKindOfClass:NSDictionary.class] ? first[@"finishReason"] : nil;
    if (error) {
        *problem = @"Gemini could not be reached.";
    } else if (status == 400 || status == 403) {
        *problem = @"Gemini turned the key down. Check it on the Lyrics page.";
    } else if (status == 429) {
        *problem = @"Gemini's limit for this key is reached for now.";
    } else if (status != 200) {
        *problem = [NSString stringWithFormat:@"Gemini did not translate the song (%ld).", (long)status];
    } else if ([blocked isKindOfClass:NSString.class]) {
        *problem = blockedBecause(blocked);
    } else if ([finished isKindOfClass:NSString.class] && ![finished isEqualToString:@"STOP"]) {
        *problem = blockedBecause(finished);
    } else if ([parsed isKindOfClass:NSArray.class]) {
        *problem = [NSString stringWithFormat:@"Gemini answered %lu lines for the song's %lu. Try again.",
                    (unsigned long)[parsed count], (unsigned long)count];
    } else {
        *problem = @"Gemini's answer could not be read. Try again.";
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_done;   // per launch, by track and language

void SGLyricsTranslateWithGemini(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                                 void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    NSString *key = storedKey();
    if (!key) {
        done(nil, @"Add a Gemini API key on the Lyrics page first.");
        return;
    }
    if (!sg_done) sg_done = [NSMutableDictionary dictionary];
    NSString *memo = [NSString stringWithFormat:@"%@|%@", trackID, languageTag];
    if (trackID && sg_done[memo].count == lines.count) {
        done(sg_done[memo], nil);
        return;
    }
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line) ?: @""];
    // By the whole tag, so the script stays: zh-Hant is "Chinese, Traditional" where its language alone is "Chinese".
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLocaleIdentifier:languageTag] ?: languageTag;
    NSData *input = [NSJSONSerialization dataWithJSONObject:texts options:0 error:nil];
    NSString *prompt = [NSString stringWithFormat:
        @"Translate the lines of this song into %@. Answer with a JSON array of exactly %lu strings, one "
        @"per input line and in the same order. Translate the meaning naturally, keep each line short like a "
        @"lyric, and keep an empty line empty. A line already in %@ stays as it is.\n\n%@",
        language, (unsigned long)texts.count, language, [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding]];
    // Lyrics are often explicit, and translating them is what the user asked for, so every filter that can
    // be lowered is. Recitation cannot be switched off, and is named when it stops an answer.
    NSMutableArray *safety = [NSMutableArray array];
    for (NSString *category in @[@"HARM_CATEGORY_HARASSMENT", @"HARM_CATEGORY_HATE_SPEECH",
                                 @"HARM_CATEGORY_SEXUALLY_EXPLICIT", @"HARM_CATEGORY_DANGEROUS_CONTENT"]) {
        [safety addObject:@{@"category": category, @"threshold": @"BLOCK_NONE"}];
    }
    NSDictionary *body = @{
        @"contents": @[@{@"parts": @[@{@"text": prompt}]}],
        @"safetySettings": safety,
        @"generationConfig": @{
            @"responseMimeType": @"application/json",
            @"responseSchema": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}},
        },
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kEndpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *problem = nil;
        NSArray *translations = SGGeminiTranslationsIn(root, status, error, texts.count, &problem);
        SGLog(@"gemini: %@ lines into %@: %@", @(texts.count), languageTag, translations ? @"translated" : problem);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translations && trackID) sg_done[memo] = translations;
            done(translations, problem);
        });
    }] resume];
}

#pragma mark - the row

static void askForKey(void) {
    // Says what leaves the phone, not only where the key stays: each song translated goes to Google whole.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gemini API key"
        message:@"Translate with Gemini sends the song's lyrics to Google, on your own key from Google AI Studio. The key stays on this iPhone."
        preferredStyle:UIAlertControllerStyleAlert];
    // An empty field would store nothing and take the key away, which only Remove is for: Save waits for text.
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (key.length) storeKey(key);
    }];
    save.enabled = NO;
    __weak UIAlertAction *weakSave = save;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"API key";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        __weak UITextField *weakField = field;   // the field keeps its actions, and the alert both
        [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
            weakSave.enabled = [weakField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
        }] forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:save];
    if (SGGeminiKeySet()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeKey(nil);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

NSNotificationName const SGLyricsTranslationsDidChangeNotification = @"spotifyglass.lyricsTranslationsDidChange";

SGModRow *SGTranslateEverySongRow(void) {
    SGModRow *row = SGOptionRow(@"Translate any song", @"The lyrics' translate menu for songs that already read as your language",
                                SGKeyLyricsTranslateEverySong);
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
    };
    return row;
}

SGModRow *SGGeminiKeyRow(void) {
    return SGStatActionRow(@"Gemini API key", @"Translate any song from the lyrics' corner menu",
                           ^NSString *{ return SGGeminiKeySet() ? @"Set" : @"Off"; }, ^{ askForKey(); });
}
