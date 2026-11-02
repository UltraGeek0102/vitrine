// Player redesign: previous, play and next as bare glyphs, the way the Music app draws them, shuffle and
// repeat left out on request, and the timestamps under the slider in digits of one width, so they stop
// twitching every second.
//
// The glyphs are drawn over Spotify's controls rather than instead of them: each button keeps its
// action, its enabled state, its accessibility and the Gestures zones around it, and the glyph takes no
// touches. Previous and next get theirs inside the button's content view, so the button's own press
// and disabled look carry over; Spotify's icon under it goes transparent on every pass (SPTEncoreIconView
// is a Swift class, which SGRSuppress cannot keep). Play loses its white disc, a plain UIImageView the
// size of the button, which SGRSuppress keeps transparent, and the glyph over it follows the player's state.
//
// Tree (trees/clean/player/01.txt): PlaybackControlsElementsUnit's view holds
// id=SPTNowPlayingPreviousTrackButton 56x56 > UIView > StackView > StackView > SPTEncoreIconView (:257),
// id=SPTNowPlayingPlayButton (PlayButtonView 64x64, :266) > CondensedButton (a UIButton,
// objc-meta-Spotify.txt:207312) > UIImageView 64x64 and a hidden SpinnerView, next to a hidden UIView
// holding a UIImageView (:277), and id=SPTNowPlayingNextTrackButton. DurationElementUnit's view holds
// id=now-playing-time-take-label and id=now-playing-time-remaning-label, SPTEncoreLabels whose UILabel
// is id=...-internal (:227). The sticky header has a play button of its own (:492), which a search
// inside the unit's view never reaches.
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Player.h"

static const CGFloat kSkipGlyphSize = 32, kPlayGlyphSize = 44;
// A spinner that is still up this long after a state change is buffering, not a track starting.
static const NSTimeInterval kSpinnerCheck = 0.6;

// After a tap the glyph shows what the tap asked for, and a state still saying the opposite is taken for
// one sent before the player caught up, for this long; after it the player's word is final.
static const NSTimeInterval kTapTrust = 1.2;

static char kPreviousKey, kNextKey, kPlayKey, kGlyphKey, kTakeKey, kRemainingKey, kRowKey, kShuffleKey, kRepeatKey;
static __weak UIView *sg_playView;
static __weak UIButton *sg_playButton;
static CFTimeInterval sg_tappedUntil;
static BOOL sg_tappedPaused;
static __weak SGRGlyphView *sg_playGlyph;
static __weak UIView *sg_controlsHost;

void SGRPlayerVanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static void logMissing(NSString *what) {
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:what]) return;
    [logged addObject:what];
    SGLog(@"redesign player: %@ not found, left as Spotify's", what);
}

static SGRGlyphView *glyphFor(UIView *owner, NSString *symbol, CGFloat size) {
    SGRGlyphView *glyph = objc_getAssociatedObject(owner, &kGlyphKey);
    if (!glyph) {
        glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:size weight:UIImageSymbolWeightRegular];
        objc_setAssociatedObject(owner, &kGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return glyph;
}

// Centered by the autoresizing mask as well as here: the unit lays out before the buttons in its row
// have a size, so a center set then is the middle of nothing, (0, 0), and no later pass of the unit's
// comes to move it (trees/continuous/1.txt, 2026-09-17: glyphs at {-23.7, -14.7} in 56pt buttons).
static void keepOnTop(UIView *view, UIView *host) {
    if (view.superview != host) {
        view.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                              | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [host addSubview:view];
    } else if (host.subviews.lastObject != view) {
        [host bringSubviewToFront:view];
    }
    view.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
}

#pragma mark - previous and next

static void skipGlyph(UIView *host, NSString *identifier, const void *findKey, NSString *symbol) {
    UIView *button = SGRFindByIdentifier(host, identifier, findKey);
    UIView *content = button.subviews.firstObject;
    if (!content) {
        logMissing(identifier);
        return;
    }
    static Class icon;
    if (!icon) icon = NSClassFromString(@"SPTEncoreIconView");
    SGRGlyphView *glyph = glyphFor(button, symbol, kSkipGlyphSize);
    SGForEachView(content, ^(UIView *view) {
        if (view != glyph && [view isKindOfClass:icon]) SGRPlayerVanish(view);
    });
    keepOnTop(glyph, content);
}

#pragma mark - shuffle and repeat

// Each switched on under Hide on the player (SGRKeyPlayerHideShuffle, SGRKeyPlayerHideRepeat), read at launch. By
// alpha in their slots (with both gone, previous and next spread over them: spreadControls): the row is Spotify's
// stack of five, and setting `hidden` in an Encore stack crashes. Kept by SGRSuppress, since Spotify's state render
// sets a button's alpha back to 1 when shuffle or repeat changes.
static BOOL sg_hideShuffle, sg_hideRepeat;
// The ordinary player's controls, apart from sg_controlsHost, which the DJ's set too.
static __weak UIView *sg_buttonsHost;
static NSString *const kShuffleID = @"Components.UI.ShuffleButton", *const kRepeatID = @"Nowplaying-RepeatButton";

static BOOL isHiddenButton(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    return (sg_hideShuffle && [identifier isEqualToString:kShuffleID])
        || (sg_hideRepeat && [identifier isEqualToString:kRepeatID]);
}

// Spotify also swaps in a new button a moment after the controls lay out (seen for repeat on 9.1.90: the instance
// found leaves the window 40 ms later and another arrives at alpha 1), with no layout pass after it. The new one is
// caught as it arrives. The class is an Encore button's, taken from the first one found (`class`, not a KVO class
// it may be observed through), since its name carries a build hash. It is the class of every Encore button, the
// playlist, album and artist headers' shuffle among them, so only one inside the player's controls goes; any other
// pays a window check and an identifier compare as it moves.
%group SGRPlayerButtonArrival
%hook SGRPlayerButton
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (view.window && isHiddenButton(view) && sg_buttonsHost && [view isDescendantOfView:sg_buttonsHost]) SGRSuppress(view);
}
%end
%end

static void suppressButton(UIView *button) {
    if (!button) return;
    SGRSuppress(button);
    static BOOL hooked;
    if (hooked) return;
    hooked = YES;
    %init(SGRPlayerButtonArrival, SGRPlayerButton = button.class);
}

// Issue #162: with both gone, previous and next spread out over the room the two left, the way the Music app sets
// its three controls: a quarter of the row's span either side of play, which stays in the middle. The row is
// Spotify's stack of five, so they move by a translation of the arranged view that holds each, as the footer's
// glyphs do (SGRPlayerTranslateArranged): a transform survives the stack laying them out again, and the holder
// takes its touches along. With only one of the two gone they stay in their slots, so play stays centered between
// them. The spread follows the switches and the row's shape, not the buttons in it at that moment: Spotify swaps
// repeat for a new one after the controls lay out (SGRPlayerButtonArrival), and a pass that missed the button would
// put previous and next back with no later pass to spread them again. A row of another shape (a podcast's) gets
// its holders back where the stack puts them.
static char kQuietKey, kMovedKey;
// The ends of the row shuffle and repeat were last found in.
static __weak UIView *sg_shuffleSlot;
static __weak UIView *sg_repeatSlot;

// Whether `slot`, an end of the row, is the hidden button's: it holds the button now, or it is the one the button
// was last found in, for the moment Spotify has taken the button out and not yet put the new one in.
static BOOL hiddenSlot(UIView *slot, UIView *button, UIView *__weak *remembered) {
    if (!slot) return NO;
    if (button) *remembered = slot;
    return slot == *remembered;
}

// Marked, so a row that stops spreading puts back only the holders moved here.
static void moveHolder(UIView *holder, UIView *row, CGFloat x) {
    SGRPlayerTranslateArranged(holder, holder, CGPointMake(CGRectGetMidX(holder.bounds), CGRectGetMidY(holder.bounds)), row, x);
    if (!objc_getAssociatedObject(holder, &kMovedKey)) objc_setAssociatedObject(holder, &kMovedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The holder of a hidden button stays where the stack put it and stops taking touches, or one over the moved
// next (the last of the row is on top) would keep them from it. Given its touches back once the row no longer
// spreads, since Spotify may reuse it for another button (a podcast's).
static void quietHolder(UIView *holder, BOOL quiet) {
    BOOL quieted = objc_getAssociatedObject(holder, &kQuietKey) != nil;
    if (quiet == quieted) return;
    holder.userInteractionEnabled = !quiet;
    objc_setAssociatedObject(holder, &kQuietKey, quiet ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// With both switched on. `arranged` is the row's arranged views, `shuffle` and `repeat` the buttons found in its ends
// this pass, if any.
static void spreadControls(UIView *host, UIStackView *row, NSArray<UIView *> *arranged, UIView *shuffle, UIView *repeat) {
    // Five holders: shuffle's and repeat's at the ends, play's in the middle, previous's and next's either side of it,
    // in either order (a right-to-left layout). The three were found this pass already, for their glyphs.
    UIView *before = nil, *after = nil;
    BOOL apart = NO;
    if (arranged.count == 5 && hiddenSlot(arranged[0], shuffle, &sg_shuffleSlot) && hiddenSlot(arranged[4], repeat, &sg_repeatSlot)) {
        UIView *previous = SGRFindByIdentifier(host, @"SPTNowPlayingPreviousTrackButton", &kPreviousKey);
        UIView *next = SGRFindByIdentifier(host, @"SPTNowPlayingNextTrackButton", &kNextKey);
        UIView *play = SGRFindByIdentifier(host, @"SPTNowPlayingPlayButton", &kPlayKey);
        BOOL inOrder = [previous isDescendantOfView:arranged[1]];
        before = arranged[inOrder ? 1 : 3];
        after = arranged[inOrder ? 3 : 1];
        apart = previous && next && [play isDescendantOfView:arranged[2]] && [previous isDescendantOfView:before] && [next isDescendantOfView:after];
    }
    if (!apart) {
        for (UIView *holder in arranged) {
            if (objc_getAssociatedObject(holder, &kMovedKey)) {
                holder.transform = CGAffineTransformIdentity;
                objc_setAssociatedObject(holder, &kMovedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            quietHolder(holder, NO);
        }
        return;
    }
    UIView *first = arranged[0], *last = arranged[4];
    // Centers and bounds are where the stack put the holders, untouched by their transforms.
    CGFloat start = first.center.x - CGRectGetWidth(first.bounds) / 2, end = last.center.x + CGRectGetWidth(last.bounds) / 2;
    CGFloat middle = arranged[2].center.x, reach = (end - start) / 4;
    // The side previous is on (the right in a right-to-left layout); next goes to the other.
    CGFloat side = before.center.x < middle ? -1 : 1;
    moveHolder(before, row, middle + side * reach);
    moveHolder(after, row, middle - side * reach);
    quietHolder(first, YES);
    quietHolder(last, YES);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: shuffle and repeat hidden, previous and next %.0fpt either side of play", reach); });
}

// Each is looked for only in its own end of the row, so a row without it (a podcast's) costs a walk of one
// element, not the unit.
static void hideShuffleAndRepeat(UIView *host, UIStackView *row) {
    sg_buttonsHost = host;
    NSArray<UIView *> *arranged = row.arrangedSubviews;
    UIView *shuffle = sg_hideShuffle ? SGRFindByIdentifier(arranged.firstObject, kShuffleID, &kShuffleKey) : nil;
    UIView *repeat = sg_hideRepeat ? SGRFindByIdentifier(arranged.lastObject, kRepeatID, &kRepeatKey) : nil;
    suppressButton(shuffle);
    suppressButton(repeat);
    if (sg_hideShuffle && sg_hideRepeat) spreadControls(host, row, arranged, shuffle, repeat);
}

#pragma mark - play

static BOOL spinnerShowing(UIButton *button) {
    for (UIView *sub in button.subviews) {
        if (!sub.hidden && sub.alpha > 0.01 && [NSStringFromClass(sub.class) containsString:@"SpinnerView"]) return YES;
    }
    return NO;
}

static NSString *symbolFor(BOOL paused) {
    return paused ? @"play.fill" : @"pause.fill";
}

static void refreshPlayGlyph(BOOL animated) {
    SGRGlyphView *glyph = sg_playGlyph;
    SPTPlayerState *state = SGPlayerState();
    if (!glyph || !state) return;
    glyph.alpha = spinnerShowing(sg_playButton) ? 0 : 1;
    CFTimeInterval now = CACurrentMediaTime();
    if (now < sg_tappedUntil) {
        if (state.isPaused != sg_tappedPaused) return;
        sg_tappedUntil = 0;
    }
    [glyph setSymbol:symbolFor(state.isPaused) animated:animated];
}

// The player's state reaches the glyph a beat after the tap (the request goes through the player core
// and comes back as a state), which read as a slow button; Spotify's own disc turns at the touch. So the
// glyph turns at the touch too, to the opposite of what it shows, and the state settles it after.
static void playTapped(void) {
    SGRGlyphView *glyph = sg_playGlyph;
    if (!glyph || glyph.alpha == 0) return;
    sg_tappedPaused = ![glyph.symbol isEqualToString:@"play.fill"];
    sg_tappedUntil = CACurrentMediaTime() + kTapTrust;
    [glyph setSymbol:symbolFor(sg_tappedPaused) animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTapTrust * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshPlayGlyph(YES); });
}

void SGRPlayerPlayGlyphIn(UIView *host) {
    // A state that lands after the layout asks this unit to lay out again (the watcher below).
    sg_controlsHost = host;
    UIView *play = SGRFindByIdentifier(host, @"SPTNowPlayingPlayButton", &kPlayKey);
    if (!play) {
        logMissing(@"SPTNowPlayingPlayButton");
        return;
    }
    // Before the player has reported a state the glyph could only guess, so the disc stays.
    SPTPlayerState *state = SGPlayerState();
    if (!state) return;
    UIButton *button = nil;
    for (UIView *sub in play.subviews) {
        if ([sub isKindOfClass:UIButton.class]) button = (UIButton *)sub;
    }
    UIImageView *disc = nil;
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UIImageView.class] && CGSizeEqualToSize(sub.bounds.size, button.bounds.size)) disc = (UIImageView *)sub;
    }
    if (!disc) {
        logMissing(@"the play button's disc");
        return;
    }
    SGRSuppress(disc);
    // The holder Spotify crossfades a snapshot of the disc in when play turns to pause.
    for (UIView *sub in play.subviews) {
        if (object_getClass(sub) != UIView.class) continue;
        for (UIView *image in sub.subviews) {
            if ([image isKindOfClass:UIImageView.class]) SGRSuppress(image);
        }
    }

    // Inside the button, over the disc it replaces, so it follows the button's own press.
    SGRGlyphView *glyph = glyphFor(play, symbolFor(state.isPaused), kPlayGlyphSize);
    keepOnTop(glyph, button);
    sg_playView = play;
    sg_playButton = button;
    sg_playGlyph = glyph;
    refreshPlayGlyph(NO);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: play glyph over %@ (disc %@ suppressed), spinner %@", NSStringFromClass(play.class), NSStringFromClass(disc.class), spinnerShowing(button) ? @"showing" : @"hidden"); });
}

%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host) return;
    // The unit lays out before its row does, and the glyphs are centered on the buttons in it.
    UIStackView *row = (UIStackView *)SGFindRemembered(host, &kRowKey, ^BOOL(UIView *v) { return SGIsRow(v); });
    [row layoutIfNeeded];
    skipGlyph(host, @"SPTNowPlayingPreviousTrackButton", &kPreviousKey, @"backward.fill");
    skipGlyph(host, @"SPTNowPlayingNextTrackButton", &kNextKey, @"forward.fill");
    SGRPlayerPlayGlyphIn(host);
    hideShuffleAndRepeat(host, row);
}
%end

@interface SGRPlayerControlsWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerControlsWatcher

- (void)playerStateDidChange:(SPTPlayerState *)state {
    // The first state can land after the controls laid out, which left the disc for want of one.
    if (!sg_playGlyph) [sg_controlsHost setNeedsLayout];
    refreshPlayGlyph(YES);
    // Spotify raises its spinner a moment after a state says loading, and drops it a moment after.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpinnerCheck * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshPlayGlyph(YES); });
}

@end

static SGRPlayerControlsWatcher *sg_controlsWatcher;

#pragma mark - times

static UILabel *monospaced(UIView *host, NSString *identifier, const void *findKey) {
    UILabel *label = (UILabel *)SGRFindByIdentifier(host, identifier, findKey);
    if (![label isKindOfClass:UILabel.class]) {
        logMissing(identifier);
        return nil;
    }
    SGRMonospacedDigits(label);
    return label;
}

// The action the play button's own UIButton sends (objc-methods.txt: -[PlayButtonView uiButtonTapped]).
// Only the player's button turns the glyph: the sticky header and every page with a play button of
// its own use the same class.
%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)uiButtonTapped {
    %orig;
    if ((UIView *)self != sg_playView) return;
    playTapped();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: play glyph turned at the tap"); });
}
%end

#pragma mark - tap to seek

// Spotify's slider only drags. A tap in the band around it seeks: anywhere across the duration unit's height,
// up to kSeekReach past either end of the bar, moving at most kSeekSlop and lifting within kSeekLongest. A tap
// on the thumb is the thumb's, and a tap on a time is Spotify's, which turns the remaining time into the length.
static const CGFloat kSeekReach = 12, kSeekSlop = 10, kThumbSlop = 6;
static const NSTimeInterval kSeekLongest = 0.5;
// The tap is played to the slider as a short drag, so Spotify's unit seeks the way it does at the end of one.
// Meanwhile the slider says it is still tracking, until the player's position is this near the place tapped or
// for this long at most, so the unit does not put the thumb back to the old place first. A drag that did not
// seek by kSeekCheck is seeked directly.
static const NSInteger kSeekNear = 1500;
static const NSTimeInterval kSeekHold = 2, kSeekCheck = 1;

static char kSliderKey, kSeekTapKey, kTakeTimeKey, kRemainingTimeKey;
static __weak UISlider *sg_seekSlider;
static NSInteger sg_seekTarget;
static CFTimeInterval sg_seekHeldUntil;

static CGFloat thumbCentre(UISlider *slider, float value) {
    CGRect bounds = slider.bounds;
    return CGRectGetMidX([slider thumbRectForBounds:bounds trackRect:[slider trackRectForBounds:bounds] value:value]);
}

// Where along the song a point on the slider is, over the thumb's travel rather than the slider's width, so
// either end of the bar is the song's start or end exactly.
CGFloat SGRSeekShareAt(UISlider *slider, CGPoint point) {
    CGFloat start = thumbCentre(slider, slider.minimumValue), end = thumbCentre(slider, slider.maximumValue);
    if (end - start < 1) return NAN;
    return MIN(1, MAX(0, (point.x - start) / (end - start)));
}

// Whether a tap at `point` in the duration unit's view seeks.
BOOL SGRSeekTapLands(UIView *unit, UISlider *slider, CGPoint point) {
    // The AI DJ's unit keeps a slider in a hidden element on a live stream: nothing to seek there.
    if (!slider.window || !slider.enabled || ![slider isDescendantOfView:unit] || !SGShownUnder(slider, unit) || !CGRectContainsPoint(unit.bounds, point)) return NO;
    CGRect bar = [unit convertRect:slider.bounds fromView:slider];
    if (point.x < CGRectGetMinX(bar) - kSeekReach || point.x > CGRectGetMaxX(bar) + kSeekReach) return NO;
    CGRect bounds = slider.bounds;
    CGRect thumb = [slider thumbRectForBounds:bounds trackRect:[slider trackRectForBounds:bounds] value:slider.value];
    if (CGRectContainsPoint(CGRectInset([unit convertRect:thumb fromView:slider], -kThumbSlop, -kThumbSlop), point)) return NO;
    for (UIView *time in @[SGRFindByIdentifier(unit, @"now-playing-time-take-label", &kTakeTimeKey) ?: NSNull.null,
                           SGRFindByIdentifier(unit, @"now-playing-time-remaning-label", &kRemainingTimeKey) ?: NSNull.null]) {
        if ([time isKindOfClass:UIView.class] && !time.hidden && CGRectContainsPoint([unit convertRect:time.bounds fromView:time], point)) return NO;
    }
    return YES;
}

static BOOL seekHeld(void) {
    if (!sg_seekHeldUntil) return NO;
    NSInteger at = SGKaraokePositionMs();
    if (CACurrentMediaTime() < sg_seekHeldUntil && (at < 0 || labs(at - sg_seekTarget) >= kSeekNear)) return YES;
    sg_seekHeldUntil = 0;
    return NO;
}

// Whether Spotify listens to the slider's control events, which is how a played drag reaches it.
static BOOL listensToSlider(UISlider *slider) {
    __block BOOL listens = NO;
    [slider enumerateEventHandlers:^(UIAction *action, id target, SEL selector, UIControlEvents events, BOOL *stop) {
        if (events & (UIControlEventTouchUpInside | UIControlEventValueChanged)) listens = *stop = YES;
    }];
    return listens;
}

static void seekTo(UISlider *slider, CGFloat share) {
    SPTPlayerState *state = SGPlayerState();
    if (!state || state.duration <= 0 || isnan(share)) return;
    NSInteger ms = (NSInteger)(share * state.duration * 1000);
    SGPlayFeedback(SGFeedbackSkip);
    BOOL played = listensToSlider(slider);
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign player: a tap seeks to %.3f of the song, %@", share, played ? @"played to the slider as a drag" : @"directly (nothing listens to the slider)");
    if (!played) {
        SGKaraokeSeek(ms);
        return;
    }
    [slider setValue:slider.minimumValue + share * (slider.maximumValue - slider.minimumValue) animated:NO];
    sg_seekSlider = slider;
    sg_seekTarget = ms;
    sg_seekHeldUntil = CACurrentMediaTime() + kSeekHold;
    [slider sendActionsForControlEvents:UIControlEventTouchDown];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSeekCheck * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSInteger at = SGKaraokePositionMs();
        if (sg_seekTarget != ms || at < 0 || labs(at - ms) < kSeekNear) return;
        SGLog(@"redesign player: the played drag did not seek (at %ld ms, not %ld), seeking directly", (long)at, (long)ms);
        sg_seekHeldUntil = 0;
        SGKaraokeSeek(ms);
    });
}

// A recognizer of its own rather than a tap: UIKit lets a slider keep a single tap from a tap recognizer
// over it, and the band reaches past the slider.
@interface SGRSeekTap : UIGestureRecognizer
@property (nonatomic, weak) UISlider *slider;
@end

@implementation SGRSeekTap {
    CGPoint _start;
    CFTimeInterval _began;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIView *unit = self.view;
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:unit];
    if (touches.count > 1 || [event touchesForGestureRecognizer:self].count > 1 || !SGRSeekTapLands(unit, self.slider, point)) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _start = point;
    _began = CACurrentMediaTime();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint point = [touches.anyObject locationInView:self.view];
    if (hypot(point.x - _start.x, point.y - _start.y) > kSeekSlop) self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL tap = CACurrentMediaTime() - _began <= kSeekLongest;
    self.state = tap ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.state = UIGestureRecognizerStateFailed;
}

- (void)sgr_seek {
    UISlider *slider = self.slider;
    if (slider) seekTo(slider, SGRSeekShareAt(slider, [self.view convertPoint:_start toView:slider]));
}
@end

static void watchSlider(UIView *host) {
    UISlider *slider = (UISlider *)SGRFindByIdentifier(host, @"SPTNowPlayingSliderV2", &kSliderKey);
    if (![slider isKindOfClass:UISlider.class]) return;
    SGRSeekTap *tap = objc_getAssociatedObject(host, &kSeekTapKey);
    if (!tap) {
        tap = [[SGRSeekTap alloc] initWithTarget:nil action:nil];
        [tap addTarget:tap action:@selector(sgr_seek)];
        [host addGestureRecognizer:tap];
        objc_setAssociatedObject(host, &kSeekTapKey, tap, OBJC_ASSOCIATION_ASSIGN);
        SGLog(@"redesign player: a tap around the progress bar seeks");
    }
    tap.slider = slider;
}

%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (BOOL)isTracking {
    return ((UISlider *)self == sg_seekSlider && seekHeld()) || %orig;
}
%end

// The ordinary player's duration unit and the AI DJ's (DJMDurationElementsUnit) hold the same progress bar and times.
static void durationLaidOut(UIViewController *unit) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    watchSlider(host);
    UILabel *taken = monospaced(host, @"now-playing-time-take-label-internal", &kTakeKey);
    monospaced(host, @"now-playing-time-remaning-label-internal", &kRemainingKey);
    // Whether Spotify's font has digits of one width shows in the descriptor's feature settings.
    if (!taken) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: monospaced times in %@ %.0fpt, features %@", taken.font.fontName, taken.font.pointSize, taken.font.fontDescriptor.fontAttributes[UIFontDescriptorFeatureSettingsAttribute]); });
}

%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationLaidOut((UIViewController *)self);
}
%end

// The DJ unit is another class, hooked only when the build has it (see %ctor).
%group SGRDJControlsDurationHooks
%hook SGRDJControlsDurationUnit
- (void)viewDidLayoutSubviews {
    %orig;
    durationLaidOut((UIViewController *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_hideShuffle = SGHidden(SGRKeyPlayerHideShuffle);
    sg_hideRepeat = SGHidden(SGRKeyPlayerHideRepeat);
    Class djDuration = SGRDJClass(@"DJMDurationElementsUnit");
    if (djDuration) { %init(SGRDJControlsDurationHooks, SGRDJControlsDurationUnit = djDuration); }
    sg_controlsWatcher = [SGRPlayerControlsWatcher new];
    SGAddPlayerStateObserver(sg_controlsWatcher);
    SGRequireClasses(@[
        @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        @"_TtC20NowPlaying_ModesImpl19DurationElementUnit",
        @"_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView",
        @"SPTEncoreIconView",
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider",
    ]);
}
