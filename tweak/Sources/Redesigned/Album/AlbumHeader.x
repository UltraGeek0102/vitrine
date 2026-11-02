// Album redesign: the header the Music app gives an album (iOS 26.4), the same one the playlist redesign
// gives a playlist. The cover runs full bleed across the top of the page and dissolves into the page's
// field, stretching when the page is pulled down (the Kit's SGRStretchHero); the title, the artist and the
// kind and date are centered on the bottom of that dissolve; and under them one row -- shuffle, a white Play
// capsule, and add.
//
// Tree (trees/clean/album/01.txt:39-152). The header is one element of the page's scrolling stack,
// id=CreativeWorkPlatform.Components.UI.CreativeWorkHeader, a plain UIView whose height the element framework
// measures from what it holds, down a chain of four stack views:
//
//     UIView {0, 78}                     the top inset, the status bar and the navigation bar's room
//       UIStackView                      the two groups
//         UIView 402x321                 the top group: the cover square, a spacer, and the title block --
//                                        TitleRow, and ParentRow, the artist with a facepile
//         UIView {0, 329} 402x71         the bottom group: Components.UI.MetadataRow (the kind and the date,
//                                        cells of a collection view) and the action row
//
// What the header shows is the redesign's own (the Kit's SGRHeaderInfo), not Spotify's rearranged: moving
// Spotify's stacks meant answering every pass of theirs, and the element framework measured the title for
// its own font. So Spotify's whole column is concealed and the Kit's view is drawn over the header in its
// place, reading its text off Spotify's concealed labels -- so it is in the app's language and follows
// whatever Spotify shows -- and drawing and firing Spotify's own controls. The header keeps its height, its
// fade as the page scrolls and its place in the stack.
//
// Play and shuffle are not in the header. The album page floats them over the page, pinned to the top
// trailing corner outside the scroll (01.txt:1431, :1436): they are concealed where they are, and the row
// draws them and fires them all the same.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Album.h"

// The dissolve and the scrim are the Kit's stretching hero's (SGRStretchHero.h), the playlist's numbers.
// A header whose text begins nearer the top than this is one mid load, not one to measure the hero from;
// and an artwork view narrower than this is a placeholder glyph rather than the cover.
static const CGFloat kMinHero = 120, kMinCover = 80;
// The square cover's corners with Full bleed covers off: Spotify's own (its ImageViewHolder, r=4), so the album's
// square is the playlist's, which is Spotify's square left in place.
static const CGFloat kSquareRadius = 4;

static char kHeaderKey, kCoverKey, kTitleKey, kParentKey, kMetaKey, kAddKey, kDownloadKey, kPlayKey, kShuffleKey;
static char kHeroKey, kHeroHeightKey, kHeaderHeightKey, kInfoKey, kHeaderWatchedKey, kRetryKey;
static char kExploreKey, kRowWatchedKey, kMoreKey, kPinnedMoreKey;

#pragma mark - moving Spotify's views

// Invisible for good. Spotify fades the header and the two floating controls by alpha as the page scrolls,
// so a redesign that answers with alpha is in a fight it loses a frame of on every scroll. `hidden` on the
// layer cannot be undone by a write to alpha, costs nothing per frame, and, unlike -[UIView setHidden:],
// tells neither KVO nor the stack views of it, which is what makes it safe on Spotify's Encore layouts; an
// empty mask holds when Spotify shows the view again with -setHidden:NO, which the playlist page does when
// Play is pressed (Playlist/PlaylistHeader.x).
static void conceal(UIView *view) {
    if (!view) return;
    if (!view.layer.hidden) view.layer.hidden = YES;
    if (!view.layer.mask) view.layer.mask = [CALayer layer];
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

// Drawn by nothing but not hidden: for Spotify's own column of the header, which the redesign still reads. A
// hidden collection view makes no cells, and the kind and the date are cells ("no metadata" in the harness
// with the column hidden, 2026-09-18), so the column keeps laying itself out and only its drawing goes.
static void blank(UIView *view) {
    if (!view) return;
    if (!view.layer.mask) view.layer.mask = [CALayer layer];
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

// The outermost view that still wraps the control exactly: the element view Spotify's layout places, so
// concealing it leaves the control itself alone to be read and fired.
static UIView *wrapperFor(UIView *control, UIView *stop) {
    UIView *wrapper = control;
    for (UIView *v = control.superview; v && v != stop; v = v.superview) {
        if (fabs(v.bounds.size.width - control.bounds.size.width) > 4) break;
        if (fabs(v.bounds.size.height - control.bounds.size.height) > 4) break;
        wrapper = v;
    }
    return wrapper;
}

// One of the two controls Spotify floats over the page. They are direct children of the page and 48pt
// across, so only the small children are searched: the wash, the tab and the navigation bar are the width
// of the page, and walking into the tab would be walking the whole list on every pass that missed.
static UIView *floatingIn(UIView *page, NSString *identifier, const void *cacheKey) {
    for (UIView *sub in page.subviews) {
        if (sub.bounds.size.width > 120) continue;
        UIView *found = SGRFindByIdentifier(sub, identifier, cacheKey);
        if (found) return found;
    }
    return nil;
}

static void setFrame(UIView *view, CGRect frame) {
    if (view && !CGRectIsEmpty(frame) && !CGRectEqualToRect(view.frame, frame)) view.frame = frame;
}

// The stack Spotify arranges the header's buttons in: the first one above `button`.
static UIView *rowOf(UIView *button, UIView *header) {
    for (UIView *v = button.superview; v && v != header; v = v.superview) {
        if ([v isKindOfClass:UIStackView.class]) return v;
    }
    return nil;
}

// Installs `laidOut` on the view's own pass once, under `key`.
static void watch(UIView *view, const void *key, void (^laidOut)(UIView *view)) {
    if (!view || objc_getAssociatedObject(view, key)) return;
    objc_setAssociatedObject(view, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRObserveLayout(view, laidOut);
}

#pragma mark - the cover, full bleed

// The picture across the top of the page with the field showing through the bottom of it: the Kit's stretching
// hero (SGRStretchHero.h), whose bottom is masked away as the playlist's is, under a scrim for the status bar.
// Pulled down past the top, it grows upward by as much, so the picture stays one piece with the text and the
// list under it and zooms in, as the Music app's does, rather than sliding down and leaving the field showing
// above it (issue #169).
//
// Here the hero adds the cover square with Full bleed covers off, its shadow, and Apple Music's animated cover,
// which goes in the hero's masked content over the picture and so dissolves with it.
@interface SGRAlbumHero : SGRStretchHero
@property (nonatomic, readonly) UIImageView *picture;
// Where Spotify lays its cover square out, in the hero's coordinates at rest. With Full bleed covers off the
// picture is drawn there instead, on the field with no scrim and no mask, until an animated cover fills the
// hero over it.
@property (nonatomic) CGRect square;
// The cover in Spotify's artwork view, and every cover it puts there afterward: the hero keeps itself
// right, rather than being handed a picture on each of the header's passes and staying empty between them.
- (void)followCover:(UIImageView *)source;
// Apple Music's animated cover over the picture, where the album has one. The same album again is a no-op.
- (void)playMotionForArtist:(NSString *)artist album:(NSString *)album;
// The square's shadow, copied off whichever layer under Spotify's concealed cover casts one (its ShadowContainer),
// so the album's square has the shadow the playlist's -- Spotify's own square -- does. Once found, a no-op.
- (void)takeShadowFrom:(UIView *)cover;
@end

@implementation SGRAlbumHero {
    CALayer *_shadow;   // under the square, which clips and so cannot cast its own; beside the masked content
    __weak UIImageView *_cover;
    UIView *_extension;   // iOS 26's UIBackgroundExtensionView around the picture, nil before it
    NSString *_motionAlbum;
    AVPlayerLayer *_motion;
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    BOOL _motionOn;   // what the player was last asked, so a scroll's steps ask it nothing again
    BOOL _motionSeen; // whether the hero was on screen when the player was last asked
}

static void *kReadyContext = &kReadyContext;

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.logName = @"album";

    _picture = [[UIImageView alloc] initWithFrame:self.bounds];
    _picture.contentMode = UIViewContentModeScaleAspectFill;
    _picture.clipsToBounds = YES;
    // The cover is square and the hero runs a little taller, so a fill cut its sides: a title set edge to
    // edge on the cover lost its ends. On iOS 26 the cover stays whole at the top and the system carries its
    // bottom edge down the rest, as the Music app's album page does; before, it fills as it always did.
    Class extension = NSClassFromString(@"UIBackgroundExtensionView");
    if (extension) {
        _extension = [[extension alloc] initWithFrame:self.bounds];
        [_extension setValue:@NO forKey:@"automaticallyPlacesContentView"];
        [_extension setValue:_picture forKey:@"contentView"];
        [self.content addSubview:_extension];
    } else {
        _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.content addSubview:_picture];
    }

    // At the bottom, under the content's layer.
    _shadow = [CALayer layer];
    _shadow.hidden = YES;
    [self.layer insertSublayer:_shadow atIndex:0];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification,
                                      UIAccessibilityVideoAutoplayStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(sgr_updateMotionSoon) name:name object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self sgr_dropMotion];
}

- (void)setSquare:(CGRect)square {
    if (CGRectEqualToRect(_square, square)) return;
    _square = square;
    // A path, so the shadow is drawn from it rather than from an offscreen pass over the layer every frame. In the
    // layer's own coordinates, so it holds wherever -layoutSubviews puts the layer.
    _shadow.shadowPath = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, square.size} cornerRadius:kSquareRadius].CGPath;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    // A square cover's mask follows whether a clip covers the whole hero: the square itself reaches into the
    // dissolve, so only a clip is masked. Set before the Kit lays the content out, so both land in one pass.
    BOOL full = SGRFullBleedCovers(), bleeds = _motion.opacity == 1;
    self.dissolves = full || bleeds;
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    if (bounds.size.height < 1) return;
    // Pulled down, the hero is `stretch` taller than at rest and as much higher in the header, so what sits on
    // the content -- the square, the picture's bottom -- is placed from the rest height and moved down by the
    // stretch, and the picture over it grows by the same.
    CGFloat stretch = self.stretch, rest = bounds.size.height - stretch;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (full) {
        if (_extension) {
            _extension.frame = bounds;
            // Scaled about its middle by as much as its bottom moves down: zoomed in, never cut off.
            CGFloat side = MIN(bounds.size.width, rest), width = bounds.size.width * (side + stretch) / side;
            _picture.frame = CGRectMake((bounds.size.width - width) / 2, 0, width, side + stretch);
        }
    } else {
        // Stays square under an animated cover too: the clip covers the whole hero, so nothing moves under its fade.
        CGRect square = CGRectOffset(_square, 0, stretch);
        UIView *holder = _extension ?: _picture;
        holder.frame = square;
        holder.layer.cornerRadius = kSquareRadius;
        holder.layer.cornerCurve = kCACornerCurveContinuous;
        holder.clipsToBounds = YES;
        if (_extension) _picture.frame = _extension.bounds;
        _shadow.frame = square;
        _shadow.hidden = bleeds;
        self.scrim.hidden = !bleeds;
    }
    _motion.frame = bounds;
    [CATransaction commit];
}

- (void)playMotionForArtist:(NSString *)artist album:(NSString *)album {
    NSString *key = artist.length && album.length ? [NSString stringWithFormat:@"%@\n%@", artist, album] : nil;
    if (!key || [key isEqualToString:_motionAlbum] || !SGEnabled(SGRKeyAlbumMotion) || !SGMotionAppleMusicOn()) return;
    _motionAlbum = key;
    // The player's size: at the screen's full width a square cover ran to the 1920 stream, tens of MB.
    CGFloat pixels = SGMotionPixels();
    __weak SGRAlbumHero *weakSelf = self;
    // Tall, as the Music app's album page: the hero runs past the title, taller than wide, and a square clip
    // filled into it lost its sides. An album with only a square clip gets that one.
    SGMotionAlbumCover(artist, album, SGMotionTall, pixels, ^(NSURL *file) {
        SGRAlbumHero *hero = weakSelf;
        if (hero && file && [hero->_motionAlbum isEqualToString:key]) [hero showMotion:file];
    });
}

// Muted and looping, over the picture in the hero's masked content and under the scrim. The picture stays
// under it until the first frame is decoded, and only then does the clip fade in: a fade started at once was
// spent on a layer with nothing in it, and the clip cut in after it.
- (void)showMotion:(NSURL *)file {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:file];
    _player = [AVQueuePlayer new];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    // A file on the phone: nothing to buffer against, so it starts as soon as it can.
    _player.automaticallyWaitsToMinimizeStalling = NO;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];
    [self sgr_dropMotion];
    _motion = [AVPlayerLayer playerLayerWithPlayer:_player];
    _motion.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _motion.zPosition = 0.5;
    _motion.frame = self.bounds;
    _motion.opacity = 0;
    [self.content.layer addSublayer:_motion];
    [_motion addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial context:kReadyContext];
    _motionOn = NO;
    [self sgr_updateMotion];
    SGLog(@"redesign album: animated cover %@", file.lastPathComponent);
}

- (void)sgr_dropMotion {
    [_motion removeObserver:self forKeyPath:@"readyForDisplay" context:kReadyContext];
    [_motion removeFromSuperlayer];
    _motion = nil;
    // A square cover's scrim, mask and shadow follow whether a clip covers it.
    if (!SGRFullBleedCovers()) [self setNeedsLayout];
}

// The Kit watches the page's list for the pull; on the same steps, with a clip, whether the hero has left the
// screen or come back to it. A hero with no clip, which most album pages have, costs the scroll nothing more.
- (void)listDidScroll {
    if (_player && [self sgr_seen] != _motionSeen) [self sgr_updateMotion];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kReadyContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    __weak SGRAlbumHero *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf sgr_fadeInMotion:object]; });
}

// Once, when the clip has a frame to show: over 0.2 s on a curve most of the way there at once (the Kit's response,
// an entrance being quick), on screen; at once off it.
- (void)sgr_fadeInMotion:(AVPlayerLayer *)layer {
    if (layer != _motion || !layer.readyForDisplay || layer.opacity == 1) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opacity = 1;
    // A square cover's hero has no scrim and no mask until the clip fills it. Its layout pass, run now, gives it
    // both, and they come in with the clip, the mask from opaque all the way down, so the square under the clip
    // is not cut into as it fades in.
    BOOL square = !SGRFullBleedCovers();
    if (square) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }
    if (self.window) {
        CAMediaTimingFunction *curve = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = @1;
        fade.duration = 0.2;
        fade.timingFunction = curve;
        for (CALayer *each in square ? @[layer, self.scrim] : @[layer]) [each addAnimation:fade forKey:@"fade"];
        if (square) [self revealDissolveOver:fade.duration curve:curve];
    }
    [CATransaction commit];
}

// The power state is reported off the main thread.
- (void)sgr_updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self sgr_updateMotion]; });
}

// The clip moves under the conditions the player's does (Player/PlayerMotion.x), and only with Auto-Play
// Video Previews on; otherwise it holds its frame. Off screen it stops: an album page left on the
// navigation stack would otherwise keep decoding, and so would one scrolled down to its tracks, where the
// hero is above the top of the screen. Scrolled back, the clip goes on from the frame it stopped on.
- (BOOL)sgr_seen {
    UIWindow *window = self.window;
    return window && CGRectIntersectsRect([self convertRect:self.bounds toView:window], window.bounds);
}

- (void)sgr_updateMotion {
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL seen = _motionSeen = [self sgr_seen];
    BOOL may = seen && front && !SGRReduceMotion() && !NSProcessInfo.processInfo.lowPowerModeEnabled
            && UIAccessibilityIsVideoAutoplayEnabled();
    if (may == _motionOn) return;
    _motionOn = may;
    if (may) [_player play];
    else [_player pause];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self sgr_updateMotion];
}

- (void)takeShadowFrom:(UIView *)cover {
    if (_shadow.shadowOpacity > 0) return;
    __block CALayer *found = nil;
    SGForEachView(cover, ^(UIView *v) {
        if (!found && v.layer.shadowOpacity > 0) found = v.layer;
    });
    if (!found) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shadow.shadowColor = found.shadowColor;
    _shadow.shadowOpacity = found.shadowOpacity;
    _shadow.shadowRadius = found.shadowRadius;
    _shadow.shadowOffset = found.shadowOffset;
    [CATransaction commit];
    SGLog(@"redesign album: square shadow from %@, opacity %.2f radius %.1f offset %@", NSStringFromClass(found.delegate.class),
          found.shadowOpacity, found.shadowRadius, NSStringFromCGSize(found.shadowOffset));
    [self setNeedsLayout];
}

- (void)followCover:(UIImageView *)source {
    if (!source) return;
    [self takeCover:source late:NO];
    if (_cover == source) return;
    _cover = source;
    __weak SGRAlbumHero *weakSelf = self;
    SGRObserveImage(source, ^(UIImageView *view) { [weakSelf takeCover:view late:YES]; });
}

// `late` is a cover that arrived after the header had laid out -- an album opened for the first time, whose
// artwork is still being fetched while the page is already on screen. The log line says once that the watch,
// and not one of the header's passes, is what filled the hero.
- (void)takeCover:(UIImageView *)source late:(BOOL)late {
    UIImage *image = source.image;
    if (!image || source.bounds.size.width < kMinCover || _picture.image == image) return;
    _picture.image = image;
    // The page's field takes its color from the same picture.
    SGRAlbumSetArtwork(self, image);
    static BOOL logged;
    if (late && !logged) {
        logged = YES;
        SGLog(@"redesign album: the cover landed after the header had laid out; the hero took it");
    }
}

@end

// The image view of Spotify's artwork square: the one with the cover in it, or, before the cover has been
// fetched, the empty one it will land in, so it can be watched from the first pass.
static UIImageView *coverImageIn(UIView *cover) {
    __block UIImageView *found = nil, *empty = nil;
    SGForEachView(cover, ^(UIView *v) {
        if (found || ![v isKindOfClass:UIImageView.class]) return;
        UIImageView *image = (UIImageView *)v;
        if (image.bounds.size.width < kMinCover) return;
        if (image.image) found = image;
        else if (!empty) empty = image;
    });
    return found ?: empty;
}

// The picture runs from the top of the header down past where its text begins, so the title and the artist
// sit on the bottom of its dissolve; the dissolve is a mask, so what shows through it is the page's field at
// that height, whatever color it is there, pulled down or not, and there is no seam to see.
//
// `bottom` is taken from the header at rest, never from where it is mid scroll, and only ever grows: a header
// still loading is shorter than it will end up, and once the cover and the artist are in it settles and the
// picture does not change size again.
static void applyHero(UIView *header, UIView *cover, CGFloat bottom) {
    SGRAlbumHero *hero = objc_getAssociatedObject(header, &kHeroKey);
    if (!hero) {
        hero = [[SGRAlbumHero alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(header, &kHeroKey, hero, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.superview != header) [header insertSubview:hero atIndex:0];
    else if (header.subviews.firstObject != hero) [header sendSubviewToBack:hero];

    CGFloat height = [objc_getAssociatedObject(hero, &kHeroHeightKey) doubleValue];
    if (bottom > height + 0.5) {
        height = round(bottom);
        objc_setAssociatedObject(hero, &kHeroHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign album: hero %.0fpt across the top of the header", height);
    }
    if (height < kMinHero) return;
    hero.restHeight = height;
    [hero sgr_place];
    // Spotify's square at full size, in the header's coordinates, which are the hero's: grow-only like the height,
    // so the square stays put while the header fades and collapses. Its bottom too, since the cover can reach its
    // full size before the header's top inset is in.
    if (!SGRFullBleedCovers()) {
        CGRect square = [cover convertRect:cover.bounds toView:header];
        if (square.size.width >= kMinCover && (square.size.width > hero.square.size.width + 0.5
                                               || CGRectGetMaxY(square) > CGRectGetMaxY(hero.square) + 0.5)) hero.square = square;
        [hero takeShadowFrom:cover];
    }
    [hero followCover:coverImageIn(cover)];
    conceal(cover);
}

#pragma mark - what the header shows

static NSString *trimmed(NSString *text) {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? clean : nil;
}

// The first label under `root` with more than a letter in it: the facepile's initials are labels of their own.
static NSString *firstText(UIView *root) {
    __block NSString *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (found || ![v isKindOfClass:UILabel.class]) return;
        NSString *text = trimmed(((UILabel *)v).text);
        if (text.length > 1) found = text;
    });
    return found;
}

// The kind and the date ("Album • 31. 1. 2025", "Single • 2024") are cells of a collection view, a label each;
// read in the order they are drawn in.
static NSString *metadataText(UIView *metadata) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SGForEachView(metadata, ^(UIView *v) {
        if ([v isKindOfClass:UILabel.class] && trimmed(((UILabel *)v).text) && v.window) [labels addObject:(UILabel *)v];
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGFloat ax = [a convertPoint:CGPointZero toView:metadata].x, bx = [b convertPoint:CGPointZero toView:metadata].x;
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UILabel *label in labels) [parts addObject:trimmed(label.text)];
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

static void applyHeader(UIView *header, UIView *page);

// The Kit's view over the whole header, its content on the header's bottom edge; Spotify's own column goes.
static SGRHeaderInfo *applyInfo(UIView *header, UIView *page, NSString **artist, NSString **album) {
    SGRHeaderInfo *info = objc_getAssociatedObject(header, &kInfoKey);
    if (!info) {
        info = [[SGRHeaderInfo alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(header, &kInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (info.superview != header) [header addSubview:info];
    else if (header.subviews.lastObject != info) [header bringSubviewToFront:info];
    SGRAlbumHero *hero = objc_getAssociatedObject(header, &kHeroKey);
    for (UIView *sub in header.subviews) {
        if (sub != info && sub != hero) blank(sub);
    }
    setFrame(info, header.bounds);

    UIView *title = SGRFindByIdentifier(header, @"CreativeWorkPlatform.Components.UI.TitleRow", &kTitleKey);
    // Spotify's header grows and shrinks as its Play turns to Pause (issue #25), its title row does not.
    if (title.window) {
        CGFloat top = [title convertRect:title.bounds toView:header].origin.y;
        if (fabs(top - info.pinnedTop) > 0.5) {
            info.pinnedTop = top;
            [info setNeedsLayout];
        }
    }
    UIView *parent = SGRFindByIdentifier(header, @"CreativeWorkPlatform.Components.UI.ParentRow", &kParentKey);
    UIView *metadata = SGRFindByIdentifier(header, @"Components.UI.MetadataRow", &kMetaKey);
    NSString *length = metadataText(metadata), *line = firstText(parent);
    *album = firstText(title);
    *artist = line ?: trimmed(parent.accessibilityLabel);
    [info showTitle:*album creator:*artist length:length about:nil];
    // The line as it reads, without the accessibility label to fall back on: no line, no row loses its artist.
    SGRAlbumSetArtist(page, line);
    // The kind and the date are cells the metadata row's collection view makes on its own pass, after the
    // header's, and nothing lays the header out again when they arrive; the collection is Spotify's own Swift
    // class, which cannot be watched. So an empty row is read again a moment later, a few times at most.
    NSInteger tries = [objc_getAssociatedObject(header, &kRetryKey) integerValue];
    if (!length && metadata && tries < 6) {
        objc_setAssociatedObject(header, &kRetryKey, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakHeader = header, *weakPage = page;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakHeader && weakPage) applyHeader(weakHeader, weakPage);
        });
    }

    // The artist under the title, opened from the line that names them. ParentRow is one control for the
    // whole line however many artists are on the album, so several of them open Spotify's own picker
    // (issue #56).
    [info showCreatorLink:parent];
    // And the artist's picture before the name, the one Spotify draws at the start of the row.
    [info showCreatorPicture:SGRCreatorPicture(parent)];

    // More, pinned over the page rather than left in the header, which is blanked and scrolls away.
    SGRPinnedMore(page, &kPinnedMoreKey, SGRFindByIdentifier(header, @"Components.UI.ContextMenuButton*", &kMoreKey));

    UIView *play = floatingIn(page, @"header-play-button", &kPlayKey);
    UIView *shuffle = floatingIn(page, @"Components.UI.ShuffleButton", &kShuffleKey);
    UIView *add = SGRFindByIdentifier(header, @"Components.UI.AddToButton", &kAddKey);
    UIView *download = add ? nil : SGRFindByIdentifier(header, @"DownloadButton.Granular*", &kDownloadKey);
    [info showShuffle:shuffle play:play trailing:add ?: download
     trailingFallback:[UIImage systemImageNamed:add ? @"plus" : @"arrow.down"] playColor:SGRAlbumFieldColor(header)];
    // Only what the two floating buttons draw goes: a concealed layer still sends the actions the row fires.
    if (play) conceal(wrapperFor(play, page));
    if (shuffle) conceal(wrapperFor(shuffle, page));

    // Add arrives after the header has laid out on an album opened for the first time (the next time its state
    // is cached and it is there from the start), in a row that lays nothing else out (Native/Album/Album.x): the
    // row drew download on Play's right, or nothing, until the page was opened again (issue #19). So the row's
    // own pass is watched, a plain UIStackView, as the artist page's is, found from whichever of Spotify's
    // buttons is in it already.
    UIView *inRow = add ?: download ?: SGRFindByIdentifier(header, @"Components.UI.WatchFeedEntityExplorerButton", &kExploreKey);
    __weak UIView *weakHeader = header, *weakPage = page;
    watch(rowOf(inRow, header), &kRowWatchedKey, ^(UIView *view) {
        if (weakHeader && weakPage) applyHeader(weakHeader, weakPage);
    });

    static BOOL logged;
    if (!logged && header.window && title) {
        logged = YES;
        SGLog(@"redesign album: own block \"%@\" by %@, \"%@\"; shuffle %@, play %@, %@", firstText(title),
              firstText(parent) ?: trimmed(parent.accessibilityLabel) ?: @"nobody", metadataText(metadata) ?: @"no metadata", shuffle ? @"found" : @"missing",
              play ? @"found" : @"missing", add ? @"add" : (download ? @"download" : @"nothing on the right"));
    }
    return info;
}

#pragma mark - the header's pass

// Drawn by nothing, whatever Spotify does to it: an empty mask. Spotify switches the navigation bar's
// gradient on and off with -setHidden:, which writes the layer's own hidden and so undoes conceal(); and
// it fades both gradients by alpha. Neither touches a mask.
static void maskOut(UIView *view) {
    if (!view || view.layer.mask) return;
    view.layer.mask = [CALayer layer];
    view.accessibilityElementsHidden = YES;
}

// The color Spotify painted the wash in: the first opaque color of the gradient layer it draws with,
// whether that is the view's own layer or one under it. nil when it draws some other way, or has
// no color yet.
static UIColor *washColorOf(UIView *gradient) {
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:gradient.layer];
    [layers addObjectsFromArray:gradient.layer.sublayers ?: @[]];
    for (CALayer *layer in layers) {
        if (![layer isKindOfClass:CAGradientLayer.class]) continue;
        for (id value in ((CAGradientLayer *)layer).colors) {
            CGColorRef cg = (__bridge CGColorRef)value;
            if (CFGetTypeID(cg) != CGColorGetTypeID() || CGColorGetAlpha(cg) < 0.5) continue;
            // The page's base surface is what a wash is before Spotify has a color for it, not a color.
            if (SGIsBaseSurface(cg)) return nil;
            return [UIColor colorWithCGColor:cg];
        }
    }
    return nil;
}

// Spotify's color wash behind the header goes, so the page's field shows through, and the color it was
// painted in goes to the field, to show until the cover's own main color has been read.
//
// The navigation bar's gradient goes too. Hidden at rest, it is shown as the page scrolls under the
// title, and over the field it was a flat dark band across the top (device, 2026-09-18). What keeps the
// title legible over the list is the soft top edge every redesigned page has (SGREdgeEffect.x), as it is
// on Home, Search and Library.
static void applyWash(UIView *page) {
    for (UIView *sub in page.subviews) {
        Class cls = sub.class;
        if (!SGClassNamed(cls, @"HeaderView") && !SGClassNamed(cls, @"HeaderNavigationBar")) continue;
        BOOL wash = !SGClassNamed(cls, @"NavigationBar");
        for (UIView *v in sub.subviews) {
            if (!SGClassNamed(v.class, @"GradientView")) continue;
            if (wash) {
                UIColor *color = washColorOf(v);
                static BOOL logged;
                if (!logged) {
                    logged = YES;
                    SGLog(@"redesign album: Spotify's wash %@ on %@, color %@", NSStringFromClass(v.class),
                          NSStringFromClass(v.layer.class), color ?: @"not found");
                }
                SGRAlbumSetSpotifyColor(page, color);
            }
            maskOut(v);
        }
    }
}

static void applyHeader(UIView *header, UIView *page) {
    if (!SGRFindByIdentifier(header, @"CreativeWorkPlatform.Components.UI.TitleRow", &kTitleKey)) return;
    SGRAlbumHoldPage(page);
    applyWash(page);
    NSString *artist, *album;
    SGRHeaderInfo *info = applyInfo(header, page, &artist, &album);

    // The picture reaches to where the content's top is at rest, plus the title and the artist. The header at
    // rest is the tallest it has been, so the picture does not change size as the header loads or scrolls.
    CGFloat rest = MAX([objc_getAssociatedObject(header, &kHeaderHeightKey) doubleValue], header.bounds.size.height);
    objc_setAssociatedObject(header, &kHeaderHeightKey, @(rest), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat bottom = rest - SGRHeaderInfoBottom - [info contentHeightForWidth:header.bounds.size.width] + SGRHeaderInfoTitleRise;
    UIView *cover = SGRFindByIdentifier(header, @"CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt", &kCoverKey);
    if (cover) applyHero(header, cover, bottom);
    SGRAlbumHero *hero = objc_getAssociatedObject(header, &kHeroKey);
    [hero playMotionForArtist:artist album:album];
}

static void applyPage(UIView *page) {
    UIView *header = SGRFindByIdentifier(page, @"CreativeWorkPlatform.Components.UI.CreativeWorkHeader", &kHeaderKey);
    if (!header) return;
    applyHeader(header, page);
    // The header lays itself out again whenever its cover, its artist or its buttons arrive, which the
    // page's own pass does not hear about. It is a plain UIView, so its pass can be watched.
    watch(header, &kHeaderWatchedKey, ^(UIView *view) {
        UIView *owner = SGRAlbumPageOf(view);
        if (owner) applyHeader(view, owner);
    });
}

%hook _TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView
- (void)layoutSubviews {
    %orig;
    applyPage((UIView *)self);
}
%end

// The play button arrives in the page after the row that replaces it has been laid out, so a page opening
// showed Spotify's green disc in the corner until something else laid the page out. Its own pass is where
// it goes, and the class is Spotify's own so nothing else pays for the check.
%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (button.layer.hidden || ![button.accessibilityIdentifier isEqualToString:@"header-play-button"]) return;
    UIView *page = SGRAlbumPageOf(button);
    if (!page) return;
    conceal(wrapperFor(button, page));
    applyPage(page);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView",
        @"_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView",
    ]);
}
