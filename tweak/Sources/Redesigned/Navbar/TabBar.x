// Tab bar: Spotify's own bar stays where it is but goes invisible, and a system UITabBar sits on top
// of it. On iOS 26+ with UIDesignRequiresCompatibility off, UIKit draws that bar as real Liquid Glass
// (selection bubble, lensing, light/dark adaptation) with no glass API of ours. Spotify's bar keeps
// its frame, so the page insets and the now playing bar stay where Spotify puts them; where the system
// bar is taller than Spotify's, Spotify is made to leave it the room (see "room for the glass bar").
//
// A tab picked on the system bar is passed on as a tap on the hidden Spotify item it mirrors, and the
// system bar's selection follows whichever Spotify label is painted white, or the tab of the mod's own whose
// page is up (SGRNavbarLitTab), which Spotify does not know of. Navbar.x composes the
// hidden row, so its order, hidden tabs and tabs of the mod's own carry over. Always on in the redesign.
//
// Tree (trees/home.txt): NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView of
//   ElementContentView<TabBarItemElement>, each with an SPTEncoreIconView and an SPTEncoreLabel.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Settings/SGPage.h"
#import "Headers/SPTEncoreIconView.h"
#import "Shared/Navigation/TabIcons.h"
#import <objc/message.h>

static char kBarKey, kApartBarKey, kHostKey, kFadeKey;
// On a UITabBarItem: the names of the Encore icons its image and selectedImage were drawn from (see fillBar).
static char kGlyphNamesKey;
static __weak UIView *sg_stockBar;
static CGFloat sg_room, sg_glassHeight;   // see "room for the glass bar"
// See "minimized". sg_keepApart holds the second bar on screen while the main one grows back under it.
static BOOL sg_minimized, sg_keepApart;

@interface SGRSystemTabBar : UITabBar <UITabBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *stockBar;
@property (nonatomic, copy) NSArray<UIView *> *sources;
@property (nonatomic, weak) UILongPressGestureRecognizer *hold;
@property (nonatomic) BOOL holding;
// The other bar, when the split tabs have one of their own: a tab picked on one bar clears the other's.
@property (nonatomic, weak) SGRSystemTabBar *partner;
// The item last shown selected, so a tap on it can be told from a tap that changes the tab.
@property (nonatomic, weak) UITabBarItem *shown;
@end

static void syncBar(UIView *stockBar);

#pragma mark - reading Spotify's items

// The items the bar shows, left to right as Navbar/Navbar.x placed them.
static NSArray<UIView *> *tabItems(UIView *tabBar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIView *item in SGRowIn(tabBar).arrangedSubviews) {
        if (!item.hidden && item.bounds.size.width >= 20) [items addObject:item];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(SGFrameIn(a, tabBar).origin.x) compare:@(SGFrameIn(b, tabBar).origin.x)];
    }];
}

// Navbar.x never reorders Spotify's row and appends the mod's own tabs after it, so Home stays first.
static BOOL isHome(UIView *item, UIView *tabBar) {
    return item && item == SGRowIn(tabBar).arrangedSubviews.firstObject;
}

static UILabel *labelIn(UIView *item) {
    __block UILabel *label = nil;
    SGForEachView(item, ^(UIView *v) {
        if (!label && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) label = (UILabel *)v;
    });
    return label;
}

static UIView *iconIn(UIView *item) {
    __block UIView *icon = nil;
    SGForEachView(item, ^(UIView *v) {
        if (icon || v.bounds.size.width < 2) return;
        if ([v isKindOfClass:UIImageView.class] || [NSStringFromClass(v.class) containsString:@"IconView"]) icon = v;
    });
    return icon;
}

// Spotify paints the selected tab's label white and the rest #B3B3B3.
static BOOL isActive(UIView *item) {
    UIColor *color = labelIn(item).textColor;
    CGFloat white = 0, alpha = 0, r, g, b;
    if (![color getWhite:&white alpha:&alpha] && [color getRed:&r green:&g blue:&b alpha:&alpha]) white = MIN(r, MIN(g, b));
    return white > 0.95;
}

static BOOL hasInk(UIImage *image) {
    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    if (!width || !height) return NO;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);
    const uint8_t *alpha = pixels.bytes;
    for (size_t i = 0; i < pixels.length; i++) if (alpha[i] > 16) return YES;
    return NO;
}

static UIImage *renderLayer(CALayer *layer, CGSize size) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [layer renderInContext:context.CGContext];
    }];
    return hasInk(image) ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

// The SPTEncoreIcon an icon view was built with. Encore keeps it in a Swift ivar with no getter.
static id encoreIconOf(UIView *view) {
    Ivar ivar = class_getInstanceVariable(view.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(view, ivar) : nil;
}

// An SPTEncoreIcon's name, which is what tells two icons apart: Spotify may hand a view a new instance of the
// same glyph. Nil for an icon that does not say.
static NSString *iconName(id icon) {
    id name = [icon respondsToSelector:@selector(name)] ? [icon name] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

// The filled variant of a tab's SPTEncoreIcon (-active, which fillBar's log prints), when it has one. A filled
// icon has none: its -active is itself, or the same glyph again.
static id activeVariantOf(id icon) {
    SEL selector = NSSelectorFromString(@"active");
    if (!icon || ![icon respondsToSelector:selector]) return nil;
    id variant = ((id (*)(id, SEL))objc_msgSend)(icon, selector);
    if (variant == icon || ![variant isKindOfClass:[icon class]]) return nil;
    NSString *name = iconName(icon);
    return name && [name isEqualToString:iconName(variant)] ? nil : variant;
}

// One glyph of a tab: `icon` drawn at the size of `live`, Spotify's icon view it came from. The caller picks the
// icon, outline or filled, so the cache key names the glyph actually drawn and an outline drawing can never be
// filed under a filled icon's name or the other way round. isActive only picks the view's colors, white either
// way. Drawn on an icon view of our own, off screen, so the images do not wait for Spotify's views to lay out
// and paint, and UITabBar swaps image and selectedImage itself.
static UIImage *drawGlyph(UIView *live, id icon, BOOL active) {
    if (!live) return nil;
    CGSize size = live.bounds.size;
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (icon && viewClass) {
        static NSCache<NSString *, UIImage *> *cache;
        if (!cache) cache = [NSCache new];
        NSString *key = [NSString stringWithFormat:@"%@ %d %@", iconName(icon) ?: icon, active, NSStringFromCGSize(size)];
        UIImage *cached = [cache objectForKey:key];
        if (cached) return cached;
        SPTEncoreIconView *view = [[viewClass alloc] initWithIcon:icon];
        view.frame = (CGRect){CGPointZero, size};
        [view setForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setActiveForegroundColor:)]) [view setActiveForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setIsActive:)]) [view setIsActive:active];
        [view layoutIfNeeded];
        UIImage *image = renderLayer(view.layer, size);
        if (image) {
            [cache setObject:image forKey:key];
            return image;
        }
    }
    // Tabs of the mod's own draw a UIImageView, or an icon Encore would not draw off screen.
    return size.width >= 2 ? renderLayer(live.layer, size) : nil;
}

// A tab's glyph from what its view holds now, the filled variant for the selected state where the icon has one.
static UIImage *glyphOf(UIView *item, BOOL active) {
    UIView *live = iconIn(item);
    id icon = live ? encoreIconOf(live) : nil;
    if (active) icon = activeVariantOf(icon) ?: icon;
    return drawGlyph(live, icon, active);
}

// For the Tab bar page's list and preview: a tab of Spotify's drawn from its item on the bar, hidden or not,
// found by the label its entry is named after; a tab of the mod's own drawn from its entry, as Navbar.x
// draws it on the bar. Nil while Spotify's item has not been built.
UIImage *SGRNavbarGlyph(NSDictionary *entry, BOOL active) {
    if (entry[SGRNavbarURI]) {
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        UIView *icon = SGTabIconView(entry[SGRNavbarIcon], [entry[SGRNavbarIconSet] isEqual:SGTabIconSetSymbols], UIColor.whiteColor);
        icon.translatesAutoresizingMaskIntoConstraints = YES;
        icon.frame = holder.bounds;
        if ([icon isKindOfClass:UIImageView.class]) icon.contentMode = UIViewContentModeScaleAspectFit;
        [holder addSubview:icon];
        [holder layoutIfNeeded];
        return glyphOf(holder, active);
    }
    for (UIView *item in SGRowIn(sg_stockBar).arrangedSubviews) {
        if ([NSStringFromClass(item.class) isEqualToString:@"SGRTabItemView"]) continue;
        if ([labelIn(item).text isEqualToString:entry[SGRNavbarID]]) return glyphOf(item, active);
    }
    return nil;
}

#pragma mark - passing a tap on

// NavigationUI_TabBarImpl's TabBarItemElementUI answers a tap recognizer (-handleTap), so the tap is
// replayed through the recognizer's own target-action pairs, the same call a real touch ends in.
static BOOL fireTapRecognizers(UIView *view) {
    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    if (!targetsIvar) return NO;
    BOOL fired = NO;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled) continue;
        for (id pair in object_getIvar(recognizer, targetsIvar)) {
            Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
            Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
            if (!targetIvar || !actionIvar) continue;
            id target = object_getIvar(pair, targetIvar);
            SEL action = *(SEL *)((char *)(__bridge void *)pair + ivar_getOffset(actionIvar));
            if (!target || !action || ![target respondsToSelector:action]) continue;
            SGLog(@"tab bar: tap -> %@ %@", NSStringFromClass([target class]), NSStringFromSelector(action));
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
            fired = YES;
        }
    }
    return fired;
}

static void forwardTap(UIView *item) {
    __block BOOL sent = NO;
    SGForEachView(item, ^(UIView *v) {
        if (!sent) sent = fireTapRecognizers(v);
    });
    SGForEachView(item, ^(UIView *v) {
        if (sent || ![v isKindOfClass:UIControl.class]) return;
        SGLog(@"tab bar: tap -> control %@", NSStringFromClass(v.class));
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        sent = YES;
    });
    if (!sent) {
        NSMutableString *out = [NSMutableString stringWithFormat:@"tab bar: nothing to tap in %@", NSStringFromClass(item.class)];
        SGForEachView(item, ^(UIView *v) {
            for (UIGestureRecognizer *r in v.gestureRecognizers) [out appendFormat:@"\n  %@ on %@", r, NSStringFromClass(v.class)];
        });
        SGLogLong(@"navbar", out);
    }
}

#pragma mark - the system bar

// A name too long for its tab (one of the user's own, a split tab's circle) shrinks a little before UIKit cuts
// it short, to 8 pt from 10.
void SGRShrinkTabTitles(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || ((UILabel *)v).adjustsFontSizeToFitWidth) return;
        ((UILabel *)v).adjustsFontSizeToFitWidth = YES;
        ((UILabel *)v).minimumScaleFactor = 0.8;
    });
}

@implementation SGRSystemTabBar

// UIKit makes the labels as it lays the items out, so they are shrunk after each pass.
- (void)layoutSubviews {
    [super layoutSubviews];
    SGRShrinkTabTitles(self);
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSUInteger index = [self.items indexOfObject:item];
    if (index == NSNotFound || index >= self.sources.count) return;
    BOOL again = item == self.shown;
    self.shown = item;
    // On the minimized bar the leading circle brings the whole bar back, as the Music app's does; passed on,
    // the tap would take Spotify's stack back to its root. Minimizing builds the circle's item anew, so it
    // is told by the bar it is on, not by being the item shown before.
    BOOL leading = self.stockBar && objc_getAssociatedObject(self.stockBar, &kBarKey) == self;
    if (sg_minimized && (again || leading)) {
        SGRSetTabBarMinimized(NO, YES);
        return;
    }
    // One of Spotify's own takes the light back from a tab of the mod's own.
    UIView *source = self.sources[index];
    if (![NSStringFromClass(source.class) isEqualToString:@"SGRTabItemView"]) SGRNavbarForgetTab();
    // Home tapped while on Home pops Spotify's stack, which would take Mod Settings straight off it.
    if (!self.holding) forwardTap(source);
    self.partner.selectedItem = nil;
    self.partner.shown = nil;
    // Spotify repaints its labels a moment later; a tap it did not take snaps the selection back.
    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
}

// UIKit's item views are private, so the item under a touch is the one whose title label or glyph is
// nearest. With the labels hidden only the glyph is left; UIKit shows the item's own image instance.
- (UITabBarItem *)itemAt:(CGPoint)point {
    __block UITabBarItem *nearest = nil;
    __block CGFloat best = CGFLOAT_MAX;
    SGForEachView(self, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        CGFloat distance = fabs([v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), 0) toView:self].x - point.x);
        if (distance >= best) return;
        for (UITabBarItem *item in self.items) {
            UIImage *image = glyph ? ((UIImageView *)v).image : nil;
            if (label ? ![((UILabel *)v).text isEqualToString:item.title] : !image || (image != item.image && image != item.selectedImage)) continue;
            best = distance;
            nearest = item;
            break;
        }
    });
    return nearest;
}

// UIView asks itself this for its own recognizers too, so only the hold is answered here.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.hold) return [super gestureRecognizerShouldBegin:recognizer];
    NSUInteger index = [self.items indexOfObject:[self itemAt:[recognizer locationInView:self]]];
    return index < self.sources.count && isHome(self.sources[index], self.stockBar);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        // The bar may still pick Home as the finger lifts, after this.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

@end

// The system bar's own view in Spotify's bar. UIKit measures the system bar and lays it out by the safe
// area of the view it stands in, and the room made under Spotify's bar is not the phone's: on a phone
// with a home button it went under the platter as well, squeezing it to 49 pt. So this view hands the
// bar the safe area without the room.
@interface SGRTabBarHost : UIView
@end

@implementation SGRTabBarHost
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = [super safeAreaInsets];
    insets.bottom = MAX(0, insets.bottom - sg_room);
    return insets;
}
@end

@interface SGRHomeHold : UILongPressGestureRecognizer
@end

@implementation SGRHomeHold
+ (void)held:(SGRHomeHold *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) SGOpenModSettings(hold.view);
}
@end

// On Spotify's own bar a hold that begins fails the item's tap recognizer, so Home is not tapped too.
static void holdHome(UIView *stockBar) {
    UIView *home = SGRowIn(stockBar).arrangedSubviews.firstObject;
    if (!home) return;
    for (UIGestureRecognizer *recognizer in home.gestureRecognizers) {
        if ([recognizer isKindOfClass:SGRHomeHold.class]) return;
    }
    [home addGestureRecognizer:[[SGRHomeHold alloc] initWithTarget:SGRHomeHold.class action:@selector(held:)]];
}

static void logBarOnce(UITabBar *bar) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGLogLong(@"navbar", [NSString stringWithFormat:@"system tab bar %@\n%@", NSStringFromCGRect(bar.superview.frame), [bar recursiveDescription]]);
        });
    });
}

#pragma mark - the fade under the bars

// The pages darken toward the bottom of the screen under the glass bar and the now playing bar, from clear
// a little above the now playing card to half black at the screen's foot, so a row going under the glass
// reads as passing behind it. Never darker than half: the glass still has the page to lens. The fade is the
// stock bar's own subview, behind the glass, so it slides away with the bar when a page hides it; Spotify's
// bar does not clip, or the glass bar would not have stood over the now playing bar before the room was made.
@interface SGRBarFade : UIView
@end

@implementation SGRBarFade
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end

// The now playing card (56), its gap over the bar (8) and 24 more, whether a song is playing or not; in a
// Jam the strip's height on top while the card is above the bar. In the minimized row the strip rides just
// above the card, which these 88 already reach.
static const CGFloat kFadeAbove = 88;

static void placeFade(UIView *stockBar, CGRect glass, BOOL minimized) {
    SGRBarFade *fade = objc_getAssociatedObject(stockBar, &kFadeKey);
    if (!fade) {
        fade = [SGRBarFade new];
        fade.userInteractionEnabled = NO;
        CAGradientLayer *layer = (CAGradientLayer *)fade.layer;
        // Eased rather than straight, so the fade has no edge where it starts.
        layer.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.3].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
        layer.locations = @[@0, @0.5, @1];
        objc_setAssociatedObject(stockBar, &kFadeKey, fade, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat top = CGRectGetMinY(glass) - kFadeAbove - (minimized ? 0 : SGRNowPlayingStripHeight());
    CGRect frame = CGRectMake(0, top, stockBar.bounds.size.width, CGRectGetMaxY(glass) - top);
    if (!CGRectEqualToRect(fade.frame, frame)) fade.frame = frame;
    if (fade.superview != stockBar || stockBar.subviews.firstObject != fade) [stockBar insertSubview:fade atIndex:0];
}

#pragma mark - room for the glass bar

// UIKit's glass bar asks for 83 pt, the platter the top 62 of it, over no more safe area than a Face ID
// phone's 34 (simulator, iOS 26.5 and 27). Spotify's bar is its 49 pt row over the bottom safe area of
// TabBarContainerImpl's view: a guide from 49 pt above the safe area's bottom to the view's bottom sets
// its height (its viewDidLoad, 0x100840a2c), the now playing bar stands on that guide's top
// (MainUIContainer's chrome bottom anchor, 0x100ae0178), the bar slides away by the inset plus 49 when
// Spotify hides it (0x1037169a4) and the pages get 49 on top of the inset (0x10707bde4). A Face ID
// phone gives the view 34 and the two bars match. A phone with a home button gives it none, and so does
// Spotify's message bar (LimitedExperienceIndicatorBar: Offline, Private Session) coming in under the
// tab bar, which takes the home indicator's inset for itself: the glass bar stood 34 pt above
// Spotify's, over the now playing bar. So the view gets the rest of the glass bar's height as safe
// area, and Spotify lays its bar, the now playing bar, the pages and the hide out for the glass bar
// itself, and moves them all with the message bar.
static const CGFloat kStockRow = 49;

// UIKit asks for 62 + max(21, inset) on a phone with a home button, max(83, 49 + inset) on a Face ID
// phone, by the safe area of the view the bar stands in. SGRTabBarHost keeps the room out of that; if
// it ever reached the bar again, the bar would ask for more room every pass, so what it asks for with
// no room made is what is kept.
static CGFloat glassHeight(UITabBar *bar, UIView *stockBar) {
    if (sg_room < 0.5 || sg_glassHeight <= 0) sg_glassHeight = [bar sizeThatFits:CGSizeMake(stockBar.bounds.size.width, kStockRow)].height;
    return sg_glassHeight;
}

static UIViewController *containerOf(UIView *stockBar) {
    Class containerClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl");
    for (UIResponder *r = stockBar.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:containerClass]) return (UIViewController *)r;
    }
    return nil;
}

static void makeRoom(UIViewController *container) {
    UIView *stockBar = sg_stockBar;
    UITabBar *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    if (!bar.window || !container.isViewLoaded || ![stockBar isDescendantOfView:container.view]) return;
    UIEdgeInsets extra = container.additionalSafeAreaInsets;
    CGFloat inset = container.view.safeAreaInsets.bottom - extra.bottom;
    CGFloat height = glassHeight(bar, stockBar);
    // Spotify's regular width bar is a fixed 76 pt that ignores the inset.
    BOOL compact = container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat room = compact ? MAX(0, ceil(height - kStockRow - inset)) : 0;
    if (fabs(extra.bottom - room) < 0.5) return;
    sg_room = extra.bottom = room;
    container.additionalSafeAreaInsets = extra;
    SGLog(@"tab bar: %.0f pt of room made under Spotify's bar for the glass bar's %.0f, over an inset of %.0f", room, height, inset);
}

static SGRSystemTabBar *makeBar(UIView *stockBar) {
    SGRSystemTabBar *bar = [[SGRSystemTabBar alloc] initWithFrame:stockBar.bounds];
    // UIKit draws the glass in the appearance the bar inherits, and the bar is outside the navigation
    // stacks Spotify makes dark itself (-[SPNavigationController viewDidLoad] while +[SPTLiquidGlass
    // isEnabled]), so a phone in light mode had it light over Spotify's black. Spotify is dark whatever
    // the system is, and so is the bar.
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.delegate = bar;
    bar.stockBar = stockBar;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:bar action:@selector(held:)];
    hold.delegate = bar;
    [bar addGestureRecognizer:hold];
    bar.hold = hold;
    return bar;
}

// Setting a tab's image lays its bar's items out again, so an image is set only when it is another one: the glyph
// cache hands back the same object for the same glyph.
static void setGlyphs(UITabBarItem *item, UIImage *image, UIImage *selectedImage) {
    if (image && item.image != image) item.image = image;
    if (selectedImage && item.selectedImage != selectedImage) item.selectedImage = selectedImage;
}

// One bar's share of the tabs: its items, their glyphs and titles. YES while a glyph is still missing.
static BOOL fillBar(SGRSystemTabBar *bar, NSArray<UIView *> *sources, BOOL hideLabels) {
    bar.tintColor = SGRAccent();
    if (![sources isEqualToArray:bar.sources]) {
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
        for (UIView *source in sources) [items addObject:[[UITabBarItem alloc] initWithTitle:hideLabels ? nil : labelIn(source).text image:nil tag:items.count]];
        bar.sources = sources;
        [bar setItems:items animated:NO];
        NSMutableString *out = [NSMutableString stringWithString:@"tab bar icons"];
        for (UIView *source in sources) {
            UIView *live = iconIn(source);
            id icon = live ? encoreIconOf(live) : nil;
            id variant = activeVariantOf(icon);
            [out appendFormat:@"\n  %@: %@ icon %@ active-variant %@ live-isActive %d label-white %d", labelIn(source).text, NSStringFromClass(live.class),
                 iconName(icon) ?: icon, iconName(variant) ?: variant,
                 [live respondsToSelector:@selector(isActive)] ? [(SPTEncoreIconView *)live isActive] : -1, isActive(source)];
        }
        SGLogLong(@"navbar", out);
    }

    BOOL missing = NO;
    for (NSUInteger i = 0; i < sources.count; i++) {
        UITabBarItem *item = bar.items[i];
        // A tab's filled glyph is not an isActive state of its icon view: Spotify gives the selected tab's view the
        // filled SPTEncoreIcon in place of the outline one (#151: the glass bar's selected tab stayed outlined, and
        // showed filled only once minimizing made its item anew). So both images come from the icon the view holds,
        // known by the icon itself and never by the label's color, which Spotify repaints apart from the icon: an
        // outline icon gives image and its -active variant selectedImage, and a filled one, or one with no variant,
        // gives both, which is right for the state it is shown in. The item keeps the names it was drawn from, so it
        // is drawn again only when the view holds an icon outside them: a filled icon whose outline drew the item
        // changes nothing. Tabs of the mod's own have no Encore icon and are drawn once.
        UIView *live = iconIn(sources[i]);
        id icon = live ? encoreIconOf(live) : nil;
        NSString *name = iconName(icon);
        if (!item.image || !item.selectedImage || (name && ![objc_getAssociatedObject(item, &kGlyphNamesKey) containsObject:name])) {
            id lit = activeVariantOf(icon);
            setGlyphs(item, drawGlyph(live, icon, NO), drawGlyph(live, lit ?: icon, YES));
            NSString *litName = iconName(lit);
            if (item.image && item.selectedImage) objc_setAssociatedObject(item, &kGlyphNamesKey, name ? (litName ? @[name, litName] : @[name]) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        missing |= !item.image || !item.selectedImage;
        item.accessibilityLabel = labelIn(sources[i]).text;
        item.largeContentSizeImage = item.image;
        item.accessibilityHint = sg_minimized && bar == objc_getAssociatedObject(bar.stockBar, &kBarKey) ? @"Shows all tabs" : nil;
        NSString *title = hideLabels ? nil : labelIn(sources[i]).text;
        if (hideLabels ? item.title != nil : title.length && ![title isEqualToString:item.title]) item.title = title;
    }
    return missing;
}

// The bar holding the tab Spotify paints as selected selects it, and the other one lets go. With no tab
// painted (a tab of the mod's own, a repaint still to come) both keep what they have.
static void selectActive(SGRSystemTabBar *bar, UIView *active) {
    NSUInteger index = active ? [bar.sources indexOfObject:active] : NSNotFound;
    UITabBarItem *item = index == NSNotFound ? nil : bar.items[index];
    if (active && bar.selectedItem != item) bar.selectedItem = item;
    if (active && item) bar.shown = item;
}

// The tab a bar shows selected, when Spotify paints none: a tab of the mod's own.
static UIView *selectedSource(SGRSystemTabBar *bar) {
    NSUInteger index = bar.selectedItem ? [bar.items indexOfObject:bar.selectedItem] : NSNotFound;
    return index < bar.sources.count ? bar.sources[index] : nil;
}

// Split tabs stand on a glass bar of their own at the trailing end, the way the Music app sets Search
// apart. A standalone UITabBar has no way to set an item apart (iOS 27 SDK: only UITabBarController's
// UISearchTab does), so it is a second bar. UIKit draws each bar's platter 21 pt in from its sides
// (harness/tabbar, iPhone 17 Pro, iOS 27: a 72 pt bar got a 30 pt platter at x 21), so a split bar is
// a 62 pt platter, a circle as tall as the bar's, per tab plus those insets, and the main bar runs under
// its leading inset to leave 12 pt of glassless gap between the two platters.
static const CGFloat kPlatterInset = 21, kApartItemWidth = 62, kPlatterGap = 12;

static void syncBar(UIView *stockBar) {
    sg_stockBar = stockBar;

    SGRSystemTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) {
        bar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRTabBarHost *host = [SGRTabBarHost new];
        [host addSubview:bar];
        objc_setAssociatedObject(stockBar, &kHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);

    for (UIView *sub in stockBar.subviews) {
        if (sub == host || [sub isKindOfClass:SGRBarFade.class]) continue;
        sub.alpha = 0;
        sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    NSArray<UIView *> *sources = tabItems(stockBar);
    if (!sources.count) return;
    // An item with no title is drawn by UIKit as its glyph alone, centered, on a bar of the same height.
    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);
    SGRSystemTabBar *apartBar = objc_getAssociatedObject(stockBar, &kApartBarKey);
    UIView *active = SGRNavbarLitTab();
    if (![sources containsObject:active]) active = nil;
    for (UIView *source in sources) if (!active && isActive(source)) active = source;
    active = active ?: selectedSource(bar) ?: selectedSource(apartBar);

    NSMutableArray<UIView *> *main = [NSMutableArray array], *apart = [NSMutableArray array];
    for (UIView *source in sources) [(SGRTabIsApart(source) ? apart : main) addObject:source];
    if (!main.count) {
        main = [sources mutableCopy];
        [apart removeAllObjects];
    }
    // Minimized, the bar keeps the tab it is on, glyph only, on a circle at the leading end, and the last
    // split tab on one at the trailing end when there are any, the way the Music app keeps Search. Without
    // split tabs the now playing card has the rest of the row.
    BOOL minimized = sg_minimized && sources.count >= 2;
    if (minimized) {
        UIView *last = apart.lastObject;
        main = [NSMutableArray arrayWithObject:active && active != last ? active : main.firstObject];
        apart = last ? [NSMutableArray arrayWithObject:last] : [NSMutableArray array];
        hideLabels = YES;
    }
    if (apart.count && !apartBar) {
        apartBar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kApartBarKey, apartBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        apartBar.partner = bar;
        bar.partner = apartBar;
        [host addSubview:apartBar];
    }
    apartBar.hidden = !apart.count && !sg_keepApart;
    if (apartBar.hidden) apartBar.sources = nil;

    CGRect bounds = stockBar.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = MAX(bounds.size.height, glassHeight(bar, stockBar));
    CGRect frame = CGRectMake(0, CGRectGetMaxY(bounds) - height, width, height);
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
    placeFade(stockBar, frame, minimized);
    CGRect mainFrame = host.bounds, apartFrame = CGRectZero;
    if (minimized) {
        CGFloat side = kApartItemWidth + 2 * kPlatterInset;
        mainFrame.size.width = side;
        if (apart.count) apartFrame = CGRectMake(width - side, 0, side, height);
    } else if (apart.count) {
        CGFloat apartWidth = MIN(width / 2, apart.count * kApartItemWidth + 2 * kPlatterInset);
        CGRectDivide(host.bounds, &apartFrame, &mainFrame, apartWidth, CGRectMaxXEdge);
        mainFrame.size.width += 2 * kPlatterInset - kPlatterGap;
    }
    if (!CGRectEqualToRect(bar.frame, mainFrame)) bar.frame = mainFrame;
    if (apart.count && !CGRectEqualToRect(apartBar.frame, apartFrame)) apartBar.frame = apartFrame;

    // The items go in once the bars are laid out at their frames. UIKit sizes an item's title by the platter it
    // is made in and never again when the bar grows, so items made while a bar was still a circle kept "…" for
    // their names at full width (harness/tabbar, `names`).
    [host layoutIfNeeded];
    BOOL missing = fillBar(bar, main, hideLabels);
    if (apart.count) missing |= fillBar(apartBar, apart, hideLabels);
    selectActive(bar, active);
    if (apart.count) selectActive(apartBar, active);
    // An icon view Spotify has not built yet is looked for again shortly, not on the next touch.
    static NSUInteger retries;
    if (missing && retries++ < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncBar(stockBar);
        });
    }
    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];
    logBarOnce(bar);
    makeRoom(containerOf(stockBar));
}

#pragma mark - minimized

// A page scrolled down minimizes the bar (TabBarMinimize.x), the way the Music app's does. Spotify's tab bar
// container is a UIViewController of its own, not a UITabBarController (the binary's ObjC metadata), so
// UIKit's tabBarMinimizeBehavior and bottomAccessory have nothing to act on. The minimized bar is built
// from the two bars this file already has: the main bar narrowed to one circle at the leading end, the
// second bar to one at the trailing end, and the now playing card between them (NowPlayingBar.x). The
// bars get their new items and are laid out where they are going at once; then every view of theirs goes back
// to where it was and moves on one spring with the card (see "one move"); nothing fades a bar's glass.
BOOL SGRTabBarMinimized(void) {
    return sg_minimized;
}

static void setMinimized(BOOL minimized, BOOL animated);

// The scroll asks from inside -[UIScrollView setContentOffset:], which Spotify can call inside an animation of
// its own: a block, whose length the spring then took, or a property animator held part way, which kept the bar's
// and the card's moves at its fraction for good, the circle stopped half way along the row and the card half way
// down to it (harness/tabbar, `nested`). So an animated change asked for inside an animation is made on the main
// queue's next turn, outside it, and only if nothing was asked for since; one asked for outside any is made at
// once. A change with no animation stays at once too: the player's transition takes its pictures of the bars
// right after asking.
static NSUInteger sg_request;

void SGRSetTabBarMinimized(BOOL minimized, BOOL animated) {
    NSUInteger request = ++sg_request;
    if (!animated) {
        [UIView performWithoutAnimation:^{ setMinimized(minimized, NO); }];
        return;
    }
    if (UIView.areAnimationsEnabled && UIView.inheritedAnimationDuration <= 0) {
        setMinimized(minimized, YES);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (request == sg_request) setMinimized(minimized, YES);
    });
}

#pragma mark - one move

// The bars, the circles and the card move as one: on one spring (SGRMotionBar), from what is on screen. UIKit
// lays a bar's items out by its width, so a bar laid out where it was with its new items put them where they
// never were: minimizing, the circle's tab stood in the middle of the old full bar and slid to the leading end
// from there (harness/tabbar, `motion`: 124 pt in one frame). So each bar is laid out where it is going, and
// every view of the bars that was already there goes back to its frame from before, under its animations still
// running, and moves to its new one in the spring. UIView's animations add up, so a change that turns one back
// carries on from where the screen is, at the speed it had. UIKit takes the animations off its platters when it
// lays new items out, though, and a platter turned back half way then started from the old move's end, 62 pt from
// where it was shown (`motion`, four quick turns); one whose move was taken off starts from what was shown. The
// selected tab's new button starts with its glyph where the old one's was; the other new buttons fade in, and the
// buttons that went fade out from where they were.
typedef struct {
    NSMapTable<UIView *, NSArray<NSValue *> *> *frames; // every view of the host: its frame, the frame shown, moving
    NSMutableDictionary<NSString *, NSValue *> *glyphs; // the selected tab's glyph center in the host (buttonKey)
    NSMapTable<UIView *, UIView *> *buttons;            // each tab button, a picture of it
} SGRBarState;

// UIKit draws every tab twice, the second time in the accent under the selection's bubble only.
static BOOL isLitCopy(UIView *view, UIView *host) {
    for (UIView *up = view.superview; up && up != host; up = up.superview) {
        if ([NSStringFromClass(up.class) containsString:@"SelectedContent"]) return YES;
    }
    return NO;
}

static BOOL isMoving(UIView *view) {
    for (NSString *key in view.layer.animationKeys) if ([key hasPrefix:@"position"] || [key hasPrefix:@"bounds"]) return YES;
    return NO;
}

static UIImageView *glyphView(UIView *button) {
    __block UIImageView *glyph = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!glyph && [v isKindOfClass:UIImageView.class] && !v.hidden && ((UIImageView *)v).image) glyph = (UIImageView *)v;
    });
    return glyph;
}

static BOOL isTabButton(UIView *view) {
    return [view isKindOfClass:UIControl.class] && glyphView(view) != nil;
}

// Which old button a new one takes over from. UIKit draws its glyphs anew with each set of items (each copy a
// UIImage of its own), so the selected tab is what the two share, in each of the two copies.
static NSString *buttonKey(UIView *button, UIView *host) {
    if (!isTabButton(button) || !((UIControl *)button).selected) return nil;
    return isLitCopy(button, host) ? @"lit" : @"plain";
}

static CGRect shownIn(UIView *view, UIView *host) {
    CALayer *layer = view.layer.presentationLayer ?: view.layer, *top = host.layer.presentationLayer ?: host.layer;
    return [layer convertRect:layer.bounds toLayer:top];
}

static SGRBarState barState(UIView *host) {
    SGRBarState state = {
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
        [NSMutableDictionary dictionary],
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
    };
    SGForEachView(host, ^(UIView *v) {
        CALayer *shownLayer = v.layer.presentationLayer;
        [state.frames setObject:@[[NSValue valueWithCGRect:v.frame], [NSValue valueWithCGRect:shownLayer ? shownLayer.frame : v.frame], @(isMoving(v))] forKey:v];
        if (!v.window || v == host || !isTabButton(v)) return;
        CGRect shown = shownIn(v, host), glyph = shownIn(glyphView(v), host);
        NSString *key = buttonKey(v, host);
        if (key) state.glyphs[key] = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(glyph), CGRectGetMidY(glyph))];
        // The lit copy is left out, or its picture would show the tab lit outside the bubble.
        if (isLitCopy(v, host)) return;
        UIView *picture = [v snapshotViewAfterScreenUpdates:NO];
        if (picture) {
            picture.frame = shown;
            [state.buttons setObject:picture forKey:v];
        }
    });
    return state;
}

// Moves the host's views from `before` to where they are now, with `along` (the card) in the same spring.
static void moveFrom(UIView *host, SGRBarState before, void (^along)(void), void (^completion)(BOOL)) {
    NSMutableArray<UIView *> *moved = [NSMutableArray array], *faded = [NSMutableArray array];
    NSMutableArray<NSValue *> *starts = [NSMutableArray array], *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    SGForEachView(host, ^(UIView *v) {
        if (v == host) return;
        NSArray<NSValue *> *old = [before.frames objectForKey:v];
        if (old) {
            BOOL stopped = [(NSNumber *)old[2] boolValue] && !isMoving(v);
            CGRect start = stopped ? old[1].CGRectValue : old[0].CGRectValue;
            if (!stopped && CGRectEqualToRect(start, v.frame)) return;
            [moved addObject:v];
            [starts addObject:[NSValue valueWithCGRect:start]];
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            return;
        }
        // A view made for the new items, whose superview was there before. The selected tab's button starts where
        // the old one's glyph was, another fades in where it is going; the rest (the selection's bubble) are there
        // at once, or the selected tab's glyph, drawn under the bubble, went with it.
        if (![before.frames objectForKey:v.superview] || [v isKindOfClass:UITabBar.class]) return;
        NSString *key = buttonKey(v, host);
        NSValue *was = key ? before.glyphs[key] : nil;
        if (was) {
            [moved addObject:v];
            [starts addObject:was];   // a center in the host, placed once the views above it are back
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            [taken addObject:key];
        } else if (isTabButton(v) && v.alpha > 0.01) {
            [faded addObject:v];
        }
    });
    NSMutableArray<UIView *> *gone = [NSMutableArray array];
    for (UIView *button in before.buttons) {
        BOOL replaced = ((UIControl *)button).selected && [taken containsObject:@"plain"];
        if (!button.window && !replaced) [gone addObject:[before.buttons objectForKey:button]];
    }

    [UIView performWithoutAnimation:^{
        // Top down, so a button's center is placed in its platter where the platter starts.
        for (NSUInteger i = 0; i < moved.count; i++) {
            UIView *v = moved[i];
            if (strcmp(starts[i].objCType, @encode(CGPoint)) != 0) {
                v.frame = starts[i].CGRectValue;
                continue;
            }
            // Its glyph where the old one's was: the button moved by as much as its glyph is off its center.
            UIImageView *glyph = glyphView(v);
            CGPoint inButton = [v convertPoint:glyph.center fromView:glyph.superview], to = [host convertPoint:starts[i].CGPointValue toView:v.superview];
            v.center = CGPointMake(to.x - (inButton.x - CGRectGetMidX(v.bounds)), to.y - (inButton.y - CGRectGetMidY(v.bounds)));
        }
        for (UIView *v in faded) v.alpha = 0;
        for (UIView *picture in gone) [host addSubview:picture];
    }];
    SGRAnimate(SGRMotionBar, ^{
        for (NSUInteger i = 0; i < moved.count; i++) moved[i].frame = targets[i].CGRectValue;
        if (along) along();
    }, completion);
    // The buttons that went leave quickly, and those that came arrive as the platter reaches them.
    SGRAnimate(SGRMotionExit, ^{ for (UIView *picture in gone) picture.alpha = 0; }, ^(BOOL finished) {
        for (UIView *picture in gone) [picture removeFromSuperview];
    });
    SGRAnimate(SGRMotionFade, ^{ for (UIView *v in faded) v.alpha = 1; }, nil);
}

static void setMinimized(BOOL minimized, BOOL animated) {
    UIView *stockBar = sg_stockBar;
    if (minimized == sg_minimized) return;
    // Spotify's regular width bar is not the glass one's row of tabs; it stays as it is.
    if (minimized && (!stockBar.window || stockBar.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact)) return;
    sg_minimized = minimized;
    sg_keepApart = !minimized;
    SGLog(@"tab bar: %@", minimized ? @"minimized" : @"expanded");
    if (!stockBar) return;
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    void (^settle)(BOOL) = ^(BOOL finished) {
        if (sg_minimized != minimized) return;
        sg_keepApart = NO;
        syncBar(stockBar);
    };
    animated &= host.window != nil;
    SGRBarState before = animated ? barState(host) : (SGRBarState){0};
    // The items are made where the bars are going, before anything moves. UIKit sizes a tab's name by the platter
    // its item is made in and never again, and the first pass made the expanding row's items while the bar still
    // held the circle's one item, its platter a circle: "Your Library" stayed cut. So they are made a second time,
    // the platters now the full row's, and the names are whole all the way.
    [UIView performWithoutAnimation:^{
        syncBar(stockBar);
        [host layoutIfNeeded];
        if (!minimized) {
            ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kBarKey)).sources = nil;
            ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kApartBarKey)).sources = nil;
            syncBar(stockBar);
            [host layoutIfNeeded];
        }
        if (!animated) SGRNowPlayingBarFollowTabBar();
    }];
    if (!animated) {
        settle(YES);
        return;
    }
    SGRNowPlayingBarMoving(YES);
    moveFrom(host, before, ^{ SGRNowPlayingBarFollowTabBar(); }, ^(BOOL finished) {
        SGRNowPlayingBarMoving(NO);
        settle(finished);
    });
}

CGRect SGRTabBarInlineSlot(UIView *host, CGFloat height) {
    UIView *stockBar = sg_stockBar;
    UIView *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    UIView *apartBar = stockBar ? objc_getAssociatedObject(stockBar, &kApartBarKey) : nil;
    if (!sg_minimized || !host || !bar.window || stockBar.hidden || stockBar.alpha < 0.01) return CGRectNull;
    // The frames the bars are going to, not what is on screen mid-spring. Without a split tab's circle the
    // card runs to where the trailing circle's glass would end.
    CGRect lead = [bar.superview convertRect:bar.frame toView:host];
    CGFloat left = CGRectGetMinX(lead) + kPlatterInset + kApartItemWidth + SGRGrid;
    CGFloat right;
    if (apartBar && !apartBar.hidden) {
        CGRect trail = [apartBar.superview convertRect:apartBar.frame toView:host];
        right = CGRectGetMaxX(trail) - kPlatterInset - kApartItemWidth - SGRGrid;
    } else {
        CGRect whole = [stockBar convertRect:stockBar.bounds toView:host];
        right = CGRectGetMaxX(whole) - kPlatterInset;
    }
    CGFloat middle = CGRectGetMinY(lead) + kApartItemWidth / 2;
    CGRect slot = CGRectMake(left, middle - height / 2, right - left, height);
    // A bar Spotify has slid away for a page takes the slot off the screen with it.
    CGRect inWindow = [host convertRect:slot toView:nil];
    if (slot.size.width < 100 || CGRectGetMaxY(inWindow) > CGRectGetMaxY(bar.window.bounds)) return CGRectNull;
    return slot;
}

#pragma mark - hooks

static UIView *tabBarOf(UIView *item) {
    Class barClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl10TabBarView");
    for (UIView *v = item.superview; v; v = v.superview) if ([v isKindOfClass:barClass]) return v;
    return nil;
}

// The bar in its own pass, and whether one of its items laid out during it.
static __weak UIView *sg_passBar;
static BOOL sg_itemsLaidOut;

%hook _TtC23NavigationUI_TabBarImpl10TabBarView
- (void)layoutSubviews {
    // A pass nested in another (an item's layoutIfNeeded) hands both back, so the outer one still composes.
    UIView *bar = (UIView *)self, *outer = sg_passBar;
    BOOL outerLaidOut = sg_itemsLaidOut;
    sg_passBar = bar;
    %orig;
    SGRComposeTabBar(bar);
    sg_itemsLaidOut = NO;
    for (UIView *sub in bar.subviews) {
        if (![sub isKindOfClass:SGRTabBarHost.class] && ![sub isKindOfClass:SGRBarFade.class]) [sub layoutIfNeeded];
    }
    // Items the row's pass laid out are composed once, all together, rather than once each.
    if (sg_itemsLaidOut) SGRComposeTabBar(bar);
    sg_passBar = outer;
    sg_itemsLaidOut = outerLaidOut;
    holdHome(bar);
    syncBar(bar);
    SGRLogTabBarRow(bar);
}
%end

// The bar's own pass runs before Spotify has filled the row; the items lay out as they arrive. Inside the bar's
// pass, the pass composes once after them; outside it, the item composes at once, so no frame shows Spotify's row.
static void itemDidLayOut(UIView *item) {
    UIView *bar = tabBarOf(item);
    if (!bar) return;
    if (bar == sg_passBar) {
        sg_itemsLaidOut = YES;
        return;
    }
    SGRComposeTabBar(bar);
    holdHome(bar);
    syncBar(bar);
    SGRLogTabBarRow(bar);
}

%hook _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

// A tab changed from elsewhere (a link, the side drawer) repaints the labels without a layout pass.
%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Another tab brings the minimized bar back (HIG, Tab bars).
        SGRSetTabBarMinimized(NO, YES);
        UIView *bar = sg_stockBar;
        if (bar) syncBar(bar);
    });
}
// The message bar coming or going changes the view's safe area before Spotify lays the bar out for it,
// so the room follows in that same pass, and inside the message bar's animation.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
}
%end

// Spotify's own fade under its bar, 219 pt down to black from 9.1.90 (TabBarGradientView), stacked with SGRBarFade
// into a band near black over the page's foot. SGRBarFade is the redesign's, so Spotify's stays clear.
%group SpotifyBarFade
%hook _TtC23NavigationUI_TabBarImpl18TabBarGradientView
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).alpha = 0;
}
- (void)setAlpha:(CGFloat)alpha {
    %orig(0);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (objc_getClass("_TtC23NavigationUI_TabBarImpl18TabBarGradientView")) %init(SpotifyBarFade);
    SGRequireClasses(@[
        @"_TtC23NavigationUI_TabBarImpl10TabBarView",
        @"_TtC23NavigationUI_TabBarImpl21TabBarItemElementView",
        @"_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView",
        @"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl",
    ]);
}
