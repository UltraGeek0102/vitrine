// LRCLIB, the floor of the order. It is an open library with no key and no catalog to license, so
// it holds what the rest cannot: the tracks Apple's word by word program never reached, and the
// ones Musixmatch may show nobody. It mostly times lines and not words, which is the whole point of
// putting it last — the estimate inside a line is still a sweep, where Spotify's own lyrics only
// scroll. A record someone has timed by the word carries a Lyricsfile too (Lyricsfile.m), read first.
//
// Its /api/get wants the length to agree almost exactly and answers 404 otherwise, so a miss falls
// back to /api/search, which answers with whole recordings to pick the closest of. LRCLIB asks that
// clients say who they are, and the mod does.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kGet = @"https://lrclib.net/api/get";
static NSString *const kSearch = @"https://lrclib.net/api/search";
// Line timing is only worth taking from a recording of about the same length as the one playing.
static const NSInteger kLengthSlack = 4;

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"User-Agent": @"Vitrine " @SG_VERSION};
}

// [00:34.30] Look — the timestamp in minutes, seconds and hundredths, or thousandths where a line
// carries three digits. A line may be stamped more than once when it is sung more than once, and
// the tags LRC opens with ([ar:…], [length:…]) are not timestamps, so they fall out on their own.
static NSArray<SGKaraokeLine *> *linesFromLRC(NSString *lrc) {
    static NSRegularExpression *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]" options:0 error:nil];
    });
    NSMutableArray<NSDictionary *> *stamped = [NSMutableArray array];
    for (NSString *row in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSTextCheckingResult *> *found = [stamp matchesInString:row options:0 range:NSMakeRange(0, row.length)];
        // Only the stamps a line opens with are its own; one further in is part of the words.
        NSUInteger end = 0;
        NSMutableArray<NSNumber *> *at = [NSMutableArray array];
        for (NSTextCheckingResult *match in found) {
            if (match.range.location != end) break;
            end = NSMaxRange(match.range);
            NSInteger minutes = [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger seconds = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            NSInteger fraction = 0;
            NSRange part = [match rangeAtIndex:3];
            if (part.location != NSNotFound) {
                NSString *digits = [row substringWithRange:part];
                fraction = digits.integerValue * (digits.length == 1 ? 100 : digits.length == 2 ? 10 : 1);
            }
            [at addObject:@((minutes * 60 + seconds) * 1000 + fraction)];
        }
        if (!at.count) continue;
        NSString *text = [[row substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber *ms in at) [stamped addObject:@{@"ms": ms, @"text": text}];
    }
    if (!stamped.count) return nil;
    [stamped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"ms"] compare:b[@"ms"]];
    }];
    // The empty rows stay in: they are the breaks, and each one is the end of the line before it.
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in stamped) {
        [starts addObject:row[@"ms"]];
        [texts addObject:row[@"text"]];
    }
    return SGKaraokeEstimatedLines(starts, texts);
}

// Without word sync a record's Lyricsfile only repeats its LRC's line times, so it is not read.
// Whether a record has words to read: it says it times them, and it is not an instrumental.
static BOOL timesWords(NSDictionary *record) {
    return [record isKindOfClass:NSDictionary.class] && [record[@"hasWordSync"] isEqual:@YES] && ![record[@"instrumental"] boolValue];
}

static SGLyricsResult *syncedResult(NSArray<SGKaraokeLine *> *lines) {
    if (!lines) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.synced = YES;
    result.karaokeLines = lines;
    NSArray<NSNumber *> *starts;
    NSArray<NSString *> *texts;
    SGLyricsPageLines(lines, &starts, &texts);
    result.starts = starts;
    result.texts = texts;
    return result;
}

SGLyricsResult *SGLyricsLRCResult(NSString *lrc) {
    return syncedResult([lrc isKindOfClass:NSString.class] ? linesFromLRC(lrc) : nil);
}

SGLyricsResult *SGLyricsPlainResult(NSArray<NSString *> *rows) {
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSString *row in rows) {
        [starts addObject:@0];
        [texts addObject:row.length ? row : @"♪"];
    }
    SGLyricsResult *result = [SGLyricsResult new];
    result.starts = starts;
    result.texts = texts;
    result.karaokeLines = SGKaraokeStaticLines(texts);
    return result;
}

// wordLines: the record's Lyricsfile as lines, nil when it has none that reads.
static SGLyricsResult *resultFrom(NSDictionary *record, NSArray<SGKaraokeLine *> *wordLines) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.instrumental = [record[@"instrumental"] boolValue];
    if (result.instrumental) return result;
    id synced = record[@"syncedLyrics"], plain = record[@"plainLyrics"];
    SGLyricsResult *worded = syncedResult(wordLines);
    if (worded) {
        worded.wordTimed = YES;
        return worded;
    }
    SGLyricsResult *timed = SGLyricsLRCResult(synced);
    if (timed) return timed;
    // Nothing timed, but the words still beat an empty page when no other source has any.
    if (![plain isKindOfClass:NSString.class] || ![plain length]) return nil;
    return SGLyricsPlainResult([plain componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]);
}

// How good a recording is for the track: words timed beat lines timed, which beat untimed, then the
// closest length. With no length to go on, the fullest sheet wins — the search will happily rank a
// seventeen second stub of a song above the song, and a stub is the one thing a length would have
// caught.
static BOOL betterRecord(NSDictionary *record, NSDictionary *best, NSInteger seconds) {
    if (!best) return YES;
    BOOL worded = [record[@"hasWordSync"] isEqual:@YES], wasWorded = [best[@"hasWordSync"] isEqual:@YES];
    if (worded != wasWorded) return worded;
    BOOL synced = [record[@"syncedLyrics"] isKindOfClass:NSString.class] && [record[@"syncedLyrics"] length];
    BOOL wasSynced = [best[@"syncedLyrics"] isKindOfClass:NSString.class] && [best[@"syncedLyrics"] length];
    if (synced != wasSynced) return synced;
    if (seconds > 0) {
        NSInteger off = labs((NSInteger)[record[@"duration"] doubleValue] - seconds);
        NSInteger wasOff = labs((NSInteger)[best[@"duration"] doubleValue] - seconds);
        return off < wasOff;
    }
    NSString *text = record[@"syncedLyrics"] ?: record[@"plainLyrics"] ?: @"";
    NSString *wasText = best[@"syncedLyrics"] ?: best[@"plainLyrics"] ?: @"";
    return [text isKindOfClass:NSString.class] && (![wasText isKindOfClass:NSString.class] || text.length > wasText.length);
}

// The search ranks by its own lights, and its first hit is often another song of the artist's or the
// song by someone else, so a record has to be the track (SongMatch.m) before its timing counts. The
// artists are written as one name, joined however the uploader's tags had them.
static NSArray<NSDictionary *> *matching(id found, SGLyricsQuery *query) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *record in [found isKindOfClass:NSArray.class] ? found : @[]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        NSInteger length = (NSInteger)[record[@"duration"] doubleValue];
        if (query.seconds > 0 && length > 0 && labs(length - query.seconds) > kLengthSlack) continue;
        NSString *artists = [record[@"artistName"] isKindOfClass:NSString.class] ? record[@"artistName"] : @"";
        if (!SGLyricsSongRank(query.title, query.artist, record[@"trackName"], @[artists])) continue;
        [records addObject:record];
    }
    return records;
}

static NSDictionary *bestOf(NSArray<NSDictionary *> *records, NSInteger seconds) {
    NSDictionary *best = nil;
    for (NSDictionary *record in records) {
        if (betterRecord(record, best, seconds)) best = record;
    }
    return best;
}

// The best of the records as a result, on the main queue, where it is called. A record's words count only once
// its Lyricsfile reads, so the best that says it times words is read first, and one whose file cannot be read is
// weighed again on its LRC alone, until the best is one with words read or one without. A Lyricsfile is read on
// another queue: a long one takes a good part of a second to read, and the main queue would stall for all of it.
static void resultFor(NSArray<NSDictionary *> *records, NSInteger seconds, void (^done)(SGLyricsResult *result)) {
    NSDictionary *best = bestOf(records, seconds);
    if (!timesWords(best)) {
        done(resultFrom(best, nil));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *left = [records mutableCopy];
        NSDictionary *top = best;
        NSArray<SGKaraokeLine *> *worded = nil;
        while (timesWords(top)) {
            worded = SGLyricsfileLines(top[@"lyricsfile"]);
            if (worded) break;
            SGLog(@"lrclib: record %@ times words in a Lyricsfile this cannot read", top[@"id"]);
            NSMutableDictionary *onLines = [top mutableCopy];
            [onLines removeObjectForKey:@"hasWordSync"];
            left[[left indexOfObjectIdenticalTo:top]] = onLines;
            top = bestOf(left, seconds);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(resultFrom(top, worded)); });
    });
}

SGLyricsAsk SGLrcLibAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        SGLog(@"lrclib: nothing to search with for %@", query.trackID);
        done(nil);
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *search = [NSMutableDictionary dictionaryWithDictionary:@{
        @"track_name": query.title,
        @"artist_name": query.artist,
    }];
    if (query.album.length) search[@"album_name"] = query.album;

    void (^bySearch)(void) = ^{
        SGLyricsGetJSON(SGLyricsURL(kSearch, search), headers(), ^(id found) {
            resultFor(matching(found, query), query.seconds, ^(SGLyricsResult *result) {
                SGLog(@"lrclib: search for %@ by %@ gave %@", query.title, query.artist,
                      !result ? @"nothing" : result.instrumental ? @"an instrumental"
                      : result.synced ? [NSString stringWithFormat:@"%lu %@ lines", (unsigned long)result.karaokeLines.count, result.wordTimed ? @"word timed" : @"timed"]
                      : [NSString stringWithFormat:@"%lu untimed lines", (unsigned long)result.texts.count]);
                done(result);
            });
        });
    };

    // With no length to match on, the exact lookup would be a guess; the search ranks by itself.
    if (query.seconds <= 0) {
        bySearch();
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *exact = [search mutableCopy];
    exact[@"duration"] = @(query.seconds).stringValue;
    SGLyricsGetJSON(SGLyricsURL(kGet, exact), headers(), ^(id record) {
        resultFor([record isKindOfClass:NSDictionary.class] ? @[record] : @[], query.seconds, ^(SGLyricsResult *result) {
            if (!result) {
                bySearch();
                return;
            }
            SGLog(@"lrclib: %@ by %@ matched exactly, %@", query.title, query.artist,
                  result.instrumental ? @"instrumental" : result.wordTimed ? @"word timed" : result.synced ? @"timed" : @"untimed");
            done(result);
        });
    });
};
