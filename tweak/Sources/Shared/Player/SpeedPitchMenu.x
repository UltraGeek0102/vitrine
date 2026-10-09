// The player's more menu gets Speed and pitch, under either look: one row in Spotify's own context menu
// sheet that opens, right there in the sheet, onto two sliders, the playback speed and the pitch
// (SpeedPitch.x applies them).
//
// The sheet is Spotify's ContextMenu_InternalImpl.ContextMenuViewController, a table of its rows
// (ContextMenuTableView, sized to its content). Its rows come from Swift item factories with no way in,
// so the block is the table's header view, or its footer when Spotify already uses the header, and is
// laid out by hand at the table's width. Opening and closing it resizes the header inside a table update,
// so the rows under it move with it, and the table's intrinsic size is invalidated for the sheet to
// follow.
//
// Only the menu the player's more button opens gets it: the button (id=Context menu,
// trees/lyrics.txt:183, an Encore Tertiary button in NowPlaying_ModesImpl.HeaderElementsUnit) is watched
// from here under either look, and the first menu that comes up within a few seconds of its tap is the
// player's. The presenter is not a test: every sheet the player puts up comes from its
// NowPlayingOverlayContainer, the ⋯ card's own pages too (its Sleep timer is a context menu sheet of its own,
// which took the block as well, "tapped 0" in the log). The first time, the menu's structure is logged,
// since no recorded tree shows it yet.
//
// The block is drawn from its own measures and type (below), not from the redesign's Kit, so it sits on
// Spotify's sheet under either look.
//
// The block keeps whether it was open for the rest of the session; speed and pitch last until Spotify
// quits.
//
// Under the redesign, with the player's background Fluid or Animated, a row under the block switches
// Animated artwork (SpeedPitch.h), which the redesign's PlayerMotion.x defines.
//
// The redesign shows the player's sheet as the system menu, with speed, pitch, reverb and Animated artwork
// as items of its own (Redesigned/Player/PlayerMenu.m), so the block stays out of a sheet shown that way
// and comes in only if the sheet itself is shown after all (SGPlayerMenuReplaced).
#import <CoreText/SFNTLayoutTypes.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/AudioEffects/AudioEffects.h"
#import "Shared/Haptics/Haptics.h"
#import "SpeedPitch.h"

// A menu this soon after the more button's tap is the player's.
static const NSTimeInterval kMenuAfterTap = 3;
static const CGFloat kRowHeight = 56, kSliderBlockHeight = 72, kSwitchRowHeight = 44, kPanelBottom = 12;
// The block's own measures and type, so it stands on Spotify's sheet under either look rather than on
// the redesign's Kit: the sheet's side margin, the gap everything else is a multiple of, and a spring
// that settles without overshooting.
static const CGFloat kSideMargin = 16, kGrid = 8;
static const NSTimeInterval kOpenDuration = 0.45;

static UIColor *primary(void) {
    return UIColor.whiteColor;
}

// White at the weight the sheet's own secondary text is, a step firmer with Increase Contrast.
static UIColor *secondary(void) {
    return [UIColor colorWithWhite:1 alpha:UIAccessibilityDarkerSystemColorsEnabled() ? 0.80 : 0.65];
}

// The system font at a text style's size, which stops growing past `largest` so the row still fits.
static UIFont *font(UIFontTextStyle style, UIFontWeight weight, UIContentSizeCategory largest) {
    UIContentSizeCategory current = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (largest && UIContentSizeCategoryCompareToCategory(current, largest) == NSOrderedDescending) current = largest;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:current];
    CGFloat size = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:traits].pointSize;
    return [UIFont systemFontOfSize:size weight:weight];
}

// Digits of one width, so a value does not shuffle as it counts.
static UIFont *monospacedDigits(UIFont *base) {
    if (!base) return nil;
    NSArray *features = @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType), UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}];
    UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute: features}];
    return [UIFont fontWithDescriptor:descriptor size:base.pointSize];
}

static void animateOpen(void (^animations)(void), void (^completion)(BOOL finished)) {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [UIView performWithoutAnimation:animations];
        if (completion) completion(YES);
        return;
    }
    [UIView animateWithDuration:kOpenDuration delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:animations completion:completion];
}
static const float kMinSpeed = 0.5f, kMaxSpeed = 2, kSpeedStep = 0.05f;
static const float kMaxPitch = 12;
// Speed is applied at most this often while the slider moves.
static const NSTimeInterval kSpeedInterval = 0.05;

static NSTimeInterval sg_moreTappedAt;
static BOOL sg_open;
static char kBlockKey, kDecidedKey, kWatchedKey, kShownAtKey, kRowsInKey;

#pragma mark - the block

@interface SGSpeedPitchView : UIView
@property (nonatomic, weak) UITableView *table;
@property (nonatomic) BOOL inFooter;
// The sliders alone, always open, for the redesign's panel under the ⋯ (SGPlayerShowSpeedPitchPanel).
@property (nonatomic) BOOL panelOnly;
@end

@implementation SGSpeedPitchView {
    UIControl *_row;
    UIImageView *_icon, *_chevron;
    UILabel *_title, *_summary;
    UIView *_panel;
    UILabel *_speedName, *_pitchName, *_reverbName;
    UIButton *_speedValue, *_pitchValue, *_reverbValue;
    UISlider *_speed, *_pitch, *_reverb;
    UILabel *_followsName;
    UISwitch *_follows;
    UIView *_animatedRow;
    UIImageView *_animatedIcon;
    UILabel *_animatedName;
    UISwitch *_animated;
    float _shownSpeed, _shownPitch, _shownReverb;
    NSTimeInterval _speedSentAt;
    BOOL _speedPending;
}

static UIImage *symbol(NSString *name, CGFloat size, UIImageSymbolWeight weight) {
    return [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

// A glyph with its color drawn in, so it never passes through a tint on its way to the screen.
static UIImage *paintedSymbol(NSString *name, CGFloat size, UIImageSymbolWeight weight, UIColor *color) {
    return [symbol(name, size, weight) imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UILabel *makeLabel(UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = NO;
    return label;
}

- (UIButton *)valueButton:(SEL)reset {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = monospacedDigits(font(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryExtraLarge));
    button.tintColor = primary();
    [button setTitleColor:primary() forState:UIControlStateNormal];
    [button setTitleColor:[primary() colorWithAlphaComponent:0.4] forState:UIControlStateHighlighted];
    [button setTitleColor:primary() forState:UIControlStateDisabled];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    button.accessibilityHint = @"Resets it";
    [button addTarget:self action:reset forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// A glyph centered in a box of one size, so both sliders' tracks start and end at the same x.
static UIImage *endImage(NSString *name, CGFloat size) {
    UIImage *glyph = paintedSymbol(name, size, UIImageSymbolWeightMedium, secondary());
    CGSize box = CGSizeMake(24, 24);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:box] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [glyph drawAtPoint:CGPointMake((box.width - glyph.size.width) / 2, (box.height - glyph.size.height) / 2)];
    }];
}

// Both sliders have their normal in the middle of the range rather than at one end, so neither track
// fills: a tick marks where normal is, under the thumb until it moves away.
- (UISlider *)slider:(float)min max:(float)max normal:(float)normal minImage:(NSString *)minImage maxImage:(NSString *)maxImage {
    UISlider *slider = [UISlider new];
    slider.minimumValue = min;
    slider.maximumValue = max;
    UIColor *track = [UIColor colorWithWhite:1 alpha:0.2];
    slider.minimumTrackTintColor = track;
    slider.maximumTrackTintColor = track;
    slider.minimumValueImage = endImage(minImage, 13);
    slider.maximumValueImage = endImage(maxImage, 17);
    UIView *tick = [UIView new];
    tick.backgroundColor = secondary();
    tick.layer.cornerRadius = 1;
    tick.userInteractionEnabled = NO;
    tick.tag = (NSInteger)(normal * 1000);
    [slider insertSubview:tick atIndex:0];
    [slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return slider;
}

// The tick at the normal value's x on the track, found the way the thumb is placed.
static void placeTick(UISlider *slider) {
    UIView *tick = slider.subviews.firstObject;
    if (tick.subviews.count || tick.class != UIView.class) return;
    CGRect track = [slider trackRectForBounds:slider.bounds];
    float normal = tick.tag / 1000.0f;
    CGRect thumb = [slider thumbRectForBounds:slider.bounds trackRect:track value:normal];
    tick.frame = CGRectMake(roundf(CGRectGetMidX(thumb)) - 1, CGRectGetMidY(track) - 6, 2, 12);
    [slider sendSubviewToBack:tick];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.clearColor;
    // Nothing here draws in the tint: every color is set on the view that draws it, and the glyphs have
    // theirs painted in rather than tinted. The row came up in the system blue for a moment as the sheet
    // appeared on the phone (issue #68), which is the tint a view inherits when nothing up the sheet sets
    // one. The block's own tint is white as well, for whatever UIKit draws in it (the sliders' parts).
    self.tintColor = primary();

    _row = [UIControl new];
    [_row addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [_row addTarget:self action:@selector(rowHighlight) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [_row addTarget:self action:@selector(rowUnhighlight) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    _row.isAccessibilityElement = YES;
    _row.accessibilityTraits = UIAccessibilityTraitButton;
    [self addSubview:_row];

    _icon = [[UIImageView alloc] initWithImage:paintedSymbol(@"slider.horizontal.3", 20, UIImageSymbolWeightRegular, secondary())];
    _icon.contentMode = UIViewContentModeCenter;
    _title = makeLabel(font(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryExtraLarge), primary());
    _title.text = @"Speed and pitch";
    _summary = makeLabel(monospacedDigits(font(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraLarge)), secondary());
    _summary.textAlignment = NSTextAlignmentRight;
    _chevron = [[UIImageView alloc] initWithImage:paintedSymbol(@"chevron.down", 13, UIImageSymbolWeightSemibold, secondary())];
    _chevron.contentMode = UIViewContentModeCenter;
    for (UIView *view in @[_icon, _title, _summary, _chevron]) {
        view.userInteractionEnabled = NO;
        [_row addSubview:view];
    }

    _panel = [UIView new];
    [self addSubview:_panel];
    UIFont *nameFont = font(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraLarge);
    _speedName = makeLabel(nameFont, secondary());
    _speedName.text = @"Speed";
    _pitchName = makeLabel(nameFont, secondary());
    _pitchName.text = @"Pitch";
    _speedValue = [self valueButton:@selector(resetSpeed)];
    _pitchValue = [self valueButton:@selector(resetPitch)];
    _speed = [self slider:kMinSpeed max:kMaxSpeed normal:1 minImage:@"tortoise.fill" maxImage:@"hare.fill"];
    _speed.accessibilityLabel = @"Speed";
    _pitch = [self slider:-kMaxPitch max:kMaxPitch normal:0 minImage:@"arrow.down" maxImage:@"arrow.up"];
    _pitch.accessibilityLabel = @"Pitch";
    _reverbName = makeLabel(nameFont, secondary());
    _reverbName.text = @"Reverb";
    _reverbValue = [self valueButton:@selector(resetReverb)];
    _reverb = [self slider:0 max:100 normal:0 minImage:@"speaker" maxImage:@"building.columns"];
    _reverb.accessibilityLabel = @"Reverb";
    _followsName = makeLabel(nameFont, primary());
    _followsName.text = @"Pitch follows speed";
    _follows = [UISwitch new];
    _follows.accessibilityLabel = @"Pitch follows speed";
    [_follows addTarget:self action:@selector(followsChanged) forControlEvents:UIControlEventValueChanged];
    for (UIView *view in @[_speedName, _speedValue, _speed, _pitchName, _pitchValue, _pitch, _reverbName, _reverbValue, _reverb,
                           _followsName, _follows]) [_panel addSubview:view];

    if (SGPlayerMenuOffersAnimatedArtwork()) {
        _animatedRow = [UIView new];
        _animatedIcon = [[UIImageView alloc] initWithImage:paintedSymbol(@"play.rectangle.on.rectangle", 18, UIImageSymbolWeightRegular, secondary())];
        _animatedIcon.contentMode = UIViewContentModeCenter;
        _animatedName = makeLabel(font(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryExtraLarge), primary());
        _animatedName.text = @"Animated artwork";
        _animated = [UISwitch new];
        _animated.accessibilityLabel = @"Animated artwork";
        [_animated addTarget:self action:@selector(animatedChanged) forControlEvents:UIControlEventValueChanged];
        for (UIView *view in @[_animatedIcon, _animatedName, _animated]) [_animatedRow addSubview:view];
        [self addSubview:_animatedRow];
    }

    [self refresh];
    return self;
}

+ (CGFloat)heightOpen:(BOOL)open {
    return kRowHeight + (open ? 3 * kSliderBlockHeight + kSwitchRowHeight + kPanelBottom : 0)
         + (SGPlayerMenuOffersAnimatedArtwork() ? kRowHeight : 0);
}

// Set after init, which drew the values for the sheet's closed block: drawn again open.
- (void)setPanelOnly:(BOOL)panelOnly {
    _panelOnly = panelOnly;
    [self showValues];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, side = kSideMargin;
    _row.frame = CGRectMake(0, 0, width, kRowHeight);
    _icon.frame = CGRectMake(side, (kRowHeight - 24) / 2, 24, 24);
    _chevron.frame = CGRectMake(width - side - 20, (kRowHeight - 20) / 2, 20, 20);
    CGFloat titleX = side + 24 + side;
    CGFloat titleWidth = MIN([_title sizeThatFits:CGSizeMake(CGFLOAT_MAX, kRowHeight)].width, CGRectGetMinX(_chevron.frame) - titleX - kGrid);
    _title.frame = CGRectMake(titleX, 0, titleWidth, kRowHeight);
    CGFloat summaryX = CGRectGetMaxX(_title.frame) + kGrid;
    _summary.frame = CGRectMake(summaryX, 0, MAX(0, CGRectGetMinX(_chevron.frame) - kGrid - summaryX), kRowHeight);

    _row.hidden = self.panelOnly;
    _animatedRow.hidden = self.panelOnly;
    _panel.frame = CGRectMake(0, self.panelOnly ? kGrid : kRowHeight, width, 3 * kSliderBlockHeight + kSwitchRowHeight + kPanelBottom);
    CGFloat y = 0;
    for (NSArray<UIView *> *line in @[@[_speedName, _speedValue, _speed], @[_pitchName, _pitchValue, _pitch],
                                       @[_reverbName, _reverbValue, _reverb]]) {
        line[0].frame = CGRectMake(side, y + 4, width / 2 - side, 24);
        line[1].frame = CGRectMake(width / 2, y + 4, width / 2 - side, 24);
        line[2].frame = CGRectMake(side, y + 30, width - 2 * side, 36);
        [line[2] layoutIfNeeded];
        placeTick((UISlider *)line[2]);
        y += kSliderBlockHeight;
    }
    CGSize toggle = [_follows sizeThatFits:CGSizeZero];
    _follows.frame = CGRectMake(width - side - toggle.width, y + (kSwitchRowHeight - toggle.height) / 2, toggle.width, toggle.height);
    _followsName.frame = CGRectMake(side, y, CGRectGetMinX(_follows.frame) - side - kGrid, kSwitchRowHeight);

    // Under the panel while it is open, under the row while it is closed.
    _animatedRow.frame = CGRectMake(0, sg_open ? CGRectGetMaxY(_panel.frame) : kRowHeight, width, kRowHeight);
    _animatedIcon.frame = _icon.frame;
    toggle = [_animated sizeThatFits:CGSizeZero];
    _animated.frame = CGRectMake(width - side - toggle.width, (kRowHeight - toggle.height) / 2, toggle.width, toggle.height);
    _animatedName.frame = CGRectMake(titleX, 0, MAX(0, CGRectGetMinX(_animated.frame) - kGrid - titleX), kRowHeight);
}

#pragma mark state

float SGPlayerReverb(void) {
    return SGDSPSwitch(SGKeyDSP) && SGDSPSwitch(SGKeyDSPReverb) ? roundf(SGDSPNumber(SGKeyDSPReverbAmount)) : 0;
}

void SGPlayerSetReverb(float amount) {
    if (amount > 0) {
        SGDSPSetNumber(SGKeyDSPReverbAmount, amount);
        if (!SGDSPSwitch(SGKeyDSPReverb)) SGDSPSetSwitch(SGKeyDSPReverb, YES);
        if (!SGDSPSwitch(SGKeyDSP)) SGDSPSetSwitch(SGKeyDSP, YES);
    } else if (SGDSPSwitch(SGKeyDSPReverb)) {
        SGDSPSetSwitch(SGKeyDSPReverb, NO);
    }
}

static float snappedSpeed(float value) {
    float speed = roundf(value / kSpeedStep) * kSpeedStep;
    return fabsf(speed - 1) < kSpeedStep * 0.6f ? 1 : speed;
}

static NSString *speedText(float speed) {
    return [NSString stringWithFormat:@"%.2f×", speed];
}

static NSString *pitchText(float pitch) {
    if (pitch == 0) return @"0";
    return [NSString stringWithFormat:@"%@%.0f", pitch > 0 ? @"+" : @"−", fabsf(pitch)];
}

// What the player and the pitch say now, onto the controls (not while a finger is on one).
- (void)refresh {
    BOOL speedAllowed = SGPlayerSpeedAllowed(), pitchAvailable = SGPlayerPitchAvailable();
    if (!_speed.tracking) _shownSpeed = snappedSpeed(SGPlayerSpeed());
    if (!_pitch.tracking) _shownPitch = SGPlayerPitch();
    if (!_reverb.tracking) _shownReverb = SGPlayerReverb();
    _reverb.value = _shownReverb;
    _speed.value = _shownSpeed;
    _pitch.value = _shownPitch;
    _speed.enabled = speedAllowed;
    _pitch.enabled = pitchAvailable;
    _speed.alpha = speedAllowed ? 1 : 0.4;
    // Following needs the speed's unit, which the in place fallback does not have.
    _follows.on = SGPlayerPitchFollowsSpeed();
    _follows.enabled = speedAllowed;
    _follows.alpha = _followsName.alpha = speedAllowed ? 1 : 0.4;
    _animated.on = SGPlayerMenuAnimatedArtwork();
    [self showValues];
}

- (void)showValues {
    BOOL speedAllowed = SGPlayerSpeedAllowed(), pitchAvailable = SGPlayerPitchAvailable();
    // While pitch follows a speed that is not normal, the speed sets the pitch and the semitones are not
    // played (SGTimePitch.h), so the slider stands aside and nothing claims them.
    BOOL following = speedAllowed && _follows.on && _shownSpeed != 1;
    float pitch = following ? 0 : _shownPitch;
    [UIView performWithoutAnimation:^{
        [_speedValue setTitle:speedAllowed ? speedText(_shownSpeed) : @"Unavailable here" forState:UIControlStateNormal];
        [_pitchValue setTitle:!pitchAvailable ? @"Unavailable" : following ? @"Follows speed" : [pitchText(pitch) stringByAppendingString:pitch ? @" st" : @""]
                     forState:UIControlStateNormal];
        [_speedValue layoutIfNeeded];
        [_pitchValue layoutIfNeeded];
    }];
    BOOL pitchFree = pitchAvailable && !following;
    _pitch.enabled = pitchFree;
    _pitch.alpha = pitchFree ? 1 : 0.4;
    _speedValue.enabled = speedAllowed && _shownSpeed != 1;
    _pitchValue.enabled = pitchFree && pitch != 0;
    [UIView performWithoutAnimation:^{
        [_reverbValue setTitle:_shownReverb > 0 ? [NSString stringWithFormat:@"%.0f%%", _shownReverb] : @"Off" forState:UIControlStateNormal];
        [_reverbValue layoutIfNeeded];
    }];
    _reverbValue.enabled = _shownReverb > 0;
    _reverb.accessibilityValue = _shownReverb > 0 ? [NSString stringWithFormat:@"%.0f percent", _shownReverb] : @"Off";
    _speed.accessibilityValue = speedAllowed ? speedText(_shownSpeed) : @"Unavailable";
    _pitch.accessibilityValue = following ? @"Follows speed" : pitch == 0 ? @"Original pitch"
                                : [NSString stringWithFormat:@"%.0f semitones %@", fabsf(pitch), pitch > 0 ? @"up" : @"down"];

    NSMutableArray<NSString *> *changed = [NSMutableArray array];
    if (_shownSpeed != 1) [changed addObject:speedText(_shownSpeed)];
    if (pitch != 0) [changed addObject:[pitchText(pitch) stringByAppendingString:@" st"]];
    if (_shownReverb > 0) [changed addObject:@"Reverb"];
    _summary.text = sg_open ? nil : [changed componentsJoinedByString:@"  "];
    _row.accessibilityLabel = changed.count ? [@"Speed and pitch, " stringByAppendingString:[changed componentsJoinedByString:@", "]] : @"Speed and pitch";
    _row.accessibilityValue = sg_open ? @"Expanded" : @"Collapsed";
    _chevron.transform = sg_open ? CGAffineTransformMakeRotation(M_PI) : CGAffineTransformIdentity;
    _panel.alpha = sg_open || self.panelOnly ? 1 : 0;
    _panel.accessibilityElementsHidden = !sg_open && !self.panelOnly;
}

#pragma mark actions

- (void)rowHighlight {
    _row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
}

- (void)rowUnhighlight {
    [UIView animateWithDuration:0.2 animations:^{ _row.backgroundColor = UIColor.clearColor; }];
}

- (void)toggle {
    sg_open = !sg_open;
    if (sg_open) [self refresh];
    UITableView *table = self.table;
    CGRect frame = self.frame;
    frame.size.height = [SGSpeedPitchView heightOpen:sg_open];
    animateOpen(^{
        [table beginUpdates];
        self.frame = frame;
        if (self.inFooter) table.tableFooterView = self;
        else table.tableHeaderView = self;
        [self showValues];
        [self layoutIfNeeded];
        [table endUpdates];
    }, ^(BOOL finished) {
        if (sg_open) [table scrollRectToVisible:[table convertRect:self.bounds fromView:self] animated:YES];
    });
    [table invalidateIntrinsicContentSize];
    UIView *sheet = table.superview;
    for (int i = 0; sheet && i < 4; i++, sheet = sheet.superview) [sheet setNeedsLayout];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, sg_open ? _speed : nil);
    SGLog(@"speed and pitch: speed and pitch %@, table %.0f tall showing %.0f", sg_open ? @"opened" : @"closed", table.contentSize.height, table.bounds.size.height);
}

- (void)sendSpeed {
    _speedPending = NO;
    _speedSentAt = CACurrentMediaTime();
    SGSetPlayerSpeed(_shownSpeed);
}

- (void)sliderMoved:(UISlider *)slider {
    if (slider == _speed) {
        float speed = snappedSpeed(slider.value);
        if (speed == _shownSpeed) return;
        if (speed == 1 || _shownSpeed == 1) SGPlayFeedback(SGFeedbackDetent);
        _shownSpeed = speed;
        NSTimeInterval wait = kSpeedInterval - (CACurrentMediaTime() - _speedSentAt);
        if (wait <= 0) [self sendSpeed];
        else if (!_speedPending) {
            _speedPending = YES;
            __weak SGSpeedPitchView *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SGSpeedPitchView *view = weakSelf;
                if (view && view->_speedPending) [view sendSpeed];
            });
        }
    } else if (slider == _reverb) {
        float amount = roundf(slider.value / 5) * 5;
        if (amount == _shownReverb) return;
        if (amount == 0 || _shownReverb == 0) SGPlayFeedback(SGFeedbackDetent);
        _shownReverb = amount;
        SGPlayerSetReverb(amount);
    } else {
        float pitch = roundf(slider.value);
        if (pitch == _shownPitch) return;
        if (pitch == 0 || _shownPitch == 0) SGPlayFeedback(SGFeedbackDetent);
        _shownPitch = pitch;
        SGSetPlayerPitch(pitch);
    }
    [self showValues];
}

- (void)sliderReleased:(UISlider *)slider {
    if (slider == _speed) {
        slider.value = _shownSpeed;
        if (_speedPending || snappedSpeed(SGPlayerSpeed()) != _shownSpeed) [self sendSpeed];
    } else if (slider == _reverb) {
        slider.value = _shownReverb;
    } else {
        slider.value = _shownPitch;
    }
}

- (void)resetReverb {
    _shownReverb = 0;
    SGPlayerSetReverb(0);
    [_reverb setValue:0 animated:YES];
    [self showValues];
}

- (void)animatedChanged {
    SGPlayerMenuSetAnimatedArtwork(_animated.on);
    SGPlayFeedback(SGFeedbackDetent);
}

- (void)followsChanged {
    SGSetPlayerPitchFollowsSpeed(_follows.on);
    SGPlayFeedback(SGFeedbackDetent);
    [self refresh];
}

- (void)resetSpeed {
    _shownSpeed = 1;
    [self sendSpeed];
    [_speed setValue:1 animated:YES];
    [self showValues];
}

- (void)resetPitch {
    _shownPitch = 0;
    SGSetPlayerPitch(0);
    [_pitch setValue:0 animated:YES];
    [self showValues];
}

@end

#pragma mark - the panel

// A popover, so it takes the system's glass and closes on a tap outside it. On iPhone a popover becomes a
// sheet unless its delegate says otherwise.
@interface SGSpeedPitchPanel : UIViewController <UIPopoverPresentationControllerDelegate>
@end

@implementation SGSpeedPitchPanel
- (void)loadView {
    SGSpeedPitchView *block = [SGSpeedPitchView new];
    block.panelOnly = YES;
    self.view = block;
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
                                                               traitCollection:(UITraitCollection *)traits {
    return UIModalPresentationNone;
}
@end

void SGPlayerShowSpeedPitchPanel(UIView *from) {
    if (!from.window) return;
    SGSpeedPitchPanel *panel = [SGSpeedPitchPanel new];
    panel.modalPresentationStyle = UIModalPresentationPopover;
    panel.preferredContentSize = CGSizeMake(320, kGrid + 3 * kSliderBlockHeight + kSwitchRowHeight + kPanelBottom);
    UIPopoverPresentationController *popover = panel.popoverPresentationController;
    popover.sourceView = from;
    popover.sourceRect = from.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionUp | UIPopoverArrowDirectionDown;
    popover.delegate = panel;
    SGPresentDark(panel);
    // Picked from the system menu, which is still going away: the panel waits for it.
    __block int tries = 0;
    __block void (^present)(void);
    present = ^{
        UIViewController *top = SGTopController();
        if ((top.isBeingDismissed || top.isBeingPresented || top.transitionCoordinator) && ++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), present);
            return;
        }
        present = nil;
        [top presentViewController:panel animated:YES completion:nil];
    };
    dispatch_async(dispatch_get_main_queue(), present);
}

#pragma mark - the player's more button

@interface SGMoreTapWatcher : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SGMoreTapWatcher
- (void)tapped {
    sg_moreTappedAt = CACurrentMediaTime();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

static void watchMoreButton(UIView *button) {
    if (!button || objc_getAssociatedObject(button, &kWatchedKey)) return;
    static SGMoreTapWatcher *watcher;
    if (!watcher) watcher = [SGMoreTapWatcher new];
    objc_setAssociatedObject(button, &kWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A control (Spotify's ⋯ is an Encore button, a UIControl) is watched through its own events alone, from
    // the touch down on: a recognizer on it, even one that cancels and delays nothing, took part in its touches
    // (a ripple on the ⋯ on the phone).
    if ([button isKindOfClass:UIControl.class]) {
        // Touch down alone: a touch up after the ⋯ card has used the tap up would count a second time, for the
        // next sheet (the card's Sleep timer took the block that way on the phone).
        [(UIControl *)button addTarget:watcher action:@selector(tapped) forControlEvents:UIControlEventTouchDown];
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(tapped)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = watcher;
    [button addGestureRecognizer:tap];
}

#pragma mark - the menu

static void logStructure(UIView *view, int depth, NSMutableString *out) {
    if (depth > 6 || out.length > 3000) return;
    [out appendFormat:@"\n%*s%@ %@", depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UITableViewCell.class]) {
            [out appendFormat:@"\n%*scell %@", (depth + 1) * 2, "", NSStringFromCGRect(child.frame)];
            continue;
        }
        logStructure(child, depth + 1, out);
    }
}

static UITableView *findTable(UIView *root, int depth) {
    if ([root isKindOfClass:UITableView.class]) return (UITableView *)root;
    if (depth > 5) return nil;
    for (UIView *child in root.subviews) {
        UITableView *table = findTable(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

static BOOL isPlayerMenu(UIViewController *menu) {
    NSNumber *decided = objc_getAssociatedObject(menu, &kDecidedKey);
    if (decided) return decided.boolValue;
    // The tap is used up by the menu it opened, so a sheet that menu opens in turn is not taken for it.
    BOOL ours = sg_moreTappedAt && CACurrentMediaTime() - sg_moreTappedAt < kMenuAfterTap;
    if (ours) sg_moreTappedAt = 0;
    objc_setAssociatedObject(menu, &kDecidedKey, @(ours), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *presenter = menu.navigationController.presentingViewController ?: menu.presentingViewController;
    SGLog(@"speed and pitch: a context menu, %@ (tapped %d, presented by %@)", ours ? @"the player's" : @"not the player's", ours,
          presenter ? NSStringFromClass(presenter.class) : @"nothing");
    return ours;
}

void SGPlayerMenuMarkPlayers(void) {
    sg_moreTappedAt = CACurrentMediaTime();
}

BOOL SGPlayerMenuIsPlayers(UIViewController *menu) {
    return isPlayerMenu(menu);
}

#pragma mark - Spotify's rows

// The sheet keeps its spinner up until Spotify's rows are in, and they are in when every item factory
// has answered or run out of time: ContextMenuItemFactory holds a timer, and the timeout is the remote
// config's ios-feature-contextmenu-platform.timeout (SPTContextMenu_InternalImplProperties reads it
// between 1 and 60 s, 10 when the server says nothing). The block takes no part in that: it goes into
// the table's header once and stays, and a sheet that gets its rows seconds later shows them under it
// (harness/menu `loading`). So a menu that waits is timed from here, to tell a wait on Spotify's
// factories from a main thread kept busy: each check says how late it ran.
static NSInteger rowCount(UITableView *table) {
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) rows += [table numberOfRowsInSection:section];
    return rows;
}

static BOOL spinning(UIView *view, int depth) {
    if ([view isKindOfClass:UIActivityIndicatorView.class]) return ((UIActivityIndicatorView *)view).isAnimating && !view.isHidden && view.alpha > 0.01;
    if (depth > 6) return NO;
    for (UIView *child in view.subviews) {
        if (spinning(child, depth + 1)) return YES;
    }
    return NO;
}

// Once, when the rows are first seen, and said only when they were late.
static void noteRows(UIViewController *menu, UITableView *table) {
    NSNumber *shownAt = objc_getAssociatedObject(menu, &kShownAtKey);
    if (!shownAt || objc_getAssociatedObject(menu, &kRowsInKey) || !table || rowCount(table) == 0) return;
    objc_setAssociatedObject(menu, &kRowsInKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSTimeInterval after = CACurrentMediaTime() - shownAt.doubleValue;
    if (after > 0.5) SGLog(@"speed and pitch: Spotify's rows came in %.1f s after the menu appeared", after);
}

static void watchRows(UIViewController *menu) {
    if (objc_getAssociatedObject(menu, &kShownAtKey)) return;
    objc_setAssociatedObject(menu, &kShownAtKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITableView *table = findTable(menu.view, 0);
    if (table && rowCount(table)) {
        objc_setAssociatedObject(menu, &kRowsInKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    __weak UIViewController *weakMenu = menu;
    for (NSNumber *wait in @[@2, @6, @15, @40]) {
        CFTimeInterval due = CACurrentMediaTime() + wait.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *shown = weakMenu;
            if (!shown.viewIfLoaded.window || objc_getAssociatedObject(shown, &kRowsInKey)) return;
            UITableView *rows = findTable(shown.view, 0);
            noteRows(shown, rows);
            if (objc_getAssociatedObject(shown, &kRowsInKey)) return;
            SGLog(@"speed and pitch: no rows of Spotify's %@ s after the menu appeared (this check ran %.2f s late), spinner %@, table %.0fx%.0f holding %.0f",
                  wait, CACurrentMediaTime() - due, spinning(shown.view, 0) ? @"spinning" : @"not spinning",
                  rows.bounds.size.width, rows.bounds.size.height, rows.contentSize.height);
        });
    }
}

static void install(UIViewController *menu) {
    UIView *root = menu.viewIfLoaded;
    if (!root || !isPlayerMenu(menu)) return;
    // Shown as the system menu, whose own items are speed, pitch and reverb.
    if (SGPlayerMenuReplaced(menu)) return;
    UITableView *table = findTable(root, 0);
    SGSpeedPitchView *block = objc_getAssociatedObject(menu, &kBlockKey);
    if (!table) {
        static int logged;
        if (logged++ < 3) SGLog(@"speed and pitch: no table in %@, speed and pitch left out", NSStringFromClass(menu.class));
        return;
    }
    CGFloat width = table.bounds.size.width;
    if (width <= 0) return;
    if (!block) {
        static BOOL described;
        if (!described) {
            described = YES;
            NSMutableString *structure = [NSMutableString string];
            logStructure(root, 0, structure);
            SGLog(@"speed and pitch: table %@ header %@ footer %@, structure:%@", NSStringFromClass(table.class),
                  table.tableHeaderView ? NSStringFromClass(table.tableHeaderView.class) : @"none",
                  table.tableFooterView ? NSStringFromClass(table.tableFooterView.class) : @"none", structure);
        }
        BOOL headerFree = !table.tableHeaderView || table.tableHeaderView.bounds.size.height < 1;
        BOOL footerFree = !table.tableFooterView || table.tableFooterView.bounds.size.height < 1;
        if (!headerFree && !footerFree) {
            SGLog(@"speed and pitch: the table's header and footer are both Spotify's, speed and pitch left out");
            objc_setAssociatedObject(menu, &kDecidedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        block = [[SGSpeedPitchView alloc] initWithFrame:CGRectMake(0, 0, width, [SGSpeedPitchView heightOpen:sg_open])];
        block.table = table;
        block.inFooter = !headerFree;
        objc_setAssociatedObject(menu, &kBlockKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (block.inFooter) table.tableFooterView = block;
        else table.tableHeaderView = block;
        [table invalidateIntrinsicContentSize];
        return;
    }
    noteRows(menu, table);
    // Spotify replaced the view, or the table changed width: put it back at the table's width.
    UIView *placed = block.inFooter ? table.tableFooterView : table.tableHeaderView;
    if (placed != block) {
        static int logged;
        if (logged++ < 3) SGLog(@"speed and pitch: the table's %@ became %@, speed and pitch put back", block.inFooter ? @"footer" : @"header",
                                placed ? NSStringFromClass(placed.class) : @"nothing");
    }
    if (placed != block || fabs(block.frame.size.width - width) > 0.5) {
        block.frame = CGRectMake(0, block.frame.origin.y, width, [SGSpeedPitchView heightOpen:sg_open]);
        if (block.inFooter) table.tableFooterView = block;
        else table.tableHeaderView = block;
        [table invalidateIntrinsicContentSize];
    }
}

// The player's header row: its more button found by its identifier and watched, under either look.
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *row = ((UIViewController *)self).viewIfLoaded;
    static __weak UIView *watched;
    if (watched && [watched isDescendantOfView:row]) return;
    __block UIView *more = nil;
    SGForEachView(row, ^(UIView *view) {
        if (!more && [view.accessibilityIdentifier isEqualToString:@"Context menu"]) more = view;
    });
    watchMoreButton(more);
    if (more) watched = more;
}
%end

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    install((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGSpeedPitchView *block = objc_getAssociatedObject(self, &kBlockKey);
    [block refresh];
    if (block) watchRows((UIViewController *)self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController", @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"]);
}
