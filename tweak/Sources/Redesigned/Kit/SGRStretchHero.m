// The stretching hero of the album and artist pages (SGRStretchHero.h).
#import "Core/SGCore.h"
#import "SGRStretchHero.h"

const CGFloat SGRStretchHeroDissolve = 0.46, SGRStretchHeroScrim = 140, SGRStretchHeroScrimAlpha = 0.28;

// A pull this far is a pull and not a bounce at the end of a scroll: where the clip check runs.
static const CGFloat kClipCheckPull = 24;

static void *kListContext = &kListContext;

static void setFrame(UIView *view, CGRect frame) {
    if (view && !CGRectIsEmpty(frame) && !CGRectEqualToRect(view.frame, frame)) view.frame = frame;
}

@implementation SGRStretchHero {
    CALayer *_mask;              // content's mask while it dissolves: _opaque over _fade
    CALayer *_opaque;            // from the top down to the dissolve, grown by the pull
    CAGradientLayer *_fade;      // the dissolve, a fixed height on the bottom with fixed stops
    __weak UIScrollView *_list;  // the page's list, watched for the pull at its top while the hero is in a window
    BOOL _clipChecked;           // this hero has been through the clip log's check
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;

    _content = [[UIView alloc] initWithFrame:self.bounds];
    _content.userInteractionEnabled = NO;
    [self addSubview:_content];

    // Above the content whatever else is added to the view later.
    _scrim = [CAGradientLayer layer];
    _scrim.zPosition = 1;
    _scrim.colors = @[(id)[UIColor colorWithWhite:0 alpha:SGRStretchHeroScrimAlpha].CGColor, (id)UIColor.clearColor.CGColor];
    [self.layer addSublayer:_scrim];

    _mask = [CALayer layer];
    _opaque = [CALayer layer];
    _opaque.backgroundColor = UIColor.blackColor.CGColor;
    [_mask addSublayer:_opaque];
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.blackColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0.28].CGColor,
                     (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @0.62, @1];
    [_mask addSublayer:_fade];
    _dissolves = YES;
    _content.layer.mask = _mask;
    _logName = @"hero";
    return self;
}

- (void)dealloc {
    [_list removeObserver:self forKeyPath:@"contentOffset" context:kListContext];
}

- (void)setDissolves:(BOOL)dissolves {
    if (_dissolves == dissolves) return;
    _dissolves = dissolves;
    _content.layer.mask = dissolves ? _mask : nil;
}

- (CGFloat)pull {
    UIScrollView *list = _list;
    return list ? MAX(0, -(list.contentOffset.y + list.adjustedContentInset.top)) : 0;
}

- (CGFloat)stretch {
    return _restHeight < 1 ? 0 : MAX(0, self.bounds.size.height - _restHeight);
}

// A pull is a change of the hero's height, so the frame write in -sgr_place is what lays this out again.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    if (bounds.size.height < 1) return;
    // Never past the top: the bounds are restHeight and the pull.
    CGFloat fade = round(_restHeight * SGRStretchHeroDissolve);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _content.frame = bounds;
    _scrim.frame = CGRectMake(0, 0, bounds.size.width, MIN(SGRStretchHeroScrim, bounds.size.height));
    _mask.frame = bounds;
    _opaque.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height - fade);
    _fade.frame = CGRectMake(0, bounds.size.height - fade, bounds.size.width, fade);
    [CATransaction commit];
}

- (void)revealDissolveOver:(CFTimeInterval)duration curve:(CAMediaTimingFunction *)curve {
    id opaque = (id)UIColor.blackColor.CGColor;
    CABasicAnimation *reveal = [CABasicAnimation animationWithKeyPath:@"colors"];
    reveal.fromValue = @[opaque, opaque, opaque];
    reveal.duration = duration;
    reveal.timingFunction = curve;
    [_fade addAnimation:reveal forKey:@"reveal"];
}

- (void)sgr_place {
    [self sgr_placeForPull:self.pull];
}

- (void)sgr_placeForPull:(CGFloat)pull {
    UIView *host = self.superview;
    if (!host || _restHeight < 1 || host.bounds.size.width < 1) return;
    setFrame(self, CGRectMake(0, -pull, host.bounds.size.width, _restHeight + pull));
    if (pull > kClipCheckPull && !_clipChecked) [self sgr_checkClip:pull];
}

// Once per page kind: above the host's top is outside it, so a view on the way to the list that clips would
// cut the stretch off. The device check of the assumption that the host moves down with the pull.
- (void)sgr_checkClip:(CGFloat)pull {
    _clipChecked = YES;
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:_logName]) return;
    [logged addObject:_logName];
    UIView *clips = nil;
    UIScrollView *list = _list;
    for (UIView *v = self.superview; v && v != list && !clips; v = v.superview) {
        if (v.clipsToBounds) clips = v;
    }
    SGLog(@"redesign %@: hero stretched %.0fpt over the pull, %@", _logName, pull,
          clips ? [NSString stringWithFormat:@"cut off by %@", NSStringFromClass(clips.class)] : @"nothing clips it");
}

- (void)listDidScroll {
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kListContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    // Most steps are the list scrolling, the hero neither pulled nor coming back from a pull: nothing to place.
    CGFloat pull = self.pull;
    if (pull > 0 || self.bounds.size.height > _restHeight + 0.5) [self sgr_placeForPull:pull];
    [self listDidScroll];
}

- (void)sgr_watchList {
    UIScrollView *list = nil;
    for (UIView *v = self.window ? self.superview : nil; v && !list; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class]) list = (UIScrollView *)v;
    }
    if (list == _list) return;
    [_list removeObserver:self forKeyPath:@"contentOffset" context:kListContext];
    _list = list;
    [list addObserver:self forKeyPath:@"contentOffset" options:0 context:kListContext];
    [self sgr_place];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self sgr_watchList];
}

@end
