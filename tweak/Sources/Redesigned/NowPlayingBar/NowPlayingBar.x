// The redesign's now playing bar: the album-colored card becomes a glass card with round artwork and the
// progress line under the text. Spotify's own labels, buttons and gestures stay in place.
//
// The full screen player morphs the bar's own card and artwork into the cover art. The bar was
// written to hand itself back to Spotify for that animation, from NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning, but Spotify 9.1.78 never runs the player through those,
// so the handback never happened and is gone; if the morph ever reads as a cut, the place to start is
// Shared/Player/PlayerEvents.h, which does fire. What does move with the player is a stand-in of the
// bar, which BarTransition.x keeps glass behind.
//
// Tree (trees/home.txt): NowPlayingBarContainerViewController.view 402x56 > NowPlayingBarViewController.view
//   at {8,0} 386x56 > UIView 386x56 (the painted card) > artwork 40x40 r=4, title stack,
//   progress line 370x2 at the bottom. The glass pane goes on the container's view.
//
// In a Jam Spotify puts a "Jam by ..." strip on the bar, a SwiftUI _UIHostingView of
// Jam_AttachmentsImpl.JamHatElement as wide as the card and 44pt high, and grows the bar by its height
// (386x100, the track card at y = 44). It paints the strip, or a view around the strip and the track, as
// well, so the card is the painted view that holds the track and has no strip in it. The strip stays out
// of the card's glass and gets a pane of its own above it, since its own paint goes clear with the rest.
// The strip's class is modelled, not recorded: no tree has a Jam in it yet. The 9.1.90 binary has the Jam's
// hat under Jam_AttachmentsImpl.HatRootViewController, so the strip is also known by its controller.
// In the minimized tab bar's row the card docks as it does outside a Jam, and the strip rides above it at
// its width, on its own pane.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Settings/SGMarquee.h"
#import "NowPlayingBar.h"
#import "Redesigned/Navbar/Navbar.h"

static const CGFloat kCardRadius = 24;
// The strip's pane is this much smaller than the strip at each end, so a gap parts it from the card's glass.
static const CGFloat kStripInset = 4;
static char kGlassKey, kStripGlassKey;
static __weak UIView *sg_card;
static CGRect sg_stripFrame;
// The track's glass frame in the container's view as the bar was last styled, the strip cut off: the row
// takes the card's height and middle from it, never the bar's, which in a Jam has the strip on top.
static CGRect sg_trackFrame = {{INFINITY, INFINITY}, {0, 0}};
static __weak UIVisualEffectView *sg_cardGlass;
static __weak UIView *sg_cardArtwork;
static __weak UIView *sg_progress;
static __weak UIViewController *sg_container;
// The container's view while it stands in the minimized tab bar's row, below the page that holds it.
static __weak UIView *sg_inline;

CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius) {
    UIVisualEffectView *glass = sg_cardGlass;
    if (!glass.superview || !glass.window || !host) return CGRectNull;
    if (radius) *radius = MIN(kCardRadius, glass.bounds.size.height / 2);
    return [host convertRect:glass.bounds fromView:glass];
}

CGFloat SGRNowPlayingStripHeight(void) {
    return sg_stripFrame.size.height;
}

CGRect SGRNowPlayingArtworkFrameIn(UIView *host) {
    UIView *artwork = sg_cardArtwork;
    if (!artwork.window || !host) return CGRectNull;
    return [host convertRect:artwork.bounds fromView:artwork];
}

// The Jam strip, by its class or by its controller's (Jam_AttachmentsImpl.HatRootViewController, whose view
// can be any hosting view). Only the Jam's: the bar's other hats (ads, sponsors) keep the card out of the row.
// The height keeps out a view of the same module that can hold the track card too.
static BOOL isStrip(UIView *view) {
    if (view.bounds.size.height > 60) return NO;
    if (SGClassNamed(view.class, @"AttachmentsImpl") && SGClassNamed(view.class, @"Hat")) return YES;
    UIResponder *next = view.nextResponder;
    if (![next isKindOfClass:UIViewController.class]) return NO;
    return SGClassNamed(next.class, @"Jam") && SGClassNamed(next.class, @"Hat");
}

static BOOL inStrip(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) if (isStrip(v)) return YES;
    return NO;
}

static UIView *stripIn(UIView *root) {
    __block UIView *strip = nil;
    SGForEachView(root, ^(UIView *v) { if (!strip && isStrip(v)) strip = v; });
    return strip;
}

// What holds the track on the bar: the title and artist block, else the artwork (a 36 to 48pt square that
// is not a button), never anything in the strip. Nil when neither is there.
static UIView *trackMarker(UIView *bar) {
    __block UIView *info = nil, *artwork = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (info || inStrip(v, bar)) return;
        if (SGClassNamed(v.class, @"InformationContainer")) info = v;
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!artwork && square && ![v isKindOfClass:UIControl.class]) artwork = v;
    });
    return info ?: artwork;
}

// A card holds the track and has no strip in it; one with the strip in it only when there is no other.
// Among equals the largest, which outside a Jam is the card it always was.
static BOOL isGoodCard(UIView *card, UIView *bar, UIView *marker) {
    return SGIsInside(card, bar) && !inStrip(card, bar) && (!marker || [marker isDescendantOfView:card]);
}

static UIView *chooseCard(UIView *bar, UIView *marker) {
    UIView *best = nil;
    BOOL bestHasStrip = NO;
    CGFloat bestArea = 0;
    for (UIView *v in sgr_nowPlayingPainted) {
        // Card sized: the paint itself has gone clear by now.
        if (!SGLooksLikeCard(v, UIColor.whiteColor.CGColor) || !isGoodCard(v, bar, marker)) continue;
        BOOL hasStrip = stripIn(v) != nil;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        BOOL better = !best || (hasStrip != bestHasStrip ? !hasStrip : area > bestArea);
        if (!better) continue;
        best = v;
        bestHasStrip = hasStrip;
        bestArea = area;
    }
    return best;
}

// Fallback when nothing is painted: the box around artwork, text and the small buttons.
static CGRect contentBounds(UIView *bar, UIView *target) {
    __block CGRect box = CGRectNull;
    SGForEachView(bar, ^(UIView *v) {
        if (v.hidden || v.alpha == 0 || inStrip(v, bar)) return;
        CGFloat width = v.bounds.size.width;
        BOOL content = ([v isKindOfClass:UIImageView.class] && width >= 20 && width <= 120)
            || [v isKindOfClass:UILabel.class]
            || ([v isKindOfClass:UIControl.class] && width <= 100);
        if (content) box = CGRectUnion(box, SGFrameIn(v, target));
    });
    return CGRectIsNull(box) ? box : CGRectInset(box, -10, -8);
}

static void roundView(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static void restyleCardContent(UIView *card) {
    SGForEachView(card, ^(UIView *v) {
        if (inStrip(v, card)) return;
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!square || v.layer.cornerRadius <= 0) return;
        if (v.layer.cornerRadius >= size.width / 2) {
            if (!sg_cardArtwork) sg_cardArtwork = v;
            return;
        }
        UIView *outer = v;
        for (UIView *u = v; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            roundView(u, size.width / 2);
            u.clipsToBounds = YES;
            outer = u;
        }
        sg_cardArtwork = outer;
    });
    __block UIView *progress = sg_progress;
    if (![progress isDescendantOfView:card]) {
        progress = nil;
        SGForEachView(card, ^(UIView *v) {
            CGRect f = v.frame;
            if (!progress && !inStrip(v, card) && f.size.height <= 3 && f.size.width >= 200 && v.superview.bounds.size.height >= 40) progress = v;
        });
        sg_progress = progress;
    }
    // Under the text, 226pt on a full width card, shorter on the one in the minimized tab bar.
    CGRect target = CGRectMake(52, card.bounds.size.height - 6, MAX(0, card.bounds.size.width - 160), 2);
    if (progress && !CGRectEqualToRect(progress.frame, target)) {
        progress.frame = target;
        [progress setNeedsLayout];
        [progress layoutIfNeeded];
    }
}

// The strip's own pane, a strip high less the gaps, on the card's side the strip is on. It is the card's glass,
// one material with it; the strip's white text reads over a bright page by the fade under the bars (TabBar.x). It is measured from
// the card's settled frame and the strip's height, not from the strip's frame: Spotify animates the strip
// in, and a pane taken from it mid-way sat about 12pt off and cut its ⋯ button. The glass comes in and goes
// by its effect, never by alpha (SGRGlass.h).
static void placeStripGlass(UIView *host, UIView *strip, CGRect card, BOOL above) {
    UIVisualEffectView *pane = objc_getAssociatedObject(host, &kStripGlassKey);
    if (!strip) {
        if (pane.effect) SGRAnimate(SGRMotionExit, ^{ SGRShowGlass(pane, NO); }, nil);
        return;
    }
    BOOL made = pane != nil;
    pane = SGGlassFor(host, &kStripGlassKey);
    if (!made) {
        pane.effect = nil;
        pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    CGFloat height = strip.bounds.size.height;
    CGRect frame = CGRectMake(card.origin.x, above ? CGRectGetMinY(card) - height : CGRectGetMaxY(card), card.size.width, height);
    pane.frame = CGRectInset(frame, 0, kStripInset);
    SGShapeGlass(pane, MIN(kCardRadius, pane.bounds.size.height / 2), NO);
    if (!pane.effect) SGRAnimate(SGRMotionRespond, ^{ SGRShowGlass(pane, YES); }, nil);
}

// The bar's left and right edges in its superview, set through the constants of the constraints that hold
// them there (their constants as Spotify set them kept to go back to), or through its frame when it is laid
// out by frame. A frame alone does not move a view laid out by constraints, nor what is constrained inside
// it (harness/tabbar). NO, with nothing changed, when its edges are held some other way, or right to left.
static NSMapTable<NSLayoutConstraint *, NSNumber *> *sg_constants;
static CGRect sg_fullFrame, sg_narrowFrame;

static void restoreEdges(UIView *bar) {
    for (NSLayoutConstraint *constraint in sg_constants) constraint.constant = [[sg_constants objectForKey:constraint] doubleValue];
    [sg_constants removeAllObjects];
    if (bar.translatesAutoresizingMaskIntoConstraints && CGRectEqualToRect(bar.frame, sg_narrowFrame)) bar.frame = sg_fullFrame;
    sg_narrowFrame = CGRectNull;
}

static BOOL setEdges(UIView *bar, CGFloat left, CGFloat right) {
    // Edges already where they are asked for walk nothing: placeInline asks on every layout pass of the bar.
    if (fabs(CGRectGetMinX(bar.frame) - left) < 0.25 && fabs(CGRectGetMaxX(bar.frame) - right) < 0.25) return YES;
    UIView *superview = bar.superview;
    if (bar.translatesAutoresizingMaskIntoConstraints) {
        CGRect frame = CGRectMake(left, bar.frame.origin.y, right - left, bar.frame.size.height);
        if (!CGRectEqualToRect(bar.frame, sg_narrowFrame)) sg_fullFrame = bar.frame;
        sg_narrowFrame = frame;
        if (!CGRectEqualToRect(bar.frame, frame)) bar.frame = frame;
        return YES;
    }
    if (superview.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) return NO;
    if (!sg_constants) sg_constants = [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger held = 0;
    for (NSLayoutConstraint *constraint in superview.constraints) {
        NSLayoutAttribute attribute = constraint.firstAttribute;
        BOOL barFirst = constraint.firstItem == bar && constraint.secondItem == superview;
        if (!constraint.active || constraint.relation != NSLayoutRelationEqual || constraint.multiplier != 1 || attribute != constraint.secondAttribute
            || (!barFirst && !(constraint.secondItem == bar && constraint.firstItem == superview))) continue;
        BOOL isLeft = attribute == NSLayoutAttributeLeading || attribute == NSLayoutAttributeLeft;
        if (!isLeft && attribute != NSLayoutAttributeTrailing && attribute != NSLayoutAttributeRight) continue;
        if (![sg_constants objectForKey:constraint]) [sg_constants setObject:@(constraint.constant) forKey:constraint];
        CGFloat edge = isLeft ? 0 : superview.bounds.size.width, value = isLeft ? left : right;
        CGFloat constant = barFirst ? value - edge : edge - value;
        if (constraint.constant != constant) constraint.constant = constant;
        held |= isLeft ? 1 : 2;
    }
    if (held == 3) return YES;
    restoreEdges(bar);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"now playing bar: its edges are not held by its superview's constraints, so it keeps Spotify's"); });
    return NO;
}

// In the row the card keeps the cover, the title and play, as the Music app's does: the device and add
// buttons stand aside while it is there and come back with the full card, the device button staying when the
// Player page's Device button asks for it (SGRKeyBarInlineConnect). Only what this hid is shown again.
static NSHashTable<UIView *> *sg_tucked;

static void tuckExtras(UIView *bar, BOOL tuck) {
    if (!sg_tucked) sg_tucked = [NSHashTable weakObjectsHashTable];
    // A stack hides an item only once the animation it was hidden in ends, so the buttons also fade on
    // their own, out as the card heads for the row and back in after it leaves.
    if (!tuck) {
        NSArray<UIView *> *items = sg_tucked.allObjects;
        [sg_tucked removeAllObjects];
        for (UIView *item in items) item.hidden = NO;
        SGRAnimate(SGRMotionRespond, ^{ for (UIView *item in items) item.alpha = 1; }, nil);
        return;
    }
    BOOL keepConnect = SGHidden(SGRKeyBarInlineConnect);
    SGForEachView(bar, ^(UIView *v) {
        NSString *name = v.accessibilityIdentifier;
        BOOL connect = [name isEqualToString:@"Components.ConnectButtonOutputSwitcher"];
        if ((!connect || keepConnect) && ![name isEqualToString:@"Components.UI.AddToButton"]) return;
        // The stack's own item, so the stack closes the gap.
        UIView *item = v;
        while (item.superview && item.superview != bar && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
        if (![item.superview isKindOfClass:UIStackView.class] || item.hidden) return;
        item.hidden = YES;
        SGRAnimate(SGRMotionExit, ^{ item.alpha = 0; }, nil);
        [sg_tucked addObject:item];
    });
}

// The Music app's two lines, the title over the artists, in place of Spotify's "title • artists" and the
// device line under it; the title alone in the minimized row. Each swipe page holds its own track's labels,
// so the text is read from them and drawn over them page by page. The page reads its own VoiceOver label.
static NSString *const kPageId = @"now-playing-bar-page";
static NSString *const kUnitId = @"Components.UI.PageInformationUnitNowPlayingBar";
static NSString *const kDeviceLineId = @"now-plaging-bar-connect-content";   // Spotify's spelling
static NSString *const kBullet = @" • ";
static char kTextKey;

@interface SGRBarText : UIView
@property (nonatomic, readonly) SGMarqueeLabel *title, *artists;
@property (nonatomic) BOOL inRow;
@end

@implementation SGRBarText
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _title = [SGMarqueeLabel new];
    _title.textColor = SGRPrimary();
    _title.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryLarge);
    _artists = [SGMarqueeLabel new];
    _artists.textColor = SGRSecondary();
    _artists.font = SGRFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryLarge);
    [self addSubview:_title];
    [self addSubview:_artists];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistsHeight = ceil(_artists.font.lineHeight);
    BOOL two = !_inRow && _artists.text.length;
    // The lines share 2pt of their leading, set as close as the Music app sets its card's.
    CGFloat shared = 2;
    CGFloat top = round((size.height - titleHeight - (two ? artistsHeight - shared : 0)) / 2);
    _title.frame = CGRectMake(0, top, size.width, titleHeight);
    _artists.frame = CGRectMake(0, top + titleHeight - shared, size.width, artistsHeight);
    _artists.alpha = two ? 1 : 0;
}
@end

static NSString *marqueeText(UIView *marquee) {
    for (UIView *sub in marquee.subviews) if ([sub isKindOfClass:UILabel.class]) return ((UILabel *)sub).text;
    return nil;
}

// Not hidden or faded by Spotify between the view and the unit; the unit's own children are faded by this file.
static BOOL inSight(UIView *view, UIView *unit) {
    for (UIView *v = view; v && v != unit; v = v.superview) {
        if (v.hidden || (v.alpha < 0.01 && v.superview != unit)) return NO;
    }
    return YES;
}

static void placeText(UIView *page) {
    // The cell lays itself out before its content view places Spotify's text, so the text is placed first.
    [page layoutIfNeeded];
    __block UIView *unit = nil;
    SGForEachView(page, ^(UIView *v) {
        if (!unit && [v.accessibilityIdentifier isEqualToString:kUnitId]) unit = v;
    });
    // Spotify lays a page out two ways. With a device line under it, the unit's first marquee is "title • artists"
    // and a later one, hidden, holds the artists alone. Without one, the first is the title and the next one in
    // sight is the artists. A promotional line, held at no alpha, is never the artists.
    __block NSString *line = nil, *artists = nil, *shown = nil;
    if (unit) SGForEachView(unit, ^(UIView *v) {
        if (![v.accessibilityIdentifier isEqualToString:@"Encore.MarqueeLabel"]) return;
        NSString *text = marqueeText(v);
        if (!line) {
            line = text;
            return;
        }
        if (!text.length) return;
        if (!artists && [line hasSuffix:[kBullet stringByAppendingString:text]]) artists = text;
        if (!shown && inSight(v, unit)) shown = text;
    });
    if (!line.length) return;
    NSString *title = line;
    if (artists) {
        title = [line substringToIndex:line.length - artists.length - kBullet.length];
    } else {
        NSRange bullet = [line rangeOfString:kBullet];
        if (bullet.location != NSNotFound) {
            title = [line substringToIndex:bullet.location];
            artists = [line substringFromIndex:NSMaxRange(bullet)];
        } else {
            artists = shown;
        }
    }

    SGRBarText *text = objc_getAssociatedObject(page, &kTextKey);
    BOOL made = !text;
    if (made) {
        text = [SGRBarText new];
        objc_setAssociatedObject(page, &kTextKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Inside Spotify's unit, so the text moves and fades with it as Spotify slides a page's in and out: the page's
    // height, which the card shows whole, and a line of text wide.
    CGRect frame = CGRectMake(0, -SGFrameIn(unit, page).origin.y, unit.bounds.size.width, page.bounds.size.height);
    BOOL inRow = sg_inline != nil;
    void (^place)(void) = ^{
        if (text.superview != unit) [unit addSubview:text];
        else if (unit.subviews.lastObject != text) [unit bringSubviewToFront:text];
        if (!CGRectEqualToRect(text.frame, frame)) text.frame = frame;
        text.title.text = title;
        text.artists.text = artists ?: @"";
        // Every pass: the artists can come in after the title.
        text.inRow = inRow;
        [text setNeedsLayout];
        [text layoutIfNeeded];
    };
    // A new page's text is placed where it belongs, never grown from nothing inside the bar's animation.
    if (made) [UIView performWithoutAnimation:place];
    else place();
    for (UIView *sub in unit.subviews) if (sub != text && sub.alpha > 0) sub.alpha = 0;
}

static void placeTexts(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        NSString *name = v.accessibilityIdentifier;
        if ([name isEqualToString:kPageId]) placeText(v);
        else if ([name isEqualToString:kDeviceLineId] && v.alpha > 0) v.alpha = 0;
    });
}

// In the minimized tab bar's row (TabBar.x): the bar narrowed to the slot by its edges, so Spotify's content
// lays itself out to the width, and moved down by a transform on the container's view, which Spotify's
// layout leaves alone. The slot is the track card's height and the card is centred in it; in a Jam the strip,
// on the bar above the card, rides above the row. A bar taller than its card for any other reason (a hat this
// file does not know) stays above the tab bar.
static const CGFloat kHatMin = 20;

// The Jam strip the bar was last styled with, shown or not: the tab bar's move lays the bar out again without
// styling it, and a second walk of the bar on each pass for it was a cost of its own.
static __weak UIView *sg_strip;

// Class names and frames only: a hat's labels can hold the track and the names of the people in a Jam.
static void appendShape(UIView *view, NSUInteger depth, NSMutableString *out) {
    [out appendFormat:@"%*s%@ %@\n", (int)depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    if (depth < 8) for (UIView *sub in view.subviews) appendShape(sub, depth + 1, out);
}

// The bar's edges set to `r`'s sides, `r` in the slot's coordinates and the view standing at `origin` in them.
static BOOL edgesTo(UIView *bar, CGRect r, CGPoint origin) {
    return !CGRectIsNull(r) && setEdges(bar, CGRectGetMinX(r) - origin.x, CGRectGetMaxX(r) - origin.x);
}

static void placeInline(UIViewController *container) {
    UIView *view = container.view;
    UIView *bar = container.childViewControllers.firstObject.viewIfLoaded;
    CGRect track = CGRectIsNull(sg_trackFrame) ? bar.frame : sg_trackFrame;
    // A hat is a row of its own (the Jam's is 44pt); a few points between card and bar are not one.
    BOOL hat = bar && bar.bounds.size.height - track.size.height >= kHatMin;
    UIView *strip = hat && [sg_strip isDescendantOfView:bar] ? sg_strip : nil;
    BOOL known = !hat || strip;
    if (!known) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSMutableString *shape = [NSMutableString string];
            appendShape(bar, 0, shape);
            SGLogLong(@"now playing bar", [NSString stringWithFormat:@"a hat on the bar that is not the Jam's keeps the card out of the "
                                          @"tab bar's row: card %@, bar %@\n%@", NSStringFromCGRect(track), NSStringFromCGRect(bar.frame), shape]);
        });
    }
    CGRect slot = !bar || bar.superview != view || !known ? CGRectNull : SGRTabBarInlineSlot(view.superview, track.size.height);
    // Where the view stands untransformed, in the slot's coordinates.
    CGPoint origin = CGPointMake(view.center.x - view.bounds.size.width / 2, view.center.y - view.bounds.size.height / 2);
    if (!edgesTo(bar, slot, origin)) {
        if (sg_inline) tuckExtras(bar, NO);
        sg_inline = nil;
        if (!CGAffineTransformIsIdentity(view.transform)) view.transform = CGAffineTransformIdentity;
        // Above the bar the card takes the glass row's edges (SGRTabBarGlassRow).
        CGRect row = bar && bar.superview == view ? SGRTabBarGlassRow(view.superview) : CGRectNull;
        if (!edgesTo(bar, row, origin)) restoreEdges(bar);
        if (bar) placeTexts(bar);
        return;
    }
    CGAffineTransform move = CGAffineTransformMakeTranslation(0, CGRectGetMidY(slot) - origin.y - CGRectGetMidY(track));
    if (!CGAffineTransformEqualToTransform(view.transform, move)) view.transform = move;
    tuckExtras(bar, YES);
    sg_inline = view;
    placeTexts(bar);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *clips = [NSMutableString string];
        for (UIView *v = view.superview; v; v = v.superview) if (v.clipsToBounds) [clips appendFormat:@" %@", v.class];
        SGLog(@"now playing bar in the tab bar's row at %@, clipped by:%@", NSStringFromCGRect(slot), clips.length ? clips : @" nothing");
    });
    // Whether the strip followed the bar's narrowed edges, which no recorded tree shows.
    static dispatch_once_t jamOnce;
    if (strip) dispatch_once(&jamOnce, ^{
        SGLog(@"now playing bar in the tab bar's row in a Jam: strip %@, bar %@, card %@ (in the container's view)",
              NSStringFromCGRect(SGFrameIn(strip, view)), NSStringFromCGRect(bar.frame), NSStringFromCGRect(track));
    });
}

void SGRNowPlayingBarFollowTabBar(void) {
    UIViewController *container = sg_container;
    if (!container.isViewLoaded) return;
    placeInline(container);
    [container.view setNeedsLayout];
    [container.view layoutIfNeeded];
}

CGRect SGRNowPlayingStripFrameIn(UIView *host) {
    UIView *strip = sg_strip;
    if (SGRNowPlayingStripHeight() <= 0 || !host || ![strip isDescendantOfView:host]) return CGRectNull;
    return [host convertRect:strip.bounds fromView:strip];
}

// The tab bar's moves under way (one can start before the last one ends), and the relayout owed to their end.
static NSInteger sg_barMoves;
static BOOL sg_owedLayout, sg_owedRefresh;

static void relayoutBar(UIView *host, BOOL taller) {
    if (sg_barMoves > 0) {
        sg_owedLayout = YES;
        sg_owedRefresh |= taller;
        return;
    }
    [host setNeedsLayout];
    if (taller) SGRRefreshTabBar();
}

void SGRNowPlayingBarMoving(BOOL moving) {
    UIView *strip = sg_strip;
    if (moving) {
        // Spotify's own strip-in animation would race the tab bar's spring: the strip goes to where it is set.
        if (sg_barMoves++ == 0 && SGRNowPlayingStripHeight() > 0 && strip.window && strip.layer.animationKeys.count) [strip.layer removeAllAnimations];
        return;
    }
    if (sg_barMoves == 0 || --sg_barMoves > 0) return;
    UIView *host = sg_container.viewIfLoaded;
    if (sg_owedLayout && host) relayoutBar(host, sg_owedRefresh);
    sg_owedLayout = sg_owedRefresh = NO;
    static dispatch_once_t once;
    if (host && SGRNowPlayingStripHeight() > 0 && [strip isDescendantOfView:host]) dispatch_once(&once, ^{
        SGLog(@"now playing bar: tab bar move ended in a Jam, strip %@, card glass %@ (in the container's view)",
              NSStringFromCGRect(SGFrameIn(strip, host)), NSStringFromCGRect(SGFrameIn(sg_cardGlass, host)));
    });
}

// The same bar class also stands at the top of Spotify's sheets (the DJ request one: Up next, device, play).
// It is not the tab bar's card there: the sheet has its own blue ground and corners, and a dark 24pt pane of
// the bar's full width on it reads as a frame round the track. It is left as Spotify draws it, and it must not
// become the bar this file tracks (sg_container, sg_cardGlass, sgr_nowPlayingRoot): the player takes its card
// frame from those.
static BOOL inSheet(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"sheet-view"] || SGClassNamed(v.class, @"SheetImpl")) return YES;
    }
    return NO;
}

// The card's glass frame in `host`: the card, else the box round the track's content, with the strip cut
// out from its side, all of it when the card is a view around both, else as much as overlaps. CGRectNull
// when there is no card to speak of.
static CGRect trackFrame(UIView *bar, UIView *card, UIView *strip, CGRect stripFrame, UIView *host, BOOL *stripAbove) {
    CGRect frame = card ? SGFrameIn(card, host) : contentBounds(bar, host);
    if (CGRectIsNull(frame)) return frame;
    *stripAbove = NO;
    if (strip) {
        *stripAbove = CGRectGetMidY(stripFrame) < CGRectGetMidY(frame);
        CGFloat cut = card && [strip isDescendantOfView:card] ? strip.bounds.size.height : CGRectIntersection(frame, stripFrame).size.height;
        frame.size.height -= cut;
        if (*stripAbove) frame.origin.y += cut;
    }
    frame.size.height = MIN(frame.size.height, 80);
    return frame.size.height < 30 || frame.size.width < 100 ? CGRectNull : frame;
}

static void styleNowPlayingBar(UIViewController *container) {
    if (container.isViewLoaded && inSheet(container.view)) {
        UIVisualEffectView *pane = objc_getAssociatedObject(container.view, &kGlassKey);
        if (pane) [pane removeFromSuperview];
        return;
    }
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    sg_container = container;
    if (!sgr_nowPlayingPainted) sgr_nowPlayingPainted = [NSHashTable weakObjectsHashTable];
    sgr_nowPlayingRoot = bar;

    // What is painted now, before it goes clear; SGRRepaint.x adds what Spotify paints later. Its size is
    // judged when the card is chosen: in a Jam the card can still be unsized here (harness/tabbar).
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UIVisualEffectView.class] && !SGKeepsColor(v) && SGIsVisibleColor(v.layer.backgroundColor)) [sgr_nowPlayingPainted addObject:v];
    });
    // The card stays while it still holds the track with no strip in it, whatever Spotify paints after.
    UIView *marker = trackMarker(bar);
    UIView *card = sg_card;
    if (!card || !isGoodCard(card, bar, marker) || stripIn(card)) card = sg_card = chooseCard(bar, marker);

    // The strip before the bar's paint goes, so the log says what it was made of.
    UIView *strip = sg_strip = stripIn(bar);
    if (strip && (strip.hidden || strip.alpha < 0.01 || !strip.window)) strip = nil;
    static dispatch_once_t stripOnce;
    if (strip) dispatch_once(&stripOnce, ^{
        NSMutableString *tree = [NSMutableString string];
        SGForEachView(strip, ^(UIView *v) {
            CGColorRef paint = v.layer.backgroundColor;
            [tree appendFormat:@"%@ %@ a=%.2f%@\n", v.class, NSStringFromCGRect(SGFrameIn(v, strip)), v.alpha,
                                paint ? [NSString stringWithFormat:@" paint=%@", [UIColor colorWithCGColor:paint]] : @""];
        });
        SGLogLong(@"now playing bar", [NSString stringWithFormat:@"Jam strip %@, controller %@, in the bar: %@ (Spotify's paint inside the "
                                       @"bar is cleared as it is set, SGRRepaint.x)\n%@", strip.class, strip.nextResponder.class,
                                       [strip isDescendantOfView:bar] ? @"yes" : @"no", tree]);
    });

    container.view.layer.backgroundColor = NULL;
    SGStripBackgrounds(bar);

    // Spotify lays the strip out after the bar and moves it in, so the bar is styled again a moment after
    // the strip has moved, until it stays put. A strip that comes, goes or changes height moves the fade too.
    CGRect stripFrame = strip ? SGFrameIn(strip, container.view) : CGRectZero;
    if (!CGRectEqualToRect(stripFrame, sg_stripFrame)) {
        BOOL taller = stripFrame.size.height != sg_stripFrame.size.height;
        sg_stripFrame = stripFrame;
        UIView *host = container.view;
        // During the tab bar's move it waits for the move's end (SGRNowPlayingBarMoving).
        dispatch_async(dispatch_get_main_queue(), ^{ relayoutBar(host, taller); });
    }
    if (strip.bounds.size.height < 1) strip = nil;
    // The track's frame for the row, then again for the glass: the row narrows the bar, which the card follows.
    BOOL stripAbove = NO;
    // A card's, or in a Jam the box round the track's content; outside a Jam without a card the bar's own
    // frame stands for it, as before, since that box is padded.
    sg_trackFrame = card || strip ? trackFrame(bar, card, strip, stripFrame, container.view, &stripAbove) : CGRectNull;
    placeInline(container);
    CGRect frame = trackFrame(bar, card, strip, stripFrame, container.view, &stripAbove);
    if (CGRectIsNull(frame)) return;

    CGFloat radius = MIN(kCardRadius, frame.size.height / 2);
    if (card) {
        roundView(card, radius);
        restyleCardContent(card);
    }

    UIVisualEffectView *glass = SGGlassFor(container.view, &kGlassKey);
    // Dark whatever the system is set to: the bar is outside the navigation stacks Spotify makes dark, and
    // took the system's light glass on a phone in light mode (TabBar.x).
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    sg_cardGlass = glass;
    glass.frame = frame;
    SGShapeGlass(glass, radius, NO);
    placeStripGlass(container.view, strip, frame, stripAbove);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"now playing card %@ at %@ (bar %@, container %@)", card.class, NSStringFromCGRect(frame),
              NSStringFromCGRect(bar.frame), NSStringFromCGRect(container.view.bounds));
    });
    static dispatch_once_t jamOnce;
    if (strip) dispatch_once(&jamOnce, ^{
        SGLog(@"now playing card in a Jam: %@ at %@, strip %@ at %@ (bar %@)", card.class, NSStringFromCGRect(frame), strip.class,
              NSStringFromCGRect(SGFrameIn(strip, container.view)), NSStringFromCGRect(bar.frame));
    });
}

%hook _TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    styleNowPlayingBar((UIViewController *)self);
}
%end

// The page the bar stands in passes touches outside the bar through, and the bar in the tab bar's row is
// below the page's bounds: a touch there reaches the bar only through this. Only the narrowed card takes
// one: the container's view keeps the screen's width, and took the touches meant for the tab bar's circles.
// Only the container's view moves to the row, by a transform; Spotify's layout view above it stays at the
// bar's old place and took every touch there (#70), so a touch on nothing of the moved bar's goes through.
%hook _TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    UIView *moved = sg_inline;
    if (![moved isDescendantOfView:(UIView *)self] || (hit && [hit isDescendantOfView:moved])) return hit;
    UIView *inside = [moved hitTest:[(UIView *)self convertPoint:point toView:moved] withEvent:event];
    return inside && inside != moved ? inside : nil;
}
%end

// A page lays out again when Spotify moves its text, which it does after the first pass at launch.
%hook _TtC18NowPlaying_BarImpl17InformationCellV2
- (void)layoutSubviews {
    %orig;
    if (sgr_nowPlayingRoot && [(UIView *)self isDescendantOfView:sgr_nowPlayingRoot]) placeText((UIView *)self);
}
%end

%hook _TtC18NowPlaying_BarImpl15InformationCell
- (void)layoutSubviews {
    %orig;
    if (sgr_nowPlayingRoot && [(UIView *)self isDescendantOfView:sgr_nowPlayingRoot]) placeText((UIView *)self);
}
%end

// A page's marquee lays out again when Spotify gives it a new track, which nothing else of the bar's does.
%hook _TtCE14Encore_TextKitO16EncoreFoundation6Encore12MarqueeLabel
- (void)layoutSubviews {
    %orig;
    UIView *root = sgr_nowPlayingRoot;
    if (!root || ![(UIView *)self isDescendantOfView:root]) return;
    for (UIView *v = (UIView *)self; v && v != root; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPageId]) {
            placeText(v);
            return;
        }
    }
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *parent = ((UIViewController *)self).parentViewController;
    if (SGClassNamed(parent.class, @"NowPlayingBarContainer")) styleNowPlayingBar(parent);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
        @"_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView",
        @"_TtCE14Encore_TextKitO16EncoreFoundation6Encore12MarqueeLabel",
        @"_TtC18NowPlaying_BarImpl17InformationCellV2",
    ]);
}
