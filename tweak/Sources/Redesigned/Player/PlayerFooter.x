// Player redesign: the footer as the Music app's row of three glyphs, lyrics, devices and queue, spread
// evenly across the player, and no share button.
//
// Spotify's footer is Connect with the device's name at the leading edge, share, and the queue at the
// trailing edge. Connect and the queue stay Spotify's controls (the device sheet, the remote device
// tint, the Jam avatars) and are only moved, by a translation of the arranged view that holds each: a
// transform survives the stack view laying them out again, and moving the holder keeps its touches
// inside its own bounds. The device name goes transparent, since the glyph alone sits in the middle, and
// Connect's holder takes touches only in a square over the glyph (SGRPlayerCoverConnect).
// Both draw the Music app's glyphs, AirPlay audio and a bulleted list (issue #109): a stand-in inside each of
// Spotify's glyph views, so it is hidden, faded and pulsed with Spotify's own, while Spotify's drawing goes
// clear at its source. Connect's glyph is an image Spotify draws the color into: each new one is read once for
// that color, so a device in use still lights it in the accent (or the cover's, PlayerCoverAccent.x), and is
// swapped for a clear image of its size. The queue's is an SPTEncoreIconView: its foreground colors are kept
// for the stand-in and Spotify's drawn clear.
// Spotify has no lyrics control down here, so that one is the Kit's glyph button, and it turns the
// lyrics in the player on and off (PlayerLyrics.x): filled while they are up, dimmed and dead for a
// track that has none.
// Spotify's icons (SGRKeyPlayerSpotifyIcons) leaves Connect's and the queue's glyphs Spotify's, and draws the Lyrics
// glyph as Spotify's Encore "lyrics", lit in the primary color while the lyrics are up.
//
// The row sits lower than Spotify puts it, just over the home indicator the way the Music app's does
// (issue #54): the footer unit's view is translated down, the controls follow it part of the way, and a
// band of the redesign's hands the touches below the bottom stack's bounds back to the row.
//
// Tree (trees/clean/player/01.txt:295-320): FooterElementsUnit's view 402x44 > UIStackView 382x44 >
// ElementView > ConnectButtonOutputSwitcherViewHolder id=Components.ConnectButtonOutputSwitcher 153x36
// (a 19x19 UIImageView glyph and a MarqueeLabel with the device name), a spacer, a hidden media trimmer,
// ElementView > EncoreButton id=ShareButtonNowPlayingView 44x44, ElementView > Queue control
// id=QueueButtonNowPlaying 47x32 (an 18x18 SPTEncoreIconView id=Encore.IconView glyph, out/rep/ptree.txt:1228-1279).
#import <substrate.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTEncoreIconView.h"
#import "Player.h"
#import <objc/message.h>

static const CGFloat kLyricsGlyphSize = 20;
// Filled and at full strength while the lyrics are up, the way the Music app marks the control that is on.
static NSString *const kLyricsSymbol = @"quote.bubble", *const kLyricsSymbolOpen = @"quote.bubble.fill";
// Where the three glyphs sit, as parts of the footer's width.
static const CGFloat kLeading = 0.2, kMiddle = 0.5, kTrailing = 0.8;
static const CGFloat kGlyphMaxWidth = 30;

// Issue #54: Spotify ends its bottom stack 61pt above the screen's bottom (01.txt:127, 576.67 + 236 of
// 874), so the row's middle sat 83pt up, well clear of the home indicator, and the controls crowded it.
// The Music app keeps that row just over the home indicator: its middle this far above the safe area's
// bottom, and never less than kRowMinBottom above the screen's on a phone without a home indicator.
static const CGFloat kRowAboveSafeArea = 20, kRowMinBottom = 34;
// The controls follow a share of the row's move when nothing stands between them, so the gaps above
// and below them even out instead of all the room opening under them.
static const CGFloat kControlsShare = 0.3;
// The volume row's sides, the player's own margin.
static const CGFloat kVolumeMargin = 24;
// And the controls go up this much over it, so the gaps above and below the volume row match.
static const CGFloat kVolumeLift = 10;

// "airplayaudio" is the name iOS 16 knows; iOS 18 calls it airplay.audio and keeps this one as its alias.
static NSString *const kConnectSymbol = @"airplayaudio", *const kQueueSymbol = @"list.bullet";

static char kEncoreKey;
static char kConnectKey, kShareKey, kTrimmerKey, kSharedByKey, kQueueKey, kQueueIconKey, kLyricsGlyphKey, kReachKey, kRowKey;
static __weak SGRGlyphButton *sg_lyricsGlyph;

// The view the footer's stack view arranges around `view`.
static UIView *arrangedAround(UIView *view, UIView *host) {
    for (UIView *v = view; v && v != host; v = v.superview) {
        if ([v.superview isKindOfClass:UIStackView.class]) return v;
    }
    return nil;
}

// Where `point` of `view` is in the host with the arranged view's own transform left out.
static CGFloat untransformedX(UIView *arranged, UIView *view, CGPoint point, UIView *host) {
    CGPoint local = [view convertPoint:point toView:arranged];
    CGPoint inRow = CGPointMake(arranged.center.x + local.x - CGRectGetMidX(arranged.bounds), arranged.center.y);
    return [arranged.superview convertPoint:inRow toView:host].x;
}

static CGFloat moveTo(UIView *arranged, UIView *view, CGPoint point, UIView *host, CGFloat x) {
    if (!arranged) return -1;
    CGFloat from = untransformedX(arranged, view, point, host);
    CGAffineTransform transform = CGAffineTransformMakeTranslation(round(x - from), 0);
    if (!CGAffineTransformEqualToTransform(arranged.transform, transform)) arranged.transform = transform;
    return from;
}

#pragma mark - Spotify's icons

BOOL SGRPlayerSpotifyIcons(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGRKeyPlayerSpotifyIcons); });
    return on;
}

UIView *SGRPlayerEncoreGlyphIn(SGRGlyphButton *button, NSString *name) {
    if (!button) return nil;
    SPTEncoreIconView *encore = objc_getAssociatedObject(button, &kEncoreKey);
    if (!encore) {
        Class icons = NSClassFromString(@"SPTEncoreIcon"), view = NSClassFromString(@"SPTEncoreIconView");
        SEL glyphSel = NSSelectorFromString(name);
        if (!icons || !view || ![icons respondsToSelector:glyphSel]) {
            SGLog(@"redesign player: no Encore glyph %@, the Music app's stays", name);
            return nil;
        }
        id glyph = ((id (*)(id, SEL))objc_msgSend)(icons, glyphSel);
        encore = glyph ? [[view alloc] initWithIcon:glyph] : nil;
        if (!encore) return nil;
        encore.userInteractionEnabled = NO;
        encore.isAccessibilityElement = NO;
        CGSize size = encore.intrinsicContentSize;
        encore.bounds = CGRectMake(0, 0, size.width > 0 ? size.width : 24, size.height > 0 ? size.height : 24);
        encore.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                                | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        encore.foregroundColor = button.glyph.tintColor ?: SGRPrimary();
        objc_setAssociatedObject(button, &kEncoreKey, encore, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Hidden rather than clear: the button puts its glyph's alpha back as it is pressed.
    button.glyph.hidden = YES;
    if (encore.superview != button) [button addSubview:encore];
    encore.center = CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
    return encore;
}

#pragma mark - lyrics

void SGRPlayerLyricsChanged(void) {
    SGRPlayerMotionLyricsChanged();
    SGRPlayerVisualiserUpdate();
    SGRGlyphButton *glyph = sg_lyricsGlyph;
    if (!glyph) return;
    BOOL enabled = SGRPlayerLyricsAvailable() || SGRPlayerLyricsOpen(), open = SGRPlayerLyricsOpen();
    BOOL wasOpen = [glyph.glyph.symbol isEqualToString:kLyricsSymbolOpen];
    if (glyph.enabled == enabled && wasOpen == open) return;
    // Lyrics turn up once the player has fetched them, well after the footer laid out: a fade, not a pop.
    // While the player opens or closes the glyph and the lyrics come and go together, so nothing animates.
    BOOL animated = glyph.window && !SGRPlayerIsTransitioning();
    [glyph.glyph setSymbol:open ? kLyricsSymbolOpen : kLyricsSymbol animated:animated];
    void (^mark)(void) = ^{
        glyph.enabled = enabled;
        glyph.glyph.tintColor = open ? SGRPrimary() : SGRSecondary();
        ((SPTEncoreIconView *)objc_getAssociatedObject(glyph, &kEncoreKey)).foregroundColor = glyph.glyph.tintColor;
    };
    if (animated) SGRAnimate(SGRMotionFade, mark, nil);
    else mark();
}

SGRGlyphButton *SGRPlayerLyricsGlyphIn(UIView *host) {
    SGRGlyphButton *glyph = objc_getAssociatedObject(host, &kLyricsGlyphKey);
    if (!glyph) {
        glyph = [SGRGlyphButton buttonWithSymbol:kLyricsSymbol pointSize:kLyricsGlyphSize title:@"Lyrics"];
        glyph.glyph.tintColor = SGRSecondary();
        glyph.onTap = ^{ SGRPlayerToggleLyrics(); };
        objc_setAssociatedObject(host, &kLyricsGlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != host) [host addSubview:glyph];
    if (SGRPlayerSpotifyIcons()) SGRPlayerEncoreGlyphIn(glyph, @"lyrics");
    sg_lyricsGlyph = glyph;
    return glyph;
}

#pragma mark - the Music app's glyphs

static char kStandInKey, kClearKey, kQueueActiveColorKey;

// The Kit's glyph centered inside `drawn`: it takes `drawn`'s hidden, alpha and animations with it.
static SGRGlyphView *standIn(UIView *drawn, NSString *symbol) {
    if (!drawn) return nil;
    SGRGlyphView *glyph = objc_getAssociatedObject(drawn, &kStandInKey);
    if (!glyph) {
        glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:kLyricsGlyphSize weight:UIImageSymbolWeightRegular];
        glyph.userInteractionEnabled = NO;
        glyph.isAccessibilityElement = NO;
        glyph.tintColor = SGRSecondary();   // at rest, as the Lyrics glyph while it is off
        // Kept centered when Spotify resizes the view between the footer's passes (a new Connect image of another size).
        glyph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(drawn, &kStandInKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != drawn) [drawn addSubview:glyph];
    CGPoint middle = CGPointMake(CGRectGetMidX(drawn.bounds), CGRectGetMidY(drawn.bounds));
    if (!CGPointEqualToPoint(glyph.center, middle)) glyph.center = middle;
    return glyph;
}

// The color Spotify drew its glyph in (SGRPlayerImageInk, kept on the image, so an image Spotify hands over again costs
// a lookup). One drawn from the tint answers the tint.
static UIColor *inkOf(UIImageView *view, UIImage *image) {
    if (image.isSymbolImage || image.renderingMode == UIImageRenderingModeAlwaysTemplate) return view.tintColor;
    return SGRPlayerImageInk(image) ?: SGRPrimary();
}

// A lit glyph as a bitmap in its color, the way Spotify draws its own: Follow the cover finds lit controls by their
// pixels, and a symbol image has none to read. The symbol's alignment insets are kept, so it sits where it did.
// Drawn in the glyph's traits (Bold Text, contrast), as its template image is.
static UIImage *litImage(SGRGlyphView *glyph, UIImage *symbol, UIColor *color) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:glyph.traitCollection];
    format.scale = symbol.scale;
    UIImage *tinted = [symbol imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    __block UIImage *bitmap;
    [glyph.traitCollection performAsCurrentTraitCollection:^{
        bitmap = [[[UIGraphicsImageRenderer alloc] initWithSize:symbol.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [tinted drawAtPoint:CGPointZero];
        }];
    }];
    return [bitmap imageWithAlignmentRectInsets:symbol.alignmentRectInsets];
}

// Spotify's new Connect glyph: its color onto the stand-in, drawn into the stand-in's image so Follow the cover
// repaints it the way it did Spotify's, and a clear image of the same size in its place, so nothing moves.
static void takeConnectImage(UIImageView *drawn) {
    UIImage *image = drawn.image;
    UIImage *clear = objc_getAssociatedObject(drawn, &kClearKey);
    if (!image.CGImage || image == clear) return;
    SGRGlyphView *glyph = objc_getAssociatedObject(drawn, &kStandInKey);
    UIImage *symbol = [UIImage systemImageNamed:glyph.symbol withConfiguration:glyph.preferredSymbolConfiguration];
    UIColor *ink = inkOf(drawn, image);
    BOOL lit = SGRPlayerAccentLike(ink);
    glyph.image = lit ? litImage(glyph, symbol, ink) : symbol;
    // Spotify hands the new image over with no layout pass, so Follow the cover is told here, or a lit glyph keeps the accent.
    if (lit) SGRPlayerPaintCover(glyph);
    if (!clear || !CGSizeEqualToSize(clear.size, image.size) || clear.scale != image.scale) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = image.scale;
        clear = [[[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
        objc_setAssociatedObject(drawn, &kClearKey, clear, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    drawn.image = clear;
}

// Spotify draws a new glyph when the device changes, with no layout pass of the footer to tell it, so its setImage:
// tells the stand-in; the clear image set back in reports too, and stops there. Each pass looks too, at the cost of a
// compare, for a view the image cannot be watched on.
static void standInForConnect(UIImageView *drawn) {
    if (SGRPlayerSpotifyIcons()) return;
    BOOL made = objc_getAssociatedObject(drawn, &kStandInKey) != nil;
    if (!standIn(drawn, kConnectSymbol)) return;
    takeConnectImage(drawn);
    if (!made) SGRObserveImage(drawn, ^(UIImageView *view) { takeConnectImage(view); });
}

// The queue's state as Spotify sets it, for the stand-in; Spotify's own glyph is drawn in clear.
static void tintQueueStandIn(SPTEncoreIconView *icon) {
    SGRGlyphView *glyph = objc_getAssociatedObject(icon, &kStandInKey);
    // Lit by Spotify's own state, not by a color a cover could make look gray. Lit, it is drawn in the color, as Connect
    // is, so Follow the cover finds it by its pixels and repaints it.
    UIColor *active = objc_getAssociatedObject(icon, &kQueueActiveColorKey);
    UIImage *symbol = [UIImage systemImageNamed:glyph.symbol withConfiguration:glyph.preferredSymbolConfiguration];
    BOOL lit = icon.isActive && active;
    glyph.image = lit ? litImage(glyph, symbol, active) : symbol;
    if (lit) SGRPlayerPaintCover(glyph);
}

static void standInForQueue(SPTEncoreIconView *icon) {
    if (SGRPlayerSpotifyIcons()) return;
    if (![icon isKindOfClass:%c(SPTEncoreIconView)]) return;
    BOOL made = objc_getAssociatedObject(icon, &kStandInKey) != nil;
    if (!standIn(icon, kQueueSymbol) || made) return;
    UIColor *color = icon.foregroundColor, *active = icon.activeForegroundColor;
    // Through the setters below, which now keep each color and hand Spotify's drawing clear.
    if (color) icon.foregroundColor = color;
    if (active) icon.activeForegroundColor = active;
    tintQueueStandIn(icon);
}

%hook SPTEncoreIconView
// The stand-in does not take the color at rest, only the active one.
- (void)setForegroundColor:(UIColor *)color {
    %orig(objc_getAssociatedObject(self, &kStandInKey) ? UIColor.clearColor : color);
}
- (void)setActiveForegroundColor:(UIColor *)color {
    BOOL ours = objc_getAssociatedObject(self, &kStandInKey) != nil;
    if (ours) objc_setAssociatedObject(self, &kQueueActiveColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(ours ? UIColor.clearColor : color);
    if (ours) tintQueueStandIn(self);
}
- (void)setIsActive:(BOOL)active {
    %orig;
    if (objc_getAssociatedObject(self, &kStandInKey)) tintQueueStandIn(self);
}
%end

#pragma mark - the row

static UIView *connectGlyphIn(UIView *holder) {
    __block UIView *glyph = nil;
    SGForEachView(holder, ^(UIView *view) {
        if (!glyph && [view isKindOfClass:UIImageView.class] && ![view isKindOfClass:SGRGlyphView.class]
            && view.bounds.size.width > 0 && view.bounds.size.width <= kGlyphMaxWidth) glyph = view;
    });
    return glyph;
}

// Connect is Spotify's control as wide as the device's name, with the glyph near its leading edge. With the
// name hidden and the glyph in the middle, its touches would reach far past the glyph, over the queue, and
// hardly before it. So the row's view that holds it takes touches only in a square over the glyph, the size
// of the row's other two; Spotify's own views inside still handle them. The square is kept on that view, and
// its class answers from it, as it does for every other view of the class.
static char kConnectHitKey;
static NSMutableDictionary<NSString *, NSValue *> *sg_origPointInside;   // class name -> original IMP

static BOOL connectPointInside(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    NSValue *square = objc_getAssociatedObject(self, &kConnectHitKey);
    if (square) return CGRectContainsPoint(square.CGRectValue, point);
    // The nearest hooked class up the chain holds the original this view would have run.
    for (Class cls = self.class; cls; cls = class_getSuperclass(cls)) {
        NSValue *orig = sg_origPointInside[NSStringFromClass(cls)];
        // A subclass hooked after its parent got the parent's hook as its original; that one is skipped.
        if (orig && orig.pointerValue != (void *)connectPointInside)
            return ((BOOL (*)(UIView *, SEL, CGPoint, UIEvent *))orig.pointerValue)(self, _cmd, point, event);
    }
    return NO;
}

void SGRPlayerCoverConnect(UIView *arranged, UIView *glyph) {
    if (!arranged || !glyph) return;
    // The ordinary footer and the DJ's can hand over views of different classes; each class is hooked once.
    if (!sg_origPointInside) sg_origPointInside = [NSMutableDictionary new];
    NSString *name = NSStringFromClass(arranged.class);
    if (!sg_origPointInside[name]) {
        IMP orig = NULL;
        MSHookMessageEx(arranged.class, @selector(pointInside:withEvent:), (IMP)connectPointInside, &orig);
        sg_origPointInside[name] = [NSValue valueWithPointer:(void *)orig];
    }
    CGRect drawn = [glyph convertRect:glyph.bounds toView:arranged];
    CGRect square = CGRectMake(CGRectGetMidX(drawn) - 22, CGRectGetMidY(drawn) - 22, 44, 44);
    objc_setAssociatedObject(arranged, &kConnectHitKey, [NSValue valueWithCGRect:square], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Connect's glyph, ready to be moved: Connect laid out first, since the glyph is unsized until it is (the first time the
// player opens), and its device name hidden. The name is a MarqueeLabel on the phone's speaker and a plain Encore label
// on AirPods; Connect holds nothing else that draws text. With no glyph yet the caller leaves Connect where Spotify put
// it, and `host` looks again on the next turn of the run loop.
UIView *SGRPlayerConnectGlyphIn(UIView *host, UIView *connect) {
    [connect layoutIfNeeded];
    UIView *glyph = connectGlyphIn(connect);
    static NSUInteger lookedAgain;   // a Connect with no glyph at all is left alone after this many
    if (glyph) lookedAgain = 0;
    if (connect && !glyph && lookedAgain++ < 20) {
        __weak UIView *weakHost = host;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakHost setNeedsLayout]; });
    }
    SGForEachView(connect, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] || SGClassNamed(view.class, @"MarqueeLabel")) SGRPlayerVanish(view);
    });
    if (glyph) standInForConnect((UIImageView *)glyph);
    return glyph;
}

#pragma mark - lower down

// Moved down, the row is drawn partly below the bottom stack it is arranged in, and UIKit does not look
// into a view for a touch outside its bounds. This band over the part that hangs out hands such a touch
// to the row itself, and lets every other one through.
@interface SGRFooterReach : UIView
@property (nonatomic, weak) UIView *row;
@end

@implementation SGRFooterReach
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *row = self.row;
    if (!row.window || row.alpha < 0.01 || row.hidden) return nil;
    UIView *hit = [row hitTest:[row convertPoint:point fromView:self] withEvent:event];
    return hit == row ? nil : hit;
}
@end

static UIViewController *unitOf(UIView *view) {
    UIResponder *next = view.nextResponder;
    return [next isKindOfClass:UIViewController.class] && ((UIViewController *)next).viewIfLoaded == view ? (UIViewController *)next : nil;
}

// The arranged view drawn right above `row` in its stack, by where the stack put them.
static UIView *rowAbove(UIView *row) {
    UIView *best = nil;
    CGFloat top = row.center.y - row.bounds.size.height / 2, bestBottom = -CGFLOAT_MAX;
    // The volume row lives in the same stack, between the controls and the footer: it is not what is above, or the
    // controls would be taken for something else whenever it ends within a point of the footer (the AI DJ's gap does).
    static Class volumeRow;
    if (!volumeRow) volumeRow = NSClassFromString(@"SGRVolumeRow");
    for (UIView *sibling in row.superview.subviews) {
        if (sibling == row || sibling.hidden || sibling.alpha < 0.01 || sibling.bounds.size.height < 1) continue;
        if (volumeRow && [sibling isKindOfClass:volumeRow]) continue;
        CGFloat bottom = sibling.center.y + sibling.bounds.size.height / 2;
        if (bottom <= top + 1 && bottom > bestBottom) {
            best = sibling;
            bestBottom = bottom;
        }
    }
    return best;
}

void SGRPlayerLowerRow(UIView *row) {
    UIView *stack = row.superview, *player = stack.superview;
    UIWindow *window = row.window;
    if (![stack isKindOfClass:UIStackView.class] || !player || !window) return;
    // Where the stack put the row, the row's own transform left out, and where it belongs.
    CGFloat middle = [stack convertPoint:row.center toView:player].y;
    CGFloat height = player.bounds.size.height;
    CGFloat target = height - MAX(window.safeAreaInsets.bottom + kRowAboveSafeArea, kRowMinBottom);
    CGFloat move = MAX(0, round(target - middle));
    CGAffineTransform down = CGAffineTransformMakeTranslation(0, move);
    if (!CGAffineTransformEqualToTransform(row.transform, down)) row.transform = down;

    // Only the controls, and only straight above: a volume row between them keeps its place and theirs.
    UIView *above = rowAbove(row);
    // The ordinary player's controls unit, or the AI DJ's head unit (DJPlayer.x), which holds the same buttons.
    Class unit = unitOf(above).class;
    BOOL controls = SGClassNamed(unit, @"PlaybackControlsElementsUnit") || SGClassNamed(unit, @"DJMHeadUnitViewController");
    // With the volume row, the controls stay where Spotify put them and the row takes the room the footer leaves.
    // The volume row is placed against the controls where they would stand for it; one that does not show leaves them
    // following the footer as they do without it.
    BOOL volume = SGRPlayerVolumeOn() && controls;
    CGFloat share = volume ? 0 : kControlsShare, lift = volume ? kVolumeLift : 0;
    CGAffineTransform follow = CGAffineTransformMakeTranslation(0, controls ? round(move * share) - lift : 0);
    if (above && controls && !CGAffineTransformEqualToTransform(above.transform, follow)) above.transform = follow;
    SGRPlayerPaintCover(stack);
    if (volume && !SGRPlayerPlaceVolume(stack, above, row, kVolumeMargin)) {
        share = kControlsShare;
        follow = CGAffineTransformMakeTranslation(0, round(move * share));
        if (!CGAffineTransformEqualToTransform(above.transform, follow)) above.transform = follow;
    } else if (!volume) {
        SGRPlayerPlaceVolume(stack, nil, row, kVolumeMargin);
    }

    SGRFooterReach *reach = objc_getAssociatedObject(row, &kReachKey);
    if (!reach) {
        reach = [SGRFooterReach new];
        reach.row = row;
        objc_setAssociatedObject(row, &kReachKey, reach, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (reach.superview != player) [player addSubview:reach];
    CGRect stackFrame = [stack convertRect:stack.bounds toView:player];
    CGRect drawn = [row convertRect:row.bounds toView:player];
    CGFloat from = CGRectGetMaxY(stackFrame);
    CGRect band = CGRectMake(CGRectGetMinX(drawn), from, drawn.size.width, MAX(0, CGRectGetMaxY(drawn) - from));
    if (!CGRectEqualToRect(reach.frame, band)) reach.frame = band;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer row from %.0f to %.0f of %.0f (safe area %.0f), controls %@ %.0f, volume %@", middle, middle + move, height,
              window.safeAreaInsets.bottom, controls ? @"follow" : @"stay", controls ? round(move * share) : 0, SGRPlayerVolumeOn() ? @"on" : @"off");
    });
}

%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host) return;
    // The unit lays out before its row does, and the moves are measured from where the row put things.
    [SGFindRemembered(host, &kRowKey, ^BOOL(UIView *v) { return SGIsRow(v); }) layoutIfNeeded];
    CGFloat width = host.bounds.size.width, middleY = CGRectGetMidY(host.bounds);
    BOOL rtl = host.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;

    // Share; Spotify's clip button, hidden in every clean tree, which would turn up where the queue moves to; and
    // "From <friend>" on a track a friend shared, which sits in the middle of the row, over Connect, which the row
    // moves there (the Music app has no such chip). Found in one walk: nothing between them touches the tree.
    static const void *const goneKeys[] = {&kShareKey, &kTrimmerKey, &kSharedByKey};
    UIView *gone[3];
    static NSArray<NSString *> *goneIdentifiers;
    if (!goneIdentifiers) goneIdentifiers = @[@"ShareButtonNowPlayingView", @"nowplaying-npv-media-trimmer-navigation-button", @"Components.UI.SharedByChip"];
    SGRFindByIdentifiers(host, goneIdentifiers, goneKeys, gone);
    UIView *share = gone[0];
    for (NSUInteger i = 0; i < 3; i++) {
        SGRPlayerVanish(gone[i]);
        // The arranged view goes too: a view that takes touches swallows them even with nothing on it.
        SGRPlayerVanish(arrangedAround(gone[i], host));
    }

    SGRGlyphButton *lyrics = SGRPlayerLyricsGlyphIn(host);
    lyrics.bounds = CGRectMake(0, 0, 44, 44);
    lyrics.center = CGPointMake(round(width * (rtl ? kTrailing : kLeading)), middleY);
    SGRPlayerLyricsChanged();

    UIView *connect = SGRFindByIdentifier(host, @"Components.ConnectButtonOutputSwitcher", &kConnectKey);
    UIView *glyph = SGRPlayerConnectGlyphIn(host, connect);
    CGFloat connectFrom = glyph ? moveTo(arrangedAround(connect, host), glyph, CGPointMake(CGRectGetMidX(glyph.bounds), CGRectGetMidY(glyph.bounds)), host, round(width * kMiddle)) : -1;

    UIView *queue = SGRFindByIdentifier(host, @"QueueButtonNowPlaying", &kQueueKey);
    standInForQueue((SPTEncoreIconView *)SGRFindByIdentifier(queue, @"Encore.IconView", &kQueueIconKey));
    CGFloat queueFrom = moveTo(arrangedAround(queue, host), queue, CGPointMake(CGRectGetMidX(queue.bounds), CGRectGetMidY(queue.bounds)), host, round(width * (rtl ? kLeading : kTrailing)));

    SGRPlayerLowerRow(host);
    SGRPlayerCoverConnect(arrangedAround(connect, host), glyph);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign player: footer lyrics at %.0f, connect %.0f (%@) to %.0f, queue %.0f to %.0f, share %@", lyrics.center.x,
              connectFrom, glyph ? @"glyph" : @"button", round(width * kMiddle), queueFrom, round(width * (rtl ? kLeading : kTrailing)), share ? @"gone" : @"not found");
    });
}
%end

// The Connect button lays itself out again when the device changes (its name comes or goes, another device's glyph,
// the button's width with them),
// with no pass of the footer around it: the glyph moved inside it while the footer's transform, worked out from where
// the glyph was, stayed, so Connect slid off its place (the phone, 2026-10-24: switched to another device from
// elsewhere, the DJ footer's Connect 11pt left of its slot). The footer is laid out again whenever the glyph moves, and
// its pass puts the button back on its place, the ordinary player's and the DJ's alike.
static char kGlyphSeenKey;

%hook _TtC23Connect_EntryPointsImpl37ConnectButtonOutputSwitcherViewHolder
- (void)layoutSubviews {
    %orig;
    UIView *connect = (UIView *)self;
    UIView *glyph = connectGlyphIn(connect);
    if (!glyph) return;
    // The glyph's place in the button and the button's size: the glyph keeps its place at the button's leading edge while
    // the button grows and shrinks with the device's name (101.5pt with "iPhone", 51 without, the phone, 2026-10-24), and
    // the element holding it is laid out again round its new size, so either one moving is a move of the glyph.
    CGRect seen = [glyph convertRect:glyph.bounds toView:connect];
    seen.size = connect.bounds.size;
    NSValue *was = objc_getAssociatedObject(connect, &kGlyphSeenKey);
    if (was && CGRectEqualToRect(was.CGRectValue, seen)) return;
    objc_setAssociatedObject(connect, &kGlyphSeenKey, [NSValue valueWithCGRect:seen], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!was) return;
    // The footer unit's view: the first ancestor a controller owns.
    for (UIView *v = connect.superview; v; v = v.superview) {
        if (!unitOf(v)) continue;
        [v setNeedsLayout];
        break;
    }
}
%end

%group VolumeSlider
%hook UISlider
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    SGRPlayerVolumeSliderSet(self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (SGRPlayerVolumeOn()) %init(VolumeSlider);
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18FooterElementsUnit", @"SPTEncoreIconView"]);
}
