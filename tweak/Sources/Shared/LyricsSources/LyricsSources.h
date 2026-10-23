// Where lyrics come from. Every source answers the same question — what are this track's lines, and
// how finely are they timed — and the chain asks them in the order the Lyrics page puts them in,
// keeping the best answer rather than the first: a source with only plain text does not shut out a
// later one that times every word.
//
// SGTTML.m reads the TTML that Apple Music's own lyrics are written in, which is what BiniLyrics and
// Unison serve. It is the only shape carrying a second voice and the (oh, aye) sung under a line; every other source times lines, or the words inside them, and nothing more.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"

// The sources in the order they are asked, as their keys. Unset means the order below, so a source
// added in a later version joins the end of everyone's list instead of shuffling it.
#define SGKeyLyricsProviders @"spotifyglass.lyricsProviders"
// Offers the lyrics card on tracks Spotify itself has no lyrics for.
#define SGKeyLyricsAllTracks @"spotifyglass.lyricsAllTracks"
// The walk goes on past a line-timed answer to the first source with words timed; read by every walk.
#define SGKeyLyricsPreferWordTiming @"spotifyglass.lyricsPreferWordTiming"
// Names the source the shown lines came from, on the full screen page.
#define SGKeyLyricsCredit @"spotifyglass.lyricsCredit"
// The language a line's translation is asked for in, as an index into SGLyricsTranslationLanguages;
// unset or 0 takes whatever translation the source has.
#define SGKeyLyricsTranslationLanguage @"spotifyglass.lyricsTranslationLanguage"

// A page a credit names someone on: "Uploader: name" and the address it opens.
@interface SGLyricsLink : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSURL *url;
@end

// What a source answers with, and what the chain merges several of into one.
@interface SGLyricsResult : NSObject
// What the credit names: the source's name, unless it gave a fuller credit of its own.
@property (nonatomic, copy) NSString *provider;
// Who made the lines, linked from the credit; and whether the source's terms ask for the credit to
// show wherever its lines do, Show source or not.
@property (nonatomic, copy) NSArray<SGLyricsLink *> *creditLinks;
@property (nonatomic) BOOL creditRequired;
// The source of the text Spotify's own page shows, when it is not the one the lines came from.
@property (nonatomic, copy) NSString *pageProvider;
@property (nonatomic) BOOL synced;                // the lines have starts of their own
@property (nonatomic) BOOL wordTimed;             // the words inside them are timed, not estimated
// Every line as Spotify's lyrics page takes it: ♪ over a break and an empty last line where the
// singing ends. Starts are in milliseconds, all 0 when not synced. nil when a source times words
// but has no text for Spotify's own page.
@property (nonatomic, copy) NSArray<NSNumber *> *starts;
@property (nonatomic, copy) NSArray<NSString *> *texts;
@property (nonatomic, copy) NSArray<SGKaraokeLine *> *karaokeLines;
// What the source learned about the track on the way, for the sources asked after it: one that
// matched the track by Spotify's id knows the title and artist the ones searching by name need.
@property (nonatomic, copy) NSString *title, *artist, *album;
@property (nonatomic) NSInteger seconds;
@property (nonatomic) BOOL instrumental;
// The source picked for the track from the player's ⋯ answered with this (SGLyricsKeepChosen), so it stands
// over Spotify's own lines however either is timed. The walk's own answer never is, a pick standing or not.
@property (nonatomic) BOOL picked;
@end

// What is known about the track when a source is asked. Only trackID is always there; the rest is
// filled in by the player, and by whichever source answered before.
@interface SGLyricsQuery : NSObject
@property (nonatomic, copy) NSString *trackID;   // Spotify's base62 id
@property (nonatomic, copy) NSString *title, *artist, *album;
@property (nonatomic) NSInteger seconds;
@end

// The lines as Spotify's own page takes them, ♪ over a break and an empty line at the end.
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts);

// Calls back on the main queue, nil when the source has nothing for the track.
typedef void (^SGLyricsAsk)(SGLyricsQuery *query, void (^done)(SGLyricsResult *result));

@interface SGLyricsProvider : NSObject
@property (nonatomic, copy) NSString *key;      // stored in the order, never shown
@property (nonatomic, copy) NSString *name;     // "BiniLyrics", what the credit reads
@property (nonatomic, copy) NSString *detail;   // one line under the name on the Lyrics page
// Searches by title and artist, so it has nothing to ask with until someone has named the track.
// Musixmatch matches by Spotify's id and can go without.
@property (nonatomic) BOOL needsName;
// Has only untimed lines, which never replace lines already found, so it is asked only while there are none
// and Spotify has none of its own.
@property (nonatomic) BOOL untimed;
@property (nonatomic, copy) SGLyricsAsk ask;
@end

// Every source there is, in the order a fresh install asks them.
NSArray<SGLyricsProvider *> *SGLyricsAllProviders(void);
SGLyricsProvider *SGLyricsProviderFor(NSString *key);
// The keys in the user's order, the ones switched off left out. An empty list means the mod leaves
// Spotify's own lyrics alone.
NSArray<NSString *> *SGLyricsOrder(void);
void SGLyricsSetOrder(NSArray<NSString *> *keys);
BOOL SGLyricsEnabled(void);   // any source at all is on

// Asks the sources in order and merges what they give, on the main queue. nil when none had lyrics.
void SGLyricsFetch(NSString *trackID, void (^done)(SGLyricsResult *result));
// NO once every source has said it has nothing for the track; safe from any thread.
BOOL SGLyricsMayHave(NSString *trackID);
// Starts the walk for a track before anyone has asked, so the answer is in when Spotify's request
// comes; a walk already run or running is left alone. Safe from any thread.
void SGLyricsPrefetch(NSString *trackID);
// What Spotify's own metadata says of a track: 1 has lyrics, 0 has none, -1 not seen yet. The
// player-track hook notes it, and the walk when it names a track; the request hook reads it to send a
// track Spotify has none for to the donor, and the walk to pass Genius over. Safe from any thread.
NSInteger SGLyricsSpotifyHas(NSString *trackID);
void SGLyricsNoteSpotifyHas(NSString *trackID, BOOL has);
// The remote-config values the lyrics feature forces while a source is on, nil for any other flag:
// the player gives its cards this long to load before it shows the list without the slow ones, and
// a source of the mod's can take longer than Spotify's default to answer.
id SGLyricsForcedFlag(NSString *key);
// Set on the requests the mod sends to spclient itself, so the request hook leaves them alone.
extern NSString *const SGLyricsOwnRequestKey;
// The name of the source the lines shown for the track came from, nil until they arrive.
NSString *SGLyricsCreditFor(NSString *trackID);
void SGLyricsSetCredit(NSString *trackID, NSString *name);
// What the walk learned of a credit, by its text: whether it must show, and the links it carries.
// SGLyricsCreditLinks takes the credit or any text holding it, as Spotify's "Lyrics provided by ..."
// does. Main queue.
BOOL SGLyricsCreditRequired(NSString *credit);
NSArray<SGLyricsLink *> *SGLyricsCreditLinks(NSString *text);
// Opens one link at once; two or more as an action sheet held to `from`.
void SGLyricsOpenCreditLinks(NSArray<SGLyricsLink *> *links, UIView *from);
// Turns an install's old Musixmatch switches into an order. Called once, before anything reads one.
void SGLyricsMigrateLegacyKeys(void);

// The requests the sources share; each calls back on the main queue, with nil when it failed.
NSURL *SGLyricsURL(NSString *base, NSDictionary<NSString *, NSString *> *query);
void SGLyricsGetJSON(NSURL *url, NSDictionary<NSString *, NSString *> *headers, void (^done)(id root));
// The same with the reply's status and headers, and the body read whatever the status: an error's
// body says why. response is nil when the request never got an answer.
void SGLyricsGetJSONReply(NSURL *url, NSDictionary<NSString *, NSString *> *headers, void (^done)(id root, NSHTTPURLResponse *response));
void SGLyricsGetText(NSURL *url, void (^done)(NSString *text));
// For the one source that is asked a question rather than sent to an address. body is anything
// NSJSONSerialization writes; nothing is sent at all when it is not.
void SGLyricsPostJSON(NSURL *url, NSDictionary<NSString *, NSString *> *headers, id body, void (^done)(id root));
// Every source's reply goes through this, so a walk that lost a request to the network or a busy
// server is not kept as "no lyrics". The two above call it themselves.
void SGLyricsNoteReply(NSURLResponse *response, NSError *error);
// What it counts as lost: the network failed, or the server answered 429 or 5xx.
BOOL SGLyricsReplyFailed(NSURLResponse *response, NSError *error);

// SGTTML.m. Apple Music's TTML as timed lines, the voices already turned into alignments and each
// line's translation and pronunciation added where the head has them; nil when the document holds no
// line the page could show.
NSArray<SGKaraokeLine *> *SGTTMLLines(NSString *xml);
// The letters and digits of a text alone, lowercased: a pronunciation or a translation equal to its
// line's this way reads the same as the line and is left out.
NSString *SGLyricsBareText(NSString *text);
// A line's pronunciation: timed `words` where the source has them, else `plain` estimated across the
// line's own time; nil when it has neither or reads the same as `of`.
SGKaraokeLine *SGLyricsPronunciation(NSArray<SGKaraokeWord *> *words, NSString *plain, SGKaraokeLine *of);

// The languages a translation can be asked for in, as language tags ("en", "es"), the first one ""
// for whatever the source has; SGKeyLyricsTranslationLanguage indexes it, so it only ever grows at
// the end. Their names, in English, for the Lyrics page.
NSArray<NSString *> *SGLyricsTranslationLanguages(void);
NSArray<NSString *> *SGLyricsTranslationLanguageNames(void);
// The tag of the language asked for, nil for whatever the source has.
NSString *SGLyricsTranslationLanguage(void);


// The sources themselves, each in its own file.
extern SGLyricsAsk SGBiniLyricsAsk;
extern SGLyricsAsk SGMusixmatchAsk;
// Musixmatch's community translations of a track into `language`, by SGMusixmatchLineKey of each original
// line, or nil when there are none. Main queue, and at once when the answer is in. Asked once per
// track and language a launch, again only after an answer cut short.
void SGMusixmatchTranslations(NSString *trackID, NSString *language, void (^done)(NSDictionary<NSString *, NSString *> *byLine));
NSString *SGMusixmatchLineKey(NSString *text);
// Copies of the lines with the translations matched in, in a new array; nil when none matched.
NSArray<SGKaraokeLine *> *SGMusixmatchTranslatedLines(NSArray<SGKaraokeLine *> *lines, NSDictionary<NSString *, NSString *> *byLine);
// A richsync body, the JSON array its richsync_body holds, as word timed lines; nil when it has none.
SGLyricsResult *SGMusixmatchRichsyncResult(id body);
extern SGLyricsAsk SGUnisonAsk;
extern SGLyricsAsk SGNetEaseAsk;
extern SGLyricsAsk SGLrcLibAsk;
extern SGLyricsAsk SGSpicyLyricsAsk;
extern SGLyricsAsk SGQQMusicAsk;
extern SGLyricsAsk SGKuGouAsk;
extern SGLyricsAsk SGGeniusAsk;
// Genius.m. The rows of the lyrics in Genius's embed script, "" between stanzas and the [Chorus]
// headings left out; nil when the script is not the shape it reads or holds no line.
NSArray<NSString *> *SGGeniusEmbedRows(NSString *js);

// LrcLib.m. Timed LRC as a synced result, nil when no line in it is timed.
SGLyricsResult *SGLyricsLRCResult(NSString *lrc);
// Lyricsfile.m. LRCLIB's Lyricsfile YAML as word timed lines; nil when it times no word, or is not
// a Lyricsfile 1.0 this reads.
NSArray<SGKaraokeLine *> *SGLyricsfileLines(NSString *yaml);
// Untimed rows as a result: every start 0, a ♪ for each empty row.
SGLyricsResult *SGLyricsPlainResult(NSArray<NSString *> *rows);
// NetEase.m. Word timed lines from NetEase's yrc, or with krc from KuGou's KRC text; nil for none.
NSArray<SGKaraokeLine *> *SGLyricsPieceLines(NSString *body, BOOL krc);
// QQMusic.m, for it and KuGou. A title as the two are matched by: lowercased, without spaces,
// punctuation or symbols, ideographic and full width ones included. The artist without whoever is
// featured ("A feat. B" is A). Whether a credited name and the track's artist name the same one: the
// key of either holds the other's, the featured artists left out.
NSString *SGLyricsMatchKey(NSString *text);
NSString *SGLyricsLeadArtist(NSString *artist);
BOOL SGLyricsSameArtist(NSString *credited, NSString *artist);
// What the two catalogs are asked as: a browser.
#define SGLyricsBrowserAgent @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
// KuGou.m. A download's base64 content as lines, nil when it is not KRC or holds no timed line.
NSArray<SGKaraokeLine *> *SGKuGouLines(NSString *content);

// SongMatch.m, for the searches that answer with whole songs (Genius, LRCLIB). Text as the two are
// matched by: letters and digits only, lowercase, accents gone and apostrophes closed up, so "Don’t"
// and "dont" read alike across sources. A title with a version in brackets or after " - " set aside
// ("Song (feat. X) - Remastered 2011" is "Song"), and the version words of the track's title, its
// guests left out ("Old Town Road (feat. Billy Ray Cyrus) - Remix" is {remix}). How closely a song
// a catalog names by title and artists is the track: 0 when it is not (another title, or none of its
// artists is the track's lead), 1 for another version of it, 2 for the plain song, 3 for the same version.
NSString *SGLyricsFoldedText(NSString *text);
NSString *SGLyricsBareTitle(NSString *title);
NSSet<NSString *> *SGLyricsTitleVersion(NSString *title);
NSInteger SGLyricsSongRank(NSString *title, NSString *artist, NSString *songTitle, NSArray<NSString *> *songArtists);
// Genius's search, which the lyrics source (Genius.m) and the line meanings (LyricsMeanings/Meanings.m)
// both ask: its address, what it is asked for a track, and the song in its reply that is the track, as
// SGLyricsSongRank tells: of several, the same version wins, then the plain song. nil when none is, or
// the track is an instrumental or karaoke version, since Genius files the words under the song.
#define SGGeniusSearchURL @"https://genius.com/api/search/song"
NSDictionary<NSString *, NSString *> *SGGeniusSearchQuery(NSString *title, NSString *artist);
NSNumber *SGGeniusSongIn(NSDictionary *response, NSString *title, NSString *artist);

// SpicyLyrics.m. Its key in the order; whether the user's own API key is in the Keychain; what keeps
// it from answering, for its row on the sources page ("Needs a key", why the key was refused), nil
// while nothing does; the Lyrics page's row that sets or removes the key; and an API response as
// lines, nil when it has none.
extern NSString *const SGSpicyLyricsKey;
BOOL SGSpicyLyricsKeySet(void);
// Removes the key from the Keychain (Mod > Clear Keychain).
void SGSpicyLyricsForgetKey(void);
NSString *SGSpicyLyricsStatus(void);
@class SGModRow;
SGModRow *SGSpicyLyricsKeyRow(void);
SGLyricsResult *SGSpicyLyricsResult(id root);

UIViewController *SGLyricsSourcesPage(void);   // the ordered list on the Lyrics page

// LyricsPick.m. The source picked for a track from the redesigned player's ⋯, which may be lower in the order
// than the one that answered (issue #67). The pick is a track's id against a source's key, kept until Spotify
// quits; a track's walk asks its picked source first, the rest of the order after it. Main queue.
NSString *SGLyricsChosenSource(NSString *trackID);
// Every source in the order is asked for the track at once, the answers kept for the last few tracks, and
// `done` gets the ones with lines, by key, when all have answered or `wait` has passed.
void SGLyricsOffers(NSString *trackID, NSTimeInterval wait, void (^done)(NSDictionary<NSString *, SGLyricsResult *> *offers));
// Makes the offer of `key` the track's lyrics now, everywhere they show, and posts
// SGLyricsSourceChosenNotification (object the track's id) once its lines are kept.
void SGLyricsChooseSource(NSString *trackID, NSString *key);
// Drops the track's pick and puts back what the order had chosen, shown before the first pick, the same way.
void SGLyricsChooseAutomatic(NSString *trackID);
// A walk under way at the track's first pick has ended with `lyrics`: that is what Automatic puts back.
void SGLyricsNoteOrderChoice(NSString *trackID, SGLyricsResult *lyrics);
// A walk found the track's pick `key` answering no lines, or switched off: the pick goes, so the menu shows
// Automatic over the order's answer the walk goes on to. Nothing when the track's pick is another by now.
void SGLyricsDropChoice(NSString *trackID, NSString *key);
extern NSNotificationName const SGLyricsSourceChosenNotification;
// LyricsSources.m, for LyricsPick.m: the query a walk would start with, and a picked answer kept as the walk's.
SGLyricsQuery *SGLyricsQueryFor(NSString *trackID);
// How many source requests have failed since launch; any thread.
NSUInteger SGLyricsFailures(void);
void SGLyricsKeepChosen(NSString *trackID, SGLyricsResult *result);
// The walk's kept answer for the track: a result, NSNull for none, nil when not kept; and that put back.
id SGLyricsKeptAnswer(NSString *trackID);
void SGLyricsRestoreKept(NSString *trackID, id kept);
