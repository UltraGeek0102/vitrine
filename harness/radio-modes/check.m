#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Shared/AdBlock/RadioModes.h"

BOOL SGHidden(NSString *key) { return getenv("SG_RADIO_TEST_OFF") == NULL; }
@interface SPTPlayerRestrictions : NSObject <NSCopying>
@property NSSet *disallowTogglingShuffleReasons, *disallowTogglingRepeatContextReasons, *disallowTogglingRepeatTrackReasons;
- (NSDictionary *)serializedDictionary;
- (BOOL)disallowTogglingShuffle;
- (BOOL)disallowTogglingRepeatContext;
- (BOOL)disallowTogglingRepeatTrack;
@end
@implementation SPTPlayerRestrictions
- (NSDictionary *)serializedDictionary {
    return @{@"shuffle":self.disallowTogglingShuffleReasons, @"context":self.disallowTogglingRepeatContextReasons,
             @"track":self.disallowTogglingRepeatTrackReasons};
}
- (id)copyWithZone:(NSZone *)zone {
    SPTPlayerRestrictions *copy = [SPTPlayerRestrictions new];
    copy.disallowTogglingShuffleReasons = self.disallowTogglingShuffleReasons;
    copy.disallowTogglingRepeatContextReasons = self.disallowTogglingRepeatContextReasons;
    copy.disallowTogglingRepeatTrackReasons = self.disallowTogglingRepeatTrackReasons;
    return copy;
}
- (BOOL)disallowTogglingShuffle { return self.disallowTogglingShuffleReasons.count > 0; }
- (BOOL)disallowTogglingRepeatContext { return self.disallowTogglingRepeatContextReasons.count > 0; }
- (BOOL)disallowTogglingRepeatTrack { return self.disallowTogglingRepeatTrackReasons.count > 0; }
@end
@interface SPTPlayerState : NSObject
@property SPTPlayerRestrictions *restrictions;
@property NSString *playbackId, *contextURI;
@end
@implementation SPTPlayerState
@end
@interface ESPCommandOptions : NSObject <NSCopying>
@property BOOL overrideRestrictions, onlyForLocalDevice;
@property NSString *onlyForPlaybackId;
@end
@implementation ESPCommandOptions
- (id)copyWithZone:(NSZone *)zone {
    ESPCommandOptions *copy = [ESPCommandOptions new];
    copy.overrideRestrictions = self.overrideRestrictions;
    copy.onlyForLocalDevice = self.onlyForLocalDevice;
    copy.onlyForPlaybackId = self.onlyForPlaybackId;
    return copy;
}
@end
#define REQUEST(CLASS, PROP) \
@interface CLASS : NSObject \
@property BOOL PROP; \
@property ESPCommandOptions *options; \
@end \
@implementation CLASS \
@end
REQUEST(ESPSetShufflingContextRequest, shufflingContext)
REQUEST(ESPSetRepeatingContextRequest, repeatingContext)
REQUEST(ESPSetRepeatingTrackRequest, repeatingTrack)
@interface SPTPlayerOptionOverrides : NSObject
@property NSNumber *shufflingContext, *repeatingContext, *repeatingTrack, *playbackSpeed;
@property NSDictionary *modes;
@end
@implementation SPTPlayerOptionOverrides
@end
static ESPCommandOptions *originalOptions;
@interface ESPSetOptionsRequest : NSObject
@property ESPCommandOptions *options;
@property SPTPlayerOptionOverrides *changes;
@property id shufflingContext, repeatingContext, repeatingTrack;
@end
@implementation ESPSetOptionsRequest
- (instancetype)init {
    if ((self = [super init])) self.options = originalOptions;
    return self;
}
@end

static BOOL shouldThrow, reconstructState;
static void (^nested)(void);
@interface SPTEsperantoPlayer : NSObject
@property (nonatomic) SPTPlayerState *state;
- (id)setShufflingContext:(BOOL)on;
- (id)setRepeatingContext:(BOOL)on;
- (id)setRepeatingTrack:(BOOL)on;
- (id)setOptions:(id)changes loggingParams:(id)logging;
@end
@implementation SPTEsperantoPlayer
@synthesize state = _state;
- (SPTPlayerState *)state {
    if (!reconstructState || !_state) return _state;
    SPTPlayerState *rebuilt = [SPTPlayerState new];
    rebuilt.playbackId = _state.playbackId; rebuilt.contextURI = _state.contextURI;
    SPTPlayerRestrictions *raw = _state.restrictions;
    rebuilt.restrictions = [SPTPlayerRestrictions new];
    rebuilt.restrictions.disallowTogglingShuffleReasons = raw.disallowTogglingShuffleReasons;
    rebuilt.restrictions.disallowTogglingRepeatContextReasons = raw.disallowTogglingRepeatContextReasons;
    rebuilt.restrictions.disallowTogglingRepeatTrackReasons = raw.disallowTogglingRepeatTrackReasons;
    return rebuilt;
}
- (id)setOptions:(id)changes loggingParams:(id)logging {
    ESPSetOptionsRequest *r = [ESPSetOptionsRequest new]; r.changes = changes;
    SPTPlayerOptionOverrides *bits = [changes isKindOfClass:SPTPlayerOptionOverrides.class] ? changes : nil;
    if ([bits shufflingContext]) { (void)r.shufflingContext; r.shufflingContext = [bits shufflingContext]; }
    if ([bits repeatingContext]) { (void)r.repeatingContext; r.repeatingContext = [bits repeatingContext]; }
    if ([bits repeatingTrack]) { (void)r.repeatingTrack; r.repeatingTrack = [bits repeatingTrack]; }
    return r;
}
- (id)setShufflingContext:(BOOL)on {
    if (shouldThrow) @throw [NSException exceptionWithName:@"test" reason:nil userInfo:nil];
    if (nested) { void (^call)(void) = nested; nested = nil; call(); }
    ESPSetShufflingContextRequest *r = [ESPSetShufflingContextRequest new];
    r.options = originalOptions;
    r.shufflingContext = on;
    return r;
}
- (id)setRepeatingContext:(BOOL)on {
    ESPSetRepeatingContextRequest *r = [ESPSetRepeatingContextRequest new];
    r.options = originalOptions;
    r.repeatingContext = on;
    return r;
}
- (id)setRepeatingTrack:(BOOL)on {
    ESPSetRepeatingTrackRequest *r = [ESPSetRepeatingTrackRequest new];
    r.options = originalOptions;
    r.repeatingTrack = on;
    return r;
}
@end
static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)
static void setReasons(SPTPlayerRestrictions *r, NSSet *v) {
    r.disallowTogglingShuffleReasons = v;
    r.disallowTogglingRepeatContextReasons = v;
    r.disallowTogglingRepeatTrackReasons = v;
}
int main(void) { @autoreleasepool {
    BOOL active = SGHidden(nil);
    CHECK(!SGRadioModeReasonsOnly(nil));
    CHECK(!SGRadioModeReasonsOnly((id)@[@"radio"]));
    CHECK(!SGRadioModeReasonsOnly([NSSet set]));
    CHECK(!SGRadioModeReasonsOnly([NSSet setWithObject:@42]));
    SPTPlayerRestrictions *r = [SPTPlayerRestrictions new];
    SPTEsperantoPlayer *player = [SPTEsperantoPlayer new];
    player.state = [SPTPlayerState new]; player.state.restrictions = r;
    player.state.playbackId = @"playback-123"; player.state.contextURI = @"context-A";
    originalOptions = [ESPCommandOptions new];
    originalOptions.onlyForLocalDevice = YES; originalOptions.onlyForPlaybackId = @"playback-123";
    NSArray *cases = @[@[], @[@"radio"], @[@"autoplay"], @[@"endless_context"],
        @[@"radio", @"autoplay", @"endless_context"], @[@"ad_disallow"], @[@"radio", @"ad_disallow"],
        @[@"autoplay", @"mft_disallow"], @[@"autoplay", @"future_unknown_reason"], @[@"jam_is_active"]];
    for (NSArray *values in cases) {
        NSSet *reasons = [NSSet setWithArray:values]; setReasons(r, reasons);
        BOOL overridden = active && SGRadioModeReasonsOnly(reasons);
        CHECK([r.disallowTogglingShuffleReasons isEqual:overridden ? [NSSet set] : reasons]);
        CHECK(r.disallowTogglingShuffle == (!overridden && reasons.count > 0));
        CHECK([r.disallowTogglingRepeatContextReasons isEqual:overridden ? [NSSet set] : reasons]);
        CHECK(r.disallowTogglingRepeatContext == (!overridden && reasons.count > 0));
        CHECK([r.disallowTogglingRepeatTrackReasons isEqual:overridden ? [NSSet set] : reasons]);
        CHECK(r.disallowTogglingRepeatTrack == (!overridden && reasons.count > 0));
        CHECK([[r serializedDictionary][@"shuffle"] isEqual:reasons]);
        player.state.restrictions = [[r copy] copy]; // Repeated copies must preserve raw restrictions.
        CHECK([[player.state.restrictions serializedDictionary][@"context"] isEqual:reasons]);
        for (NSNumber *toggle in @[@NO, @YES]) {
            NSArray *requests = @[[player setShufflingContext:toggle.boolValue], [player setRepeatingContext:toggle.boolValue], [player setRepeatingTrack:toggle.boolValue]];
            for (id request in requests) {
                ESPCommandOptions *options = [(ESPSetShufflingContextRequest *)request options];
                CHECK(options.overrideRestrictions == overridden);
                CHECK(options.onlyForLocalDevice);
                CHECK([options.onlyForPlaybackId isEqual:@"playback-123"]);
                CHECK((options == originalOptions) == !overridden);
            }
            CHECK([[requests[0] valueForKey:@"shufflingContext"] boolValue] == toggle.boolValue);
            CHECK([[requests[1] valueForKey:@"repeatingContext"] boolValue] == toggle.boolValue);
            CHECK([[requests[2] valueForKey:@"repeatingTrack"] boolValue] == toggle.boolValue);
            CHECK(!originalOptions.overrideRestrictions);
        }
    }
    player.state.restrictions = r;
    // Scope is per mode, and a direct ESP request never inherits a completed call's decision.
    setReasons(r, [NSSet setWithObject:@"radio"]);
    r.disallowTogglingRepeatTrackReasons = [NSSet setWithObject:@"ad_disallow"];
    CHECK(((ESPSetRepeatingTrackRequest *)[player setRepeatingTrack:YES]).options == originalOptions);
    ESPSetShufflingContextRequest *direct = [ESPSetShufflingContextRequest new]; direct.shufflingContext = YES;
    CHECK(!direct.options.overrideRestrictions);
    // An exception must restore thread-local state.
    shouldThrow = YES;
    @try { [player setShufflingContext:YES]; } @catch (NSException *e) {}
    shouldThrow = NO; direct.shufflingContext = NO;
    CHECK(!direct.options.overrideRestrictions);
    // A blocked nested command must not lose its caller's permitted decision.
    nested = ^{ CHECK(((ESPSetRepeatingTrackRequest *)[player setRepeatingTrack:YES]).options == originalOptions); };
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options.overrideRestrictions == active);
    // The UI's combined request: off -> context -> track -> off, no incidental speed/mode bypass.
    setReasons(r, [NSSet setWithObject:@"autoplay"]);
    SPTPlayerOptionOverrides *changes = [SPTPlayerOptionOverrides new];
    for (NSArray *bits in @[@[@YES, @NO], @[@NO, @YES], @[@NO, @NO]]) {
        changes.repeatingContext = bits[0]; changes.repeatingTrack = bits[1];
        ESPSetOptionsRequest *request = [player setOptions:changes loggingParams:nil];
        CHECK(request.options.overrideRestrictions == active);
        CHECK(request.options.onlyForLocalDevice);
        CHECK(request.changes == changes);
    }
    player.state.restrictions = r;
    (void)player.state; // Observe positive radio evidence before an optimistic empty update.
    reconstructState = YES;
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options.overrideRestrictions == active);
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options.overrideRestrictions == active);
    reconstructState = NO;
    changes.playbackSpeed = @1.5;
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options == originalOptions);
    changes.playbackSpeed = nil; changes.modes = @{@"media": @"VIDEO"};
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options == originalOptions);
    changes.modes = nil;
    r.disallowTogglingRepeatTrackReasons = [NSSet setWithObjects:@"autoplay", @"ad_disallow", nil];
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options == originalOptions);
    changes.repeatingTrack = nil; // Unchanged, so its restriction cannot block repeat-context.
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options.overrideRestrictions == active);
    changes.repeatingContext = nil;
    CHECK(((ESPSetOptionsRequest *)[player setOptions:changes loggingParams:nil]).options == originalOptions);
    nested = ^{
        ESPSetRepeatingContextRequest *other = [ESPSetRepeatingContextRequest new]; other.repeatingContext = YES;
        CHECK(!other.options.overrideRestrictions);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [NSThread detachNewThreadWithBlock:^{
            ESPSetShufflingContextRequest *otherThread = [ESPSetShufflingContextRequest new]; otherThread.shufflingContext = YES;
            CHECK(!otherThread.options.overrideRestrictions);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    };
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options.overrideRestrictions == active);
    // Empty optimistic updates retain only positive evidence for this playback.
    setReasons(r, [NSSet setWithObject:@"radio"]); (void)player.state;
    setReasons(r, [NSSet set]);
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:NO]).options.overrideRestrictions == active);
    // An explicit new restriction revokes the evidence, even if followed by emptiness.
    setReasons(r, [NSSet setWithObject:@"ad_disallow"]); (void)player.state;
    setReasons(r, [NSSet set]);
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options == originalOptions);
    setReasons(r, [NSSet setWithObject:@"radio"]); (void)player.state;
    setReasons(r, [NSSet set]); player.state.playbackId = @"new-playback";
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options == originalOptions);
    setReasons(r, [NSSet setWithObject:@"radio"]); (void)player.state;
    setReasons(r, [NSSet set]); player.state.contextURI = @"new-context";
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options == originalOptions);
    setReasons(r, [NSSet setWithObject:@"radio"]); player.state.playbackId = nil;
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options == originalOptions);
    // Missing state leaves the request alone.
    player.state = nil;
    CHECK(((ESPSetShufflingContextRequest *)[player setShufflingContext:YES]).options == originalOptions);
    originalOptions.overrideRestrictions = YES;
    CHECK(((ESPSetRepeatingContextRequest *)[player setRepeatingContext:YES]).options == originalOptions);
    printf("radio modes (%s): %d checks, %d failures\n", active ? "on" : "off", checks, failures);
    return failures != 0;
} }
