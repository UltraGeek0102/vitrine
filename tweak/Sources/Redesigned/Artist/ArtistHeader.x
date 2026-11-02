// Artist redesign: the header the playlist and album pages have. The photo runs full bleed across the top
// of the page and dissolves into the page's field, stretching when the page is pulled down (the Kit's
// SGRStretchHero); the name and the monthly listeners are centered on the bottom of that dissolve; and under
// them one row -- shuffle, a white Play capsule, and Follow.
//
// Tree (trees/clean/artist/01.txt:37-170). The header is TemplateKit's HeaderContainer, 568pt, the first view
// of the page's stack, holding an element view that holds the ImageHeaderView:
//
//     UIView 402x424 clips                    the photo (Components.Header.UI.ArtworkImage) and a gradient
//     UIView {16, 334}                        the name, Encore.AdaptiveTitle, 45pt
//     ImageHeaderView.VerifiedBadge           "Verified by Spotify"
//     Components.Header.UI.Metadata           "58,4M monthly listeners"
//     UIStackView {4, 456} 394x48             explore, Follow (Curation.FollowButtonElementKit.FollowButton,
//                                             a text button), more, Components.UI.ShuffleButton, and
//                                             header-play-button
//     UIStackView {0, 504} 402x64             Components.UI.ArtistHeadline, "Pre-save the upcoming album"
//     HeaderForegroundView                    the 100pt navigation bar with the name, shown collapsed
//
// Scrolled (02.txt:26-30), the container keeps its 568pt and scrolls away with the page, while the element
// view slides down inside it and the ImageHeaderView shrinks to the 100pt bar, pinned at the top of the
// screen. So the photo and the redesign's text are the container's, not the ImageHeaderView's: in the header
// view they would be pinned at the top with it. The bar stays Spotify's, drawing the name once the page is
// scrolled, with its gradient masked out as the album's is.
//
// Everything else of the ImageHeaderView is drawn by nothing (an empty mask) and takes no touches: the badge,
// Explore, and the headline go with it -- the headline's pre-save is also the list's own Release Countdown
// section. The Kit's SGRHeaderInfo reads the name and the listeners off Spotify's concealed labels and draws
// and fires Spotify's shuffle, play and Follow, Follow as a glyph from the collection (ArtistFollow.x). More stays in Spotify's row, where the row needs it (ArtistField.x), and the Kit's pinned ⋯
// (SGRPinnedMore) draws and fires it from the top trailing corner of the page, level with the back button.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Redesigned/Album/Album.h"
#import "Artist.h"

// The dissolve and the scrim are the Kit's stretching hero's (SGRStretchHero.h), the playlist's and the album's.
// A photo view narrower than this is a placeholder glyph, and a picture shorter than this one mid load.
static const CGFloat kMinCover = 80, kMinHero = 120;
// The collapsed ImageHeaderView, Spotify's navigation bar; the text fades out over the last kFade before it.
static const CGFloat kBar = 100, kFade = 150;

static char kInfoKey, kHeroKey, kHeroHeightKey, kContainerHeightKey, kRowWatchedKey, kSizeKey;
static char kTitleKey, kMetaKey, kShuffleKey, kPlayKey, kFollowKey, kArtworkKey, kBarKey, kMoreKey, kMoreButtonKey;

#pragma mark - Spotify's views

// Drawn by nothing and out of the way of touches, whatever Spotify does to it: an empty mask. Not hidden --
// the header's OverflowStackView traps when a view in it hides, and a hidden view is one the redesign still
// has to read and fire.
static void blank(UIView *view) {
    if (!view) return;
    if (!view.layer.mask) view.layer.mask = [CALayer layer];
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static void setFrame(UIView *view, CGRect frame) {
    if (view && !CGRectIsEmpty(frame) && !CGRectEqualToRect(view.frame, frame)) view.frame = frame;
}

static NSString *trimmed(NSString *text) {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? clean : nil;
}

static char kLogoNameKey;

// Apple Music's logo for the artist in place of the name, where Apple Music has one. Asked once per name;
// the catalog remembers the answer for the launch.
static void showLogo(SGRHeaderInfo *info, NSString *name) {
    if (!name.length || !SGEnabled(SGRKeyArtistLogo) || [objc_getAssociatedObject(info, &kLogoNameKey) isEqualToString:name]) return;
    objc_setAssociatedObject(info, &kLogoNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak SGRHeaderInfo *weakInfo = info;
    CGFloat pixels = UIScreen.mainScreen.bounds.size.width * UIScreen.mainScreen.scale;
    SGMotionArtistLogo(name, pixels, ^(UIImage *logo) {
        SGRHeaderInfo *shown = weakInfo;
        if (!shown || ![objc_getAssociatedObject(shown, &kLogoNameKey) isEqualToString:name]) return;
        [shown showTitleImage:logo];
        if (logo) SGLog(@"redesign artist: Apple Music's logo for %@", name);
    });
}

static NSString *firstText(UIView *root) {
    __block NSString *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (found || ![v isKindOfClass:UILabel.class]) return;
        found = trimmed(((UILabel *)v).text);
    });
    return found;
}

// The TemplateKit container the header sits in, which scrolls with the page.
static UIView *containerOf(UIView *header) {
    for (UIView *v = header.superview; v; v = v.superview) {
        if ([NSStringFromClass(v.class) containsString:@"HeaderContainer"]) return v;
    }
    return nil;
}

#pragma mark - the photo, full bleed

// The picture across the top of the page with the field showing through the bottom of it: the Kit's stretching
// hero (SGRStretchHero.h), whose bottom is masked away as the playlist's and the album's are, under a scrim for
// the status bar. Pulled down past the top, it grows upward by as much, so the photo stays one piece with the
// name and the list under it and zooms in, as the Music app's does, rather than sliding down and leaving the
// field showing above it (issue #169). The photo fills the hero's content, so a pull only resizes it.
@interface SGRArtistHero : SGRStretchHero
@property (nonatomic, readonly) UIImageView *picture;
// The photo in Spotify's artwork view, and every photo it puts there afterward: the hero keeps itself
// right, rather than being handed a picture on each of the header's passes and staying empty between them.
// The same view again only re-reads it.
- (void)followArtwork:(UIImageView *)source;
@end

@implementation SGRArtistHero {
    __weak UIImageView *_artwork;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.logName = @"artist";
    _picture = [[UIImageView alloc] initWithFrame:self.bounds];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.content addSubview:_picture];
    return self;
}

- (void)followArtwork:(UIImageView *)source {
    if (!source) return;
    [self takeArtwork:source late:NO];
    if (_artwork == source) return;
    _artwork = source;
    __weak SGRArtistHero *weakSelf = self;
    SGRObserveImage(source, ^(UIImageView *view) { [weakSelf takeArtwork:view late:YES]; });
}

// `late` is a photo that arrived after the header had laid out -- the artist opened for the first time,
// whose picture is still being fetched while the page is already on screen (issue #52). The log line says
// once that the watch, and not one of the header's passes, is what filled the hero.
- (void)takeArtwork:(UIImageView *)source late:(BOOL)late {
    UIImage *image = source.image;
    if (!image || _picture.image == image) return;
    _picture.image = image;
    // The page's field takes its color from the same picture.
    SGRArtistSetArtwork(self, image);
    static BOOL logged;
    if (late && !logged) {
        logged = YES;
        SGLog(@"redesign artist: the photo landed after the header had laid out; the hero took it");
    }
}

@end

// The image view of Spotify's artwork: the one with the photo in it, or, before the photo has been fetched,
// the empty one it will land in, so it can be watched from the first pass. Either way one the size of the
// picture, never a small placeholder glyph beside it.
static UIImageView *photoIn(UIView *artwork) {
    __block UIImageView *found = nil, *empty = nil;
    SGForEachView(artwork, ^(UIView *v) {
        if (found || ![v isKindOfClass:UIImageView.class]) return;
        UIImageView *image = (UIImageView *)v;
        if (image.bounds.size.width < kMinCover) return;
        if (image.image) found = image;
        else if (!empty) empty = image;
    });
    return found ?: empty;
}

// The picture from the top of the container down to `bottom`, which comes from the container at rest and only
// ever grows, so it does not change size while the page loads or scrolls.
static void applyHero(UIView *container, UIView *artwork, CGFloat bottom) {
    SGRArtistHero *hero = objc_getAssociatedObject(container, &kHeroKey);
    if (!hero) {
        hero = [[SGRArtistHero alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(container, &kHeroKey, hero, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.superview != container) [container insertSubview:hero atIndex:0];
    else if (container.subviews.firstObject != hero) [container sendSubviewToBack:hero];

    CGFloat height = [objc_getAssociatedObject(hero, &kHeroHeightKey) doubleValue];
    if (bottom > height + 0.5) {
        height = round(bottom);
        objc_setAssociatedObject(hero, &kHeroHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign artist: hero %.0fpt across the top of the page", height);
    }
    if (height < kMinHero) return;
    hero.restHeight = height;
    [hero sgr_place];
    [hero followArtwork:photoIn(artwork)];
}

#pragma mark - the header's pass

static void applyHeader(UIView *header, BOOL full);
static void applyContent(UIView *header, UIView *container, SGRHeaderInfo *info, NSString *name, UIView *listeners, UIColor *fieldColor);

// Spotify's navigation bar, the one part of the header kept: collapsed, it is where the name is. Its gradient
// is a flat dark band over the field, as the album's was (Album/AlbumHeader.x); the soft top edge every
// redesigned page has keeps the name legible instead.
static UIView *keepBar(UIView *header) {
    UIView *foreground = nil;
    for (UIView *sub in header.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"HeaderForegroundView"]) foreground = sub;
    }
    if (foreground && !objc_getAssociatedObject(header, &kBarKey)) {
        SGForEachView(foreground, ^(UIView *v) {
            if ([NSStringFromClass(v.class) containsString:@"GradientView"] && !v.layer.mask) v.layer.mask = [CALayer layer];
        });
        objc_setAssociatedObject(header, &kBarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return foreground;
}

// `full` NO is the header's own pass: a step of the collapse (its height changed, its width did not) then only
// moves and fades, unless the name or the listeners changed; any other pass and the row's take everything again.
static void applyHeader(UIView *header, BOOL full) {
    CGSize size = header.bounds.size;
    NSValue *last = objc_getAssociatedObject(header, &kSizeKey);
    if (!full) full = !last || last.CGSizeValue.width != size.width || last.CGSizeValue.height == size.height;
    UIView *container = containerOf(header);
    UIView *artwork = SGRFindByIdentifier(header, @"Components.Header.UI.ArtworkImage", &kArtworkKey);
    if (!container || !artwork || !SGRArtistPageOf(container)) return;
    objc_setAssociatedObject(header, &kSizeKey, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *bar = keepBar(header);
    for (UIView *sub in header.subviews) {
        if (sub != bar) blank(sub);
    }

    SGRHeaderInfo *info = objc_getAssociatedObject(container, &kInfoKey);
    if (!info) {
        info = [[SGRHeaderInfo alloc] initWithFrame:CGRectZero];
        // Follow's only state is its title in the app's language, so the glyph takes it from the collection.
        __weak UIView *weakPage = SGRArtistPageOf(container);
        __weak SGRHeaderInfo *weakInfo = info;
        __weak UIView *weakHeader = header;
        info.trailingState = ^BOOL(BOOL *on) {
            UIView *more = SGRFindByIdentifier(weakHeader, @"Components.UI.ContextMenuButton*", &kMoreKey);
            return SGRArtistFollowing(weakPage, more.accessibilityIdentifier, on, ^{ [weakInfo trailingStateChanged]; });
        };
        info.trailingOffSymbol = @"person.badge.plus";
        info.trailingOnSymbol = @"person.fill.checkmark";
        objc_setAssociatedObject(container, &kInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (info.superview != container) [container addSubview:info];
    setFrame(info, container.bounds);

    UIView *title = SGRFindByIdentifier(header, @"Encore.AdaptiveTitle", &kTitleKey);
    UIView *listeners = SGRFindByIdentifier(header, @"Components.Header.UI.Metadata", &kMetaKey);
    NSString *name = firstText(title) ?: firstText(bar);
    full |= [info showTitle:name creator:nil length:firstText(listeners) about:nil];
    // Play's glyph and word are drawn in the field's color, which lands whenever the photo's has been read.
    UIColor *fieldColor = SGRArtistFieldColor(container);
    full |= ![fieldColor isEqual:info.handedPlayColor];
    // Until the buttons' row is found and watched, every pass looks for it: it can arrive after the last full one.
    full |= !info.rowFound;
    if (full) {
        info.handedPlayColor = fieldColor;
        applyContent(header, container, info, name, listeners, fieldColor);
    }

    // Collapsing, the text would pass over Spotify's bar with the name in it: it goes over the last kFade of
    // the collapse, from the header's own height, which this pass runs on every step of. More stays: it is
    // outside the header and has nothing to pass over.
    CGFloat alpha = MAX(0, MIN(1, (header.bounds.size.height - kBar) / kFade));
    if (fabs(info.alpha - alpha) > 0.01) info.alpha = alpha;

    // The picture reaches to where the content's top is at rest, plus the name. The container keeps its
    // height as the header collapses, and only ever grows as the page loads. Not while the page is pulled down
    // past its top: should Spotify grow the container with the pull, that height is not the rest, and the hero
    // would stay that much too tall once the page is let go.
    CGFloat rest = [objc_getAssociatedObject(container, &kContainerHeightKey) doubleValue];
    SGRArtistHero *hero = objc_getAssociatedObject(container, &kHeroKey);
    if (container.bounds.size.height > rest && hero.pull <= 0) {
        rest = container.bounds.size.height;
        objc_setAssociatedObject(container, &kContainerHeightKey, @(rest), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat bottom = rest - SGRHeaderInfoBottom - [info contentHeightForWidth:container.bounds.size.width] + SGRHeaderInfoTitleRise;
    applyHero(container, artwork, bottom);
}

// What the header shows besides its text: the logo, the buttons, More, and the watch on the buttons' row.
static void applyContent(UIView *header, UIView *container, SGRHeaderInfo *info, NSString *name, UIView *listeners, UIColor *fieldColor) {
    showLogo(info, name);

    UIView *shuffle = SGRFindByIdentifier(header, @"Components.UI.ShuffleButton", &kShuffleKey);
    UIView *play = SGRFindByIdentifier(header, @"header-play-button", &kPlayKey);
    UIView *follow = SGRFindByIdentifier(header, @"Curation.FollowButtonElementKit.FollowButton", &kFollowKey);
    [info showShuffle:shuffle play:play trailing:follow trailingFallback:nil playColor:fieldColor];

    // More, in the top trailing corner of the page itself rather than of the container, which scrolls away
    // with the photo: pinned there it is the same button in the same place on the album and the playlist,
    // and the page keeps it however far down the list one is (issue #57).
    UIView *more = SGRFindByIdentifier(header, @"Components.UI.ContextMenuButton*", &kMoreKey);
    SGRPinnedMore(SGRArtistPageOf(container), &kMoreButtonKey, more);

    // The buttons arrive after the header has laid out, in a row that keeps its size and so lays nothing out
    // again (Native/Artist/Artist.x): the row's own pass is watched, a plain UIStackView.
    UIView *row = shuffle ?: play ?: follow;
    while (row && row.superview != header) row = row.superview;
    if (row && [row class] == UIStackView.class && !objc_getAssociatedObject(row, &kRowWatchedKey)) {
        objc_setAssociatedObject(row, &kRowWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakHeader = header;
        SGRObserveLayout(row, ^(UIView *view) {
            if (weakHeader) applyHeader(weakHeader, YES);
        });
    }
    if (row && objc_getAssociatedObject(row, &kRowWatchedKey)) info.rowFound = YES;

    static BOOL logged;
    if (!logged && header.window && name) {
        logged = YES;
        SGLog(@"redesign artist: own block \"%@\", \"%@\"; shuffle %@, play %@, follow %@, more %@", name,
              firstText(listeners) ?: @"no listeners", shuffle ? @"found" : @"missing", play ? @"found" : @"missing",
              follow ? @"found" : @"missing", more ? @"found" : @"missing");
    }
}

// Scrolled, Spotify fades UIKit's navigation bar in over the artist page with an opaque black background
// (SPNavigationBar's _UIBarBackground, 116pt), where the album's own bar lets the page's field show through
// (issue #28). The page's item gets the same bar with no background, again whenever Spotify sets its own.
static void clearNavigationBar(UIView *header) {
    static char kClearKey;
    UIResponder *responder = header;
    while (responder && !([responder isKindOfClass:UIViewController.class]
                          && [((UIViewController *)responder).parentViewController isKindOfClass:UINavigationController.class]))
        responder = responder.nextResponder;
    UIViewController *page = (UIViewController *)responder;
    if (!page) return;
    UINavigationItem *item = page.navigationItem;
    UINavigationBarAppearance *clear = objc_getAssociatedObject(page, &kClearKey);
    if (clear && item.standardAppearance == clear && item.scrollEdgeAppearance == clear) return;
    if (!clear) {
        clear = [page.navigationController.navigationBar.standardAppearance copy] ?: [UINavigationBarAppearance new];
        [clear configureWithTransparentBackground];
        objc_setAssociatedObject(page, &kClearKey, clear, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    item.standardAppearance = clear;
    item.scrollEdgeAppearance = clear;
    item.compactAppearance = clear;
    item.compactScrollEdgeAppearance = clear;
}

%hook _TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView
- (void)layoutSubviews {
    %orig;
    applyHeader((UIView *)self, NO);
    clearNavigationBar((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC35CreativeWorkPlatform_ImageHeaderKit15ImageHeaderView"]);
}
