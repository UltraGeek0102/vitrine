// Lyricsfile, the YAML that LRCLIB serves under `lyricsfile` when someone has timed the words of a
// record (https://github.com/tranxuanthang/lyricsfile/blob/main/SPECIFICATION.md):
//
// version: "1.0"
// lines:
//   - text: "Hold on "
//     start_ms: 48712
//     end_ms: 52187
//     words:
//       - text: "Hold "
//         start_ms: 48712
//
// The spec allows mappings, sequences and scalars and nothing else, so this reads YAML's block style
// and no more: no flow collections but an empty one, no anchors, aliases or tags, and no scalar
// written over more than one row except a | or > block. A file outside that is refused whole, and
// LRCLIB's LRC is read instead.
#import "LyricsSources.h"

#pragma mark - the YAML

// The rows of the document and the one being read. A sequence item's "- " is blanked out in place, so
// the mapping it opens reads like any other at the column its first key is in.
typedef struct {
    NSMutableArray<NSString *> *rows;
    NSUInteger at, depth;
    BOOL failed;
} SGLFReader;

static NSUInteger indentOf(NSString *row) {
    NSUInteger n = 0;
    while (n < row.length && [row characterAtIndex:n] == ' ') n++;
    return n;
}

static BOOL ignorable(NSString *row) {
    NSString *trimmed = [row stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return !trimmed.length || [trimmed hasPrefix:@"#"] || [trimmed isEqualToString:@"---"];
}

// The next row with something on it, nil at the end; a tab where the indent is fails the document.
static NSString *nextRow(SGLFReader *r) {
    while (r->at < r->rows.count && ignorable(r->rows[r->at])) r->at++;
    if (r->at >= r->rows.count) return nil;
    NSString *row = r->rows[r->at];
    if ([row hasPrefix:@"..."]) return nil;
    NSUInteger indent = indentOf(row);
    if (indent < row.length && [row characterAtIndex:indent] == '\t') {
        r->failed = YES;
        return nil;
    }
    return row;
}

static BOOL isDash(NSString *row, NSUInteger indent) {
    return indent < row.length && [row characterAtIndex:indent] == '-' && (indent + 1 == row.length || [row characterAtIndex:indent + 1] == ' ');
}

// What follows a scalar on its row: nothing, or a comment.
static BOOL restIsEmpty(NSString *rest) {
    NSString *trimmed = [rest stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return !trimmed.length || [trimmed hasPrefix:@"#"];
}

static NSString *doubleQuoted(NSString *text, NSUInteger *end) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 1; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '"') {
            *end = i + 1;
            return out;
        }
        if (c != '\\') {
            [out appendFormat:@"%C", c];
            continue;
        }
        if (++i >= text.length) return nil;
        unichar e = [text characterAtIndex:i];
        NSUInteger digits = e == 'x' ? 2 : e == 'u' ? 4 : e == 'U' ? 8 : 0;
        if (digits) {
            if (i + digits >= text.length) return nil;
            UTF32Char point = 0;
            for (NSUInteger k = i + 1; k <= i + digits; k++) {
                unichar h = [text characterAtIndex:k];
                if (h > 127 || !isxdigit(h)) return nil;
                point = point * 16 + digittoint(h);
            }
            NSString *ch = [[NSString alloc] initWithBytes:&point length:4 encoding:NSUTF32LittleEndianStringEncoding];
            if (!ch) return nil;
            [out appendString:ch];
            i += digits;
            continue;
        }
        // YAML's escapes, which libyaml's writer uses for these characters in a lyric.
        unichar plain;
        switch (e) {
            case '0': plain = 0; break;
            case 'a': plain = 7; break;
            case 'b': plain = 8; break;
            case 't': case '\t': plain = '\t'; break;
            case 'n': plain = '\n'; break;
            case 'v': plain = 11; break;
            case 'f': plain = 12; break;
            case 'r': plain = '\r'; break;
            case 'e': plain = 27; break;
            case ' ': case '"': case '/': case '\\': plain = e; break;
            case '_': plain = ' '; break;
            case 'N': plain = 0x85; break;
            case 'L': plain = 0x2028; break;
            case 'P': plain = 0x2029; break;
            default: return nil;
        }
        [out appendString:[NSString stringWithCharacters:&plain length:1]];
    }
    return nil;   // the closing quote is on a later row, which this does not read
}

static NSString *singleQuoted(NSString *text, NSUInteger *end) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 1; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\'') {
            if (i + 1 < text.length && [text characterAtIndex:i + 1] == '\'') {
                [out appendString:@"'"];
                i++;
                continue;
            }
            *end = i + 1;
            return out;
        }
        [out appendFormat:@"%C", c];
    }
    return nil;
}

// A scalar written on one row, kept as text whatever it spells: the reader of each field decides what
// it should be. nil for what this does not read.
static id inlineScalar(NSString *text) {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!text.length) return nil;
    unichar c = [text characterAtIndex:0];
    NSUInteger end = 0;
    if (c == '"' || c == '\'') {
        NSString *value = c == '"' ? doubleQuoted(text, &end) : singleQuoted(text, &end);
        return value && restIsEmpty([text substringFromIndex:end]) ? value : nil;
    }
    if ([text isEqualToString:@"[]"]) return @[];
    if ([text isEqualToString:@"{}"]) return @{};
    if (c < 128 && strchr("[]{}&*!|>%@`", (char)c)) return nil;   // past ASCII, the cast to char could match
    NSRange comment = [text rangeOfString:@" #"];
    if (comment.location != NSNotFound) text = [text substringToIndex:comment.location];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// A mapping key at the start of `text`, and where its value starts; NO when the text is no "key:".
static BOOL splitKey(NSString *text, NSString **key, NSString **rest) {
    unichar c = text.length ? [text characterAtIndex:0] : 0;
    NSUInteger end = 0;
    if (c == '"' || c == '\'') {
        *key = c == '"' ? doubleQuoted(text, &end) : singleQuoted(text, &end);
        if (!*key) return NO;
        NSString *after = [[text substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![after hasPrefix:@":"]) return NO;
        *rest = [after substringFromIndex:1];
        return YES;
    }
    NSRange colon = [text rangeOfString:@": "];
    if (colon.location == NSNotFound && [text hasSuffix:@":"]) colon = NSMakeRange(text.length - 1, 1);
    if (colon.location == NSNotFound || colon.location == 0) return NO;
    *key = [[text substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    *rest = [text substringFromIndex:NSMaxRange(colon)];
    return YES;
}

static id node(SGLFReader *r, NSUInteger indent);

// The rows of a | or > block after the row that opens it, all indented deeper than `parent`: by the
// digit in its header when it has one (a writer gives it when the first row starts with a space),
// else as deep as its first row.
// shortcut: read as | with its chomping ignored; only `plain` is written this way, and nothing reads it.
static NSString *blockScalar(SGLFReader *r, NSUInteger parent, NSString *header) {
    NSRange digit = [header rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"123456789"]];
    NSUInteger indent = digit.location == NSNotFound ? 0 : parent + [header characterAtIndex:digit.location] - '0';
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    while (r->at < r->rows.count) {
        NSString *row = r->rows[r->at];
        BOOL blank = ![row stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length;
        if (!blank) {
            NSUInteger here = indentOf(row);
            if (here <= parent || (indent && here < indent)) break;
            if (!indent) indent = here;
        }
        [lines addObject:blank ? @"" : [row substringFromIndex:indent]];
        r->at++;
    }
    return [lines componentsJoinedByString:@"\n"];
}

// The value after "key:" or "- ", the row it is on already passed: on the same row, a block under it,
// or (after a key) a sequence at the key's own indent.
static id valueAfter(SGLFReader *r, NSString *rest, NSUInteger indent, BOOL afterKey) {
    NSString *trimmed = [rest stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([trimmed hasPrefix:@"|"] || [trimmed hasPrefix:@">"]) return blockScalar(r, indent, trimmed);
    if (!restIsEmpty(trimmed)) {
        id value = inlineScalar(trimmed);
        if (!value) r->failed = YES;
        return value;
    }
    NSString *row = nextRow(r);
    if (!row) return NSNull.null;
    NSUInteger here = indentOf(row);
    if (here > indent || (afterKey && here == indent && isDash(row, here))) return node(r, here);
    return NSNull.null;
}

static NSDictionary *mapping(SGLFReader *r, NSUInteger indent) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSString *row;
    while (!r->failed && (row = nextRow(r))) {
        NSUInteger here = indentOf(row);
        if (here < indent || (here == indent && isDash(row, here))) break;
        NSString *key, *rest;
        if (here > indent || !splitKey([row substringFromIndex:here], &key, &rest) || map[key]) {
            r->failed = YES;   // a key given twice is refused, as the spec asks, rather than one picked
            break;
        }
        r->at++;
        id value = valueAfter(r, rest, indent, YES);
        if (value) map[key] = value;
    }
    return map;
}

static NSArray *sequence(SGLFReader *r, NSUInteger indent) {
    NSMutableArray *items = [NSMutableArray array];
    NSString *row;
    while (!r->failed && (row = nextRow(r))) {
        NSUInteger here = indentOf(row);
        if (here != indent || !isDash(row, here)) {
            if (here > indent) r->failed = YES;
            break;
        }
        NSString *content = [row substringFromIndex:here + 1];
        NSUInteger column = here + 1 + indentOf(content);
        NSString *key, *rest;
        if (column < row.length && splitKey([row substringFromIndex:column], &key, &rest)) {
            r->rows[r->at] = [[@"" stringByPaddingToLength:column withString:@" " startingAtIndex:0] stringByAppendingString:[row substringFromIndex:column]];
            [items addObject:mapping(r, column)];
            continue;
        }
        r->at++;
        id value = valueAfter(r, content, indent, NO);
        if (value) [items addObject:value];
    }
    return items;
}

// The spec nests four deep; a reply nested far deeper is refused before it can run the stack out.
static const NSUInteger kMaxDepth = 16;

static id node(SGLFReader *r, NSUInteger indent) {
    NSString *row = nextRow(r);
    if (!row) return NSNull.null;
    if (++r->depth > kMaxDepth) {
        r->failed = YES;
        return nil;
    }
    id value = isDash(row, indent) ? sequence(r, indent) : mapping(r, indent);
    r->depth--;
    return value;
}

// The document as dictionaries, arrays and strings; nil when it is not YAML this reads.
static id parseYAML(NSString *yaml) {
    SGLFReader reader = {[NSMutableArray array]}, *r = &reader;
    for (NSString *row in [yaml componentsSeparatedByString:@"\n"]) {
        [r->rows addObject:[row hasSuffix:@"\r"] ? [row substringToIndex:row.length - 1] : row];
    }
    NSString *first = nextRow(r);
    if (!first || indentOf(first) != 0) return nil;
    id root = node(r, 0);
    return r->failed || nextRow(r) ? nil : root;
}

#pragma mark - the lines

// A whole song timed by the word is tens of kilobytes; anything past this is no Lyricsfile. A megabyte
// took a third of a second to read on a Mac.
static const NSUInteger kMaxLength = 1 << 18;

// A time in milliseconds: ASCII digits only, none negative, and at most nine of them (over a hundred
// hours), so the sums below cannot overflow. -1 for anything else.
static NSInteger msOf(id value) {
    static NSCharacterSet *notDigits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet; });
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 9) return -1;
    if ([value rangeOfCharacterFromSet:notDigits].location != NSNotFound) return -1;
    return [value integerValue];
}

// Whether a line or word has an end of its own. end_ms is optional, and a writer that dumps its every field
// spells a missing one as YAML's null (`end_ms: null`, `~`, or nothing), which is no end rather than a bad one.
static BOOL endGiven(NSDictionary *raw) {
    id end = raw[@"end_ms"];
    return end && end != NSNull.null && ![@[@"null", @"Null", @"NULL", @"~"] containsObject:end];
}

// Where a line without an end of its own, or of its last word, is taken to stop.
static const NSInteger kTailMs = 1000;

// A word timed line. A segment the spec writes without the space after it ("wan", "ted ") goes on
// into the next one, and one written with a space in front starts a word of its own.
static SGKaraokeLine *wordLine(NSArray *rawWords, NSInteger start, NSInteger end) {
    NSInteger lineEnd = end;
    if (lineEnd < 0) {
        NSDictionary *last = rawWords.lastObject;
        lineEnd = endGiven(last) ? msOf(last[@"end_ms"]) : msOf(last[@"start_ms"]) + kTailMs;
    }
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableArray<SGKaraokePiece *> *pieces = [NSMutableArray array];
    for (NSUInteger i = 0; i < rawWords.count; i++) {
        NSDictionary *raw = rawWords[i];
        NSString *said = raw[@"text"];
        NSInteger wordStart = msOf(raw[@"start_ms"]), wordEnd = endGiven(raw) ? msOf(raw[@"end_ms"]) : -1;
        if (![said isKindOfClass:NSString.class] || wordStart < 0) return nil;
        if (endGiven(raw) && wordEnd < wordStart) return nil;
        if (wordEnd < 0) wordEnd = i + 1 < rawWords.count ? msOf(rawWords[i + 1][@"start_ms"]) : lineEnd;
        SGKaraokePiece *piece = [SGKaraokePiece new];
        piece.text = [said stringByTrimmingCharactersInSet:space];
        piece.start = wordStart;
        piece.end = MAX(wordEnd, wordStart + 1);   // a word of no length still shows, for a moment
        piece.spaceBefore = said.length && [space characterIsMember:[said characterAtIndex:0]];
        piece.spaceAfter = said.length && [space characterIsMember:[said characterAtIndex:said.length - 1]];
        [pieces addObject:piece];
    }
    return SGKaraokePieceLine(pieces, start, lineEnd);
}

NSArray<SGKaraokeLine *> *SGLyricsfileLines(NSString *yaml) {
    if (![yaml isKindOfClass:NSString.class] || yaml.length > kMaxLength) return nil;
    NSDictionary *root = parseYAML(yaml);
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"version"] isEqual:@"1.0"]) return nil;
    NSArray *rawLines = root[@"lines"];
    if (![rawLines isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    BOOL anyWords = NO;
    for (NSDictionary *raw in rawLines) {
        if (![raw isKindOfClass:NSDictionary.class]) return nil;
        NSString *text = raw[@"text"];
        NSArray *words = raw[@"words"];
        NSInteger start = msOf(raw[@"start_ms"]), end = endGiven(raw) ? msOf(raw[@"end_ms"]) : -1;
        if (![text isKindOfClass:NSString.class] || start < 0 || (endGiven(raw) && end < start)) return nil;
        if (words && ![words isKindOfClass:NSArray.class]) {
            if (words != (id)NSNull.null) return nil;
            words = nil;
        }
        for (NSDictionary *word in words) if (![word isKindOfClass:NSDictionary.class]) return nil;
        SGKaraokeLine *line;
        if (words.count) {
            line = wordLine(words, start, end);
            if (!line) return nil;
            anyWords = YES;
        } else {
            // A line the file times only as a whole, among ones it times by the word.
            line = SGKaraokeEstimatedLines(end >= 0 ? @[@(start), @(end)] : @[@(start)], end >= 0 ? @[text, @""] : @[text]).firstObject;
        }
        if (line) [lines addObject:line];
    }
    // Lines timed only as whole lines are what the record's LRC has already.
    return anyWords ? SGKaraokeInTimeOrder(lines) : nil;
}
