// Music Haptics > In the Background: iOS's own Music Haptics for Spotify. The system plays Apple Music's haptic track
// for a recording, in the background and on the lock screen too, for an app that declares
// MusicHapticsSupported (plist/liquid-glass.plist) and names the recording in its now playing info. Spotify
// names none, so the mod adds one to Spotify's info (Shared/Player/NowPlayingExtras.h), exactly one:
//
//   1. The track's ISRC, from Spotify's own metadata (SGHapticTrack.h), asked with the headers of Spotify's
//      own spclient requests. No search by name: a live take or a remaster has a name of the same song.
//   2. Apple Music's song for that ISRC, asked of its catalog by ISRC and taken only when it is the same
//      length within 2 s and has a haptic track. Its catalog id goes under MediaPlayer's iTunes Store
//      identifier key, the name MediaPlayer exports for it, resolved at runtime and skipped when missing.
//      The ISRC is left off then: MediaRemoteUI asks for the ISRC first when both are there, and an ISRC it
//      cannot find showed "Music Haptics unavailable" over the matched song playing (iOS 27.2).
//   3. Failing a song, the ISRC itself, and iOS asked whether it has a haptic track for it.
//
// A new track or a flipped switch takes the old identifier off at once, before anything is asked, and every
// answer carries the revision it was asked under, so one for an earlier track is dropped. Nothing is
// published while Music Haptics is off in Settings > Accessibility, or with In the Background off.
// iOS repeats its notifications as the now playing info changes; only a change in whether it is on or
// paused is acted on, since sending the info again on each would feed back into the system service.
//
// The handover to the mod's own (MusicHaptics.x): iOS plays the haptic track of the now playing song
// whether the app is in front or not (MAMusicHapticsManager reports its status per now playing song, with no
// foreground or background to it), so the mod's own stands down for the song entirely, from the moment the
// track is asked about (Checking) through an identifier with a haptic track named (Ready), paused from
// Control Center or not. It plays again once the answer is that iOS has none (Unavailable), or with nothing
// asked (Waiting: In the Background off, iOS's switch off, nothing playing). Ready is taken on the catalog's
// word or iOS's availability check, not the status observer's report that iOS plays it, since when that
// observer fires for an app's song is unproven: waiting on it could leave both playing.
// ponytail: quiet while Checking means a song with no haptic track gets the mod's own only once the lookup
// answers, a moment with the ISRC kept, up to kSpotifyTries * kSpotifyRetryAfter when Spotify does not answer.
//
// ponytail: the identifier rides on Spotify's info by title, as NowPlayingExtras matches it, so a next track
// with the same title can carry the last one's for the moment before the player reports it. Matching by the
// info's external content identifier would close that, in NowPlayingExtras for every owner.
// ponytail: an answer for an earlier track is dropped rather than its request canceled; the lookups are
// kept and shared, and a cancel would take the answer from another asker waiting on it.
#import <MediaAccessibility/MediaAccessibility.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "Haptics.h"
#import "SGHapticTrack.h"

static NSString *const kExtendedMetadata = @"https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata";
// A request that got no answer is sent this many times in all, this far apart.
static const NSUInteger kSpotifyTries = 3;
static const NSTimeInterval kSpotifyRetryAfter = 4;
static const NSUInteger kKeptISRCs = 100;

#pragma mark - Spotify's ISRC

// By track URI; NSNull for a track Spotify answered for with no ISRC.
static NSCache<NSString *, id> *sg_isrcs;

// `done` gets the ISRC, or nil, on the main queue. The headers are read again for every try: a refused one
// may have expired, and Spotify's next request of its own brings a fresh one. They are never logged.
static void askSpotify(NSString *uri, NSUInteger triesLeft, void (^done)(NSString *isrc)) {
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kExtendedMetadata]];
        request.HTTPMethod = @"POST";
        [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:name];
        }];
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];
        request.HTTPBody = SGHapticTrackRequest(uri);
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            BOOL answered = NO;
            NSString *isrc = status == 200 ? SGHapticISRCInReply(data, uri, &answered) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (answered) {
                    [sg_isrcs setObject:isrc ?: (id)NSNull.null forKey:uri];
                    done(isrc);
                    return;
                }
                SGLog(@"isrc: Spotify's metadata for %@ not answered (%ld, %@), %lu tries left", uri, (long)status,
                      error.localizedDescription, (unsigned long)triesLeft - 1);
                if (triesLeft <= 1) {
                    done(nil);
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpotifyRetryAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    askSpotify(uri, triesLeft - 1, done);
                });
            });
        }] resume];
    });
}

void SGSpotifyISRC(NSString *uri, NSUInteger tries, void (^done)(NSString *isrc)) {
    id kept = [sg_isrcs objectForKey:uri];
    if (kept) {
        done(kept == NSNull.null ? nil : kept);
        return;
    }
    askSpotify(uri, MAX(tries, 1), done);
}

#pragma mark - iOS

// MediaPlayer's iTunes Store identifier key: exported as _MPNowPlayingInfoPropertyiTunesStoreIdentifier
// (the iOS 27 SDK's MediaPlayer.tbd lists __MPNowPlayingInfoPropertyiTunesStoreIdentifier), not in its headers.
static NSString *storeIDKey(void) {
    static NSString *key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *slot = dlsym(RTLD_DEFAULT, "_MPNowPlayingInfoPropertyiTunesStoreIdentifier");
        id value = slot ? (__bridge id)*(void **)slot : nil;
        key = [value isKindOfClass:NSString.class] ? value : nil;
        if (!key) SGLog(@"music haptics: MediaPlayer has no iTunes Store identifier key, the ISRC is named instead");
    });
    return key;
}

// Whether Music Haptics is on in Settings > Accessibility. On iOS 27 isActive follows Control Center's pause
// instead and stays YES with the switch off; the read-only musicHapticsEnabled tells them apart where it is.
API_AVAILABLE(ios(18.0))
static BOOL systemEnabled(MAMusicHapticsManager *manager) {
    SEL enabled = NSSelectorFromString(@"musicHapticsEnabled");
    if ([manager respondsToSelector:enabled]) return ((BOOL (*)(id, SEL))objc_msgSend)(manager, enabled);
    return manager.isActive;
}

#pragma mark - following the player

typedef NS_ENUM(NSInteger, SGNativePhase) {
    SGNativeWaiting,       // nothing to look up yet
    SGNativeChecking,      // asking Spotify, Apple or iOS
    SGNativeReady,         // an identifier with a haptic track is named
    SGNativeUnavailable,   // nothing named, or iOS has no haptic track for it
};

API_AVAILABLE(ios(18.0))
@interface SGNativeMusicHaptics : NSObject <SGPlayerStateObserver>
- (void)follow:(SPTPlayerState *)state again:(BOOL)again;
- (void)systemChanged;
@end

@implementation SGNativeMusicHaptics {
    NSString *_track;
    NSUInteger _revision;
    SGNativePhase _phase;
    NSString *_isrc, *_songID;   // what the track is known by, and Apple's song when one matched
    BOOL _known, _enabled, _active;
    id _observer;
    NSString *_observedCode;
    BOOL _observedActive;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self follow:state again:NO];
}

- (void)setPhase:(SGNativePhase)phase {
    _phase = phase;
    // follow: leaves Waiting only with In the Background on, iOS's switch on and a track playing.
    SGMusicHapticsSetSystemCovers(phase == SGNativeChecking || phase == SGNativeReady);
    [self showStatus];
}

- (void)showStatus {
    NSString *status;
    if (!_enabled) status = @"Off in iOS";
    else if (!_active) status = @"Paused";
    else if (_phase == SGNativeChecking) status = @"Checking";
    else if (_phase == SGNativeUnavailable) status = @"Unavailable";
    else if (_phase == SGNativeWaiting) status = @"Waiting";
    // A status callback alone is not proof: it has to be for the identifier named, and iOS active for it.
    else status = _observedActive && ([_observedCode isEqualToString:_isrc] || [_observedCode isEqualToString:_songID]) ? @"Playing" : @"Ready";
    SGSetMusicHapticsStatus(status);
}

- (void)publish:(NSDictionary *)extras title:(NSString *)title {
    SGNowPlayingSetExtras(@"haptics", extras, title);
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"music haptics: %@ named for iOS's Music Haptics", extras.allValues.firstObject);
}

// `again` follows the same track anew: a switch, or iOS's, changed.
- (void)follow:(SPTPlayerState *)state again:(BOOL)again {
    NSString *track = SGURIString(state.track.URI);
    if (!again && (track == _track || [track isEqualToString:_track])) return;
    _track = track;
    NSUInteger revision = ++_revision;
    _isrc = _songID = nil;
    _observedCode = nil;
    _observedActive = NO;
    // Off before anything is asked, so no answer can arrive while the last track's is still named.
    SGNowPlayingSetExtras(@"haptics", nil, nil);
    if (!SGMusicHapticsInBackground() || !_enabled || !track) {
        self.phase = SGNativeWaiting;
        return;
    }
    // Episodes, ads and local files have no ISRC of Spotify's.
    if (!SGHapticIsTrackURI(track)) {
        self.phase = SGNativeUnavailable;
        return;
    }
    NSString *title = state.track.trackTitle;
    id length = state.track.metadata[@"duration"];
    double ms = [length respondsToSelector:@selector(doubleValue)] && [length doubleValue] > 0 ? [length doubleValue] : state.duration * 1000;
    self.phase = SGNativeChecking;
    SGSpotifyISRC(track, kSpotifyTries, ^(NSString *isrc) {
        if (revision != self->_revision) return;
        if (!isrc) {
            self.phase = SGNativeUnavailable;
            return;
        }
        self->_isrc = isrc;
        SGMotionSongsWithISRC(isrc, ^(NSArray *songs) {
            if (revision != self->_revision) return;
            NSString *song = SGHapticSongIn(songs, isrc, ms), *key = storeIDKey();
            if (song && key) {
                self->_songID = song;
                [self publish:@{key: @(song.longLongValue)} title:title];
                self.phase = SGNativeReady;
                return;
            }
            [self publish:@{MPNowPlayingInfoPropertyInternationalStandardRecordingCode: isrc} title:title];
            [MAMusicHapticsManager.sharedManager checkHapticTrackAvailabilityForMediaMatchingCode:isrc completionHandler:^(BOOL available) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (revision == self->_revision) self.phase = available ? SGNativeReady : SGNativeUnavailable;
                });
            }];
        });
    });
}

// addStatusObserver: can answer nil while the switch in Accessibility is off, so it is asked again whenever
// iOS's state or the app's comes back.
- (void)observe {
    if (_observer || !_enabled) return;
    __weak SGNativeMusicHaptics *weakSelf = self;
    _observer = [MAMusicHapticsManager.sharedManager addStatusObserver:^(NSString *code, BOOL active) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SGNativeMusicHaptics *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_observedCode = code;
            strongSelf->_observedActive = active;
            static NSUInteger logged;
            if (logged++ < 6) SGLog(@"music haptics: iOS reports %@ %@", code, active ? @"playing" : @"not playing");
            [strongSelf showStatus];
        });
    }];
}

- (void)systemChanged {
    MAMusicHapticsManager *manager = MAMusicHapticsManager.sharedManager;
    BOOL enabled = systemEnabled(manager), active = manager.isActive;
    BOOL first = !_known, wasEnabled = _enabled;
    if (!first && enabled == _enabled && active == _active) {
        [self observe];
        return;
    }
    _known = YES;
    _enabled = enabled;
    _active = active;
    SGSetSystemMusicHapticsOn(enabled);
    SGLog(@"music haptics: iOS's Music Haptics %@, %@", enabled ? @"on" : @"off", active ? @"active" : @"paused");
    [self observe];
    if (first || enabled != wasEnabled) [self follow:SGPlayerState() again:YES];
    else [self showStatus];
}

@end

%ctor {
    // MusicHaptics.x's constructor moves it too, but may run after this one.
    SGMigrateMusicHaptics();
    sg_isrcs = [NSCache new];
    sg_isrcs.countLimit = kKeptISRCs;
    if (@available(iOS 18.0, *)) {
        static SGNativeMusicHaptics *native;
        native = [SGNativeMusicHaptics new];
        SGAddPlayerStateObserver(native);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        void (^changed)(NSNotification *) = ^(NSNotification *note) { [native systemChanged]; };
        // iOS's own may come from any thread: heard there and handed to main without waiting (AGENTS.md).
        void (^changedFromAnywhere)(NSNotification *) = ^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [native systemChanged]; });
        };
        [center addObserverForName:MAMusicHapticsManagerActiveStatusDidChangeNotification object:nil queue:nil usingBlock:changedFromAnywhere];
        // Not in the SDK's headers, though MediaAccessibility exports it: posted as the switch in Accessibility moves.
        void *enabledName = dlsym(RTLD_DEFAULT, "MAMusicHapticsEnabledStatusDidChangeNotification");
        id name = enabledName ? (__bridge id)*(void **)enabledName : nil;
        if ([name isKindOfClass:NSString.class]) [center addObserverForName:name object:nil queue:nil usingBlock:changedFromAnywhere];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:changed];
        // Only In the Background's own flip: Music Haptics' would take iOS's identifier off for nothing.
        __block BOOL background = SGMusicHapticsInBackground();
        [center addObserverForName:SGMusicHapticsSwitchesChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (SGMusicHapticsInBackground() == background) return;
            background = !background;
            [native follow:SGPlayerState() again:YES];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ [native systemChanged]; });
    } else {
        SGSetMusicHapticsStatus(@"Needs iOS 18");
    }
}
