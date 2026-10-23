// Genius, under every other source: the words as its users transcribed them, with no timing at all, for
// a track no source has lyrics for. The song is found by the search the line meanings share
// (SongMatch.m).
//
// Genius's API gives a song's details and not its words; /api/songs/:id/lyrics wants a signed-in user.
// The words are read from the embed it offers other sites (songs/:id/embed.js, about 15 KB against the
// song page's 650): a script that writes the lyrics' HTML. That is reading a page, not an API, so a
// change to the script's shape or the rg_embed_body around the lines ends this source, quietly: it then
// has nothing for any track. Cloudflare in front of Genius turns some user agents away; the system's
// own gets through.
#import "Core/SGCore.h"
#import "LyricsSources.h"

// The string the script hands JSON.parse, its JavaScript escapes undone: a JSON string.
static NSString *scriptString(NSString *js) {
    NSRange open = [js rangeOfString:@"JSON.parse('"];
    if (open.location == NSNotFound) return nil;
    NSMutableString *json = [NSMutableString string];
    NSUInteger from = NSMaxRange(open);
    for (NSUInteger i = from; i < js.length; i++) {
        unichar c = [js characterAtIndex:i];
        if (c != '\'' && c != '\\') continue;
        [json appendString:[js substringWithRange:NSMakeRange(from, i - from)]];
        if (c == '\'') return json;
        if (++i < js.length) [json appendFormat:@"%C", [js characterAtIndex:i]];
        from = i + 1;
    }
    return nil;
}

static NSString *decodedEntities(NSString *text) {
    static NSRegularExpression *entity;
    static NSDictionary<NSString *, NSString *> *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        entity = [NSRegularExpression regularExpressionWithPattern:@"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-z]+);" options:0 error:nil];
        named = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @" "};
    });
    NSMutableString *out = [text mutableCopy];
    for (NSTextCheckingResult *match in [entity matchesInString:text options:0 range:NSMakeRange(0, text.length)].reverseObjectEnumerator) {
        NSString *name = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *with = named[name];
        if ([name hasPrefix:@"#"]) {
            BOOL hex = name.length > 1 && ([name characterAtIndex:1] == 'x' || [name characterAtIndex:1] == 'X');
            UTF32Char code = (UTF32Char)strtoul([name substringFromIndex:hex ? 2 : 1].UTF8String, NULL, hex ? 16 : 10);
            with = code ? [[NSString alloc] initWithBytes:&code length:4 encoding:NSUTF32LittleEndianStringEncoding] : nil;
        }
        if (with) [out replaceCharactersInRange:match.range withString:with];
    }
    return out;
}

NSArray<NSString *> *SGGeniusEmbedRows(NSString *js) {
    NSString *json = js ? scriptString(js) : nil;
    id html = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    if (![html isKindOfClass:NSString.class]) return nil;
    NSRange body = [html rangeOfString:@"rg_embed_body"];
    NSRange footer = [html rangeOfString:@"rg_embed_footer"];
    if (body.location == NSNotFound || footer.location == NSNotFound || footer.location < NSMaxRange(body)) return nil;
    // Up to the footer's own tag.
    NSUInteger end = [html rangeOfString:@"<" options:NSBackwardsSearch range:NSMakeRange(NSMaxRange(body), footer.location - NSMaxRange(body))].location;
    if (end == NSNotFound) return nil;
    NSString *lyrics = [html substringWithRange:NSMakeRange(NSMaxRange(body), end - NSMaxRange(body))];
    NSRange tagEnd = [lyrics rangeOfString:@">"];
    if (tagEnd.location == NSNotFound) return nil;
    lyrics = [lyrics substringFromIndex:NSMaxRange(tagEnd)];

    static NSRegularExpression *breaks, *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        breaks = [NSRegularExpression regularExpressionWithPattern:@"<br\\s*/?>|</p>" options:NSRegularExpressionCaseInsensitive error:nil];
        tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
    });
    // The HTML's own newlines are layout; its <br>s are the lines.
    lyrics = [[lyrics componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@""];
    lyrics = [breaks stringByReplacingMatchesInString:lyrics options:0 range:NSMakeRange(0, lyrics.length) withTemplate:@"\n"];
    lyrics = [tags stringByReplacingMatchesInString:lyrics options:0 range:NSMakeRange(0, lyrics.length) withTemplate:@""];
    lyrics = decodedEntities(lyrics);

    // [Chorus] and the like name the part, they are not sung; one empty row stands for any gap.
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSString *row in [lyrics componentsSeparatedByString:@"\n"]) {
        NSString *text = [row stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([text hasPrefix:@"["] && [text hasSuffix:@"]"]) continue;
        if (!text.length && (!rows.count || !rows.lastObject.length)) continue;
        [rows addObject:text];
    }
    if (rows.count && !rows.lastObject.length) [rows removeLastObject];
    return rows.count ? rows : nil;
}

SGLyricsAsk SGGeniusAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        done(nil);
        return;
    }
    SGLyricsGetJSON(SGLyricsURL(SGGeniusSearchURL, SGGeniusSearchQuery(query.title, query.artist)), nil, ^(id root) {
        NSNumber *song = SGGeniusSongIn([root isKindOfClass:NSDictionary.class] ? root[@"response"] : nil, query.title, query.artist);
        if (!song) {
            SGLog(@"genius: no song for %@ by %@", query.title, query.artist);
            done(nil);
            return;
        }
        NSURL *embed = [NSURL URLWithString:[NSString stringWithFormat:@"https://genius.com/songs/%@/embed.js", song]];
        SGLyricsGetText(embed, ^(NSString *js) {
            NSArray<NSString *> *rows = SGGeniusEmbedRows(js);
            if (!rows) {
                SGLog(@"genius: %@ by %@ is song %@, no lines in its embed", query.title, query.artist, song);
                done(nil);
                return;
            }
            SGLog(@"genius: %@ by %@ is song %@, %lu untimed lines", query.title, query.artist, song, (unsigned long)rows.count);
            done(SGLyricsPlainResult(rows));
        });
    });
};
