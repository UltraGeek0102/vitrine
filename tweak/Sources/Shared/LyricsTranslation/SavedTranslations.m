// Translations kept on disk, whichever way they were made: one small JSON file a song and language in
// Caches/Vitrine/Translations, each line's text to its translation under "lines" with who made it ("by",
// "model") and when ("made", seconds since 1970), so a song comes back translated after
// a relaunch and lyrics from another source still find their lines. The newest kKept files stay; iOS may
// clear Caches when it runs low, which costs a translation again.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "LyricsTranslation.h"

static const NSUInteger kKept = 200;

static NSURL *folder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [[caches URLByAppendingPathComponent:@"Vitrine" isDirectory:YES] URLByAppendingPathComponent:@"Translations" isDirectory:YES];
}

static NSURL *fileFor(NSString *track, NSString *language) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"].invertedSet;
    NSString *tag = [[language componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    return [folder() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.json", track, tag]];
}

static NSArray<NSURL *> *files(void) {
    return [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder() includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey]
                                                          options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
}

NSDictionary<NSString *, NSString *> *SGSavedTranslationLines(id json, SGTranslationSource **source) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    id lines = json[@"lines"];
    if (![lines isKindOfClass:NSDictionary.class]) {
        *source = [SGTranslationSource by:nil model:nil made:nil];   // saved before sources were kept
        return json;
    }
    id by = json[@"by"], model = json[@"model"], made = json[@"made"];
    *source = [SGTranslationSource by:[by isKindOfClass:NSString.class] ? by : nil model:[model isKindOfClass:NSString.class] ? model : nil
                                 made:[made isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[made doubleValue]] : nil];
    return lines;
}

SGTranslationSource *SGLyricsSyncSavedTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines) {
    if (!track.length || !language.length || !lines.count) return nil;
    NSData *data = [NSData dataWithContentsOfURL:fileFor(track, language)];
    SGTranslationSource *source = nil;
    NSDictionary *saved = SGSavedTranslationLines(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil, &source);
    BOOL shown = NO;
    for (SGKaraokeLine *line in lines) {
        id translation = saved[SGKaraokeLineText(line) ?: @""];
        BOOL has = [translation isKindOfClass:NSString.class] && [translation length];
        if (line.translationMade && !has) {
            line.translation = nil;
            line.translationMade = NO;
        } else if (!line.translation.length && has) {
            line.translation = translation;
            line.translationMade = YES;
        }
        shown |= line.translationMade;
    }
    // A file none of these lines matched (lyrics from another source) made nothing that shows.
    return shown ? source : nil;
}

// One at a time, in the order asked: a song is saved after every batch, and an older write must not land last.
static dispatch_queue_t writes(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("vitrine.translations", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

SGTranslationSource *SGLyricsSaveTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines, SGTranslationSource *source) {
    if (!track.length || !language.length) return nil;
    NSMutableDictionary<NSString *, NSString *> *saved = [NSMutableDictionary dictionary];
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        if (text.length && line.translation.length) saved[text] = line.translation;
    }
    if (!saved.count) return nil;
    // The source of the last translation asked: a song finished by a second translator names the second.
    NSDate *now = [NSDate date];
    NSMutableDictionary *file = [@{@"lines": saved, @"made": @(floor(now.timeIntervalSince1970))} mutableCopy];
    if (source.by) file[@"by"] = source.by;
    if (source.model) file[@"model"] = source.model;
    NSData *data = [NSJSONSerialization dataWithJSONObject:file options:0 error:nil];
    dispatch_async(writes(), ^{
        [NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToURL:fileFor(track, language) atomically:YES];
        NSArray<NSURL *> *all = files();
        if (all.count <= kKept) return;
        NSArray<NSURL *> *oldestFirst = [all sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *da, *db;
            [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
            [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
            return [da ?: NSDate.distantPast compare:db ?: NSDate.distantPast];
        }];
        for (NSUInteger i = 0; i < all.count - kKept; i++) [NSFileManager.defaultManager removeItemAtURL:oldestFirst[i] error:nil];
    });
    return [SGTranslationSource by:source.by model:source.model made:now];
}

// After any write still queued, so it cannot bring a file back.
static void deleteQueued(NSURL *url, NSString *what) {
    dispatch_async(writes(), ^{
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGLog(@"translation: %@ deleted", what);
            [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
        });
    });
}

void SGLyricsDeleteSavedTranslation(NSString *track, NSString *language) {
    if (!track.length || !language.length) return;
    SGLyricsForgetAITranslation(track, language);
    deleteQueued(fileFor(track, language), [NSString stringWithFormat:@"%@ in %@", track, language]);
}

static NSString *summary(void) {
    NSArray<NSURL *> *all = files();
    if (!all.count) return @"None";
    long long bytes = 0;
    for (NSURL *file in all) {
        NSNumber *size;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        bytes += size.longLongValue;
    }
    return [NSString stringWithFormat:@"%lu · %@", (unsigned long)all.count,
            [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile]];
}

SGModRow *SGSavedTranslationsRow(void) {
    return SGStatActionRow(@"Saved translations", @"Songs translated on this iPhone or by an AI translator come back translated",
                           ^NSString *{ return summary(); }, ^{
        if (!files().count) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete saved translations?"
            message:@"Songs translated before are translated again the next time you ask." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGLyricsForgetAITranslation(nil, nil);
            deleteQueued(folder(), @"saved translations");
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
}
