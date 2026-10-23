// A song's lines translated into any language by an AI translator on the user's own API key (Gemini, an
// OpenAI-compatible server, or Anthropic), at a tap in the lyrics' corner menu. Each key lives in the Keychain,
// not in the settings, so a settings export never carries it. Only the lyrics' text and the language go out,
// to the chosen provider.
#import <UIKit/UIKit.h>

@class SGKaraokeLine, SGModRow;

// Posted on the main thread when the saved translations are deleted or Translate any song changes: the lyrics
// page syncs its song again and redraws.
extern NSNotificationName const SGLyricsTranslationsDidChangeNotification;

// On: the translate menu is offered for every song, not only those found in another language.
#define SGKeyLyricsTranslateEverySong @"spotifyglass.lyrics.translateEverySong"
SGModRow *SGTranslateEverySongRow(void);

// The AI translator: a provider's id (gemini, openai, anthropic; unset: gemini), the prompt every provider gets
// (unset: Vitrine's), and per provider spotifyglass.lyrics.<id>.model. An OpenAI-compatible server (unset: OpenAI's)
// is kept in the Keychain beside its key, not here. All read at each translation.
#define SGKeyAITranslator @"spotifyglass.lyrics.ai"
#define SGKeyAIPrompt @"spotifyglass.lyrics.prompt"

// Who made a translation: an AI provider's id with its model, or one of the two on the iPhone. A translation
// saved before sources were kept has neither, and reads as unknown.
#define SGTranslatedOnDevice @"translate"
#define SGTranslatedByAppleIntelligence @"intelligence"
@interface SGTranslationSource : NSObject
@property (nonatomic, copy, readonly) NSString *by, *model;
@property (nonatomic, readonly) NSDate *made;   // nil: not known
+ (instancetype)by:(NSString *)by model:(NSString *)model made:(NSDate *)made;
@property (nonatomic, readonly) NSString *name;   // "Gemini (gemini-flash-latest)", "Translate on iPhone", "Unknown"
@property (nonatomic, readonly) BOOL deletable;   // made by an AI provider, or by no one known
@end

// The chosen provider has its key, a model and, for an OpenAI-compatible one, a usable server URL.
BOOL SGAITranslatorReady(void);
// Removes every provider's key and the OpenAI-compatible server from the Keychain (Mod > Clear Keychain).
void SGAIForgetKeys(void);
// The menu item's words: "Gemini", "Anthropic", or an OpenAI-compatible server's model; and who gets the lyrics.
NSString *SGAITranslatorName(void);
NSString *SGAITranslatorRecipient(void);
// The provider and model a translation asked now is made by.
SGTranslationSource *SGAITranslatorSource(void);

// One translation per line, in order, or nil and a message to show. Main queue. The same song in the
// same language, provider, model and prompt is asked once a launch.
void SGLyricsTranslateWithAI(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                             void (^done)(NSArray<NSString *> *translations, NSString *error));
// Forgets the song's answers kept for the launch, so it is asked again; a nil track forgets every song's.
void SGLyricsForgetAITranslation(NSString *trackID, NSString *languageTag);

// "“Title” by Artist" for a track the player or the local files know, for a translator's instructions; else nil.
NSString *SGLyricsSongName(NSString *trackID);

// The language a translation is asked in: the Lyrics page's, else the phone's own.
NSString *SGLyricsTranslationTarget(void);

// The request a provider is sent, plain being the one without the optional fields some models turn down.
// nil for an unknown provider or a server URL that is not usable.
NSURLRequest *SGAITranslationRequest(NSString *provider, NSString *model, NSString *prompt, NSString *key, BOOL plain);
// An OpenAI-compatible server URL as typed: nil when it is not http(s) with a host or could carry a secret.
NSString *SGAIServerIn(NSString *text);
// A provider's reply read: one translation per line when it has exactly `count`, else nil and in `problem`
// why not (the key, the limit, a filter, a refusal, a length stop, a line count that does not match).
NSArray<NSString *> *SGAITranslationsIn(NSString *provider, id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem);

// The Lyrics page's rows: the provider, its key (and server), its model, and the prompt.
NSArray<SGModRow *> *SGAITranslatorRows(void);

// On the iPhone itself (OnDeviceTranslation.swift): Apple's Translate, with both languages downloaded in the
// Translate app, and Apple Intelligence's model. Each gives one translation per line ("" for a line with no
// words), or nil and a message to show, on the main queue.
@interface SGOnDeviceTranslation : NSObject
@property (class, readonly) BOOL translationAvailable;
+ (BOOL)appleIntelligenceAvailable:(NSString *)languageTag;
+ (void)translate:(NSArray<NSString *> *)lines to:(NSString *)languageTag done:(void (^)(NSArray<NSString *> *lines, NSString *error))done;
// Apple Intelligence works through the song a batch at a time: `progress` gets the lines so far, "" for the rest.
+ (void)translateWithAppleIntelligence:(NSArray<NSString *> *)lines to:(NSString *)languageTag song:(NSString *)song
                              progress:(void (^)(NSArray<NSString *> *lines))progress
                                  done:(void (^)(NSArray<NSString *> *lines, NSString *error))done;
@end

// SavedTranslations.m: a song's translations kept on disk by track and language, matched to lines by their text,
// with who made them and when. The saved ones are the truth for translations made here: syncing fills the lines
// with no translation from them, and takes a made translation off a line that has none saved (after Delete).
// Syncing gives the saved file's source, nil when none of its lines shows; saving gives the new one. Main thread.
SGTranslationSource *SGLyricsSyncSavedTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines);
SGTranslationSource *SGLyricsSaveTranslation(NSString *track, NSString *language, NSArray<SGKaraokeLine *> *lines, SGTranslationSource *source);
// Deletes the song's saved translation and the launch's answers for it, then posts SGLyricsTranslationsDidChangeNotification.
void SGLyricsDeleteSavedTranslation(NSString *track, NSString *language);
// A saved file read: its lines (text to translation) and its source, or nil. A file from before sources were
// kept is the lines alone.
NSDictionary<NSString *, NSString *> *SGSavedTranslationLines(id json, SGTranslationSource **source);
// The Lyrics page's row: how many songs are kept, and a tap to delete them.
SGModRow *SGSavedTranslationsRow(void);
