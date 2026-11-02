// The artwork field: one continuous color taken from the artwork (SGRPalette.h) behind a whole
// redesigned page, with no card and no seam anywhere. The player's field also carries the
// artwork itself at the top, blurred and dimmed and dissolving into the color (showsBackdrop).
//
// Nothing is blurred live and nothing is masked: the view draws a solid color layer, a black gradient
// layer (the redesign is AMOLED throughout, fading the color to black down the page) and at most one
// bitmap layer rendered off the main thread, so it costs a few composited layers while the page moves. A new color or bitmap crossfades over
// SGRCrossfade; the same image again is a no-op.
//
// Ownership: the screen that installs a field owns it (usually retained by its superview and an
// associated object). The field retains its last image and palette only.
// Threading: main thread only; the palette work it starts runs off it.
#import <UIKit/UIKit.h>

@interface SGRArtworkField : UIView
// Where the color, the fade to black and the backdrop reach past the bounds (overscroll, a plane
// that does not clip): positive values draw outside. The field never clips.
@property (nonatomic) UIEdgeInsets bleed;
@property (nonatomic) BOOL showsBackdrop;
// The player's moving field instead of the still backdrop (SGRFlow.h): the artwork's colors drifting
// over the whole of the bounds, with no fade to black. It moves only while the field is in a window,
// the app is in front, the player is not opening or closing, Reduce Motion and Low Power Mode are off
// and nothing holds it (motionHeld); otherwise it stays still where it was.
@property (nonatomic) BOOL flows;
// Fluid artwork instead (SGRFluid.h): the cover itself blurred and slowly turning over the whole of the
// bounds, under the same conditions for moving as `flows`. Setting one turns the other off.
@property (nonatomic) BOOL fluid;
// Held still by the owner (the player while playback is paused, or while an Animated artwork clip covers
// the field).
@property (nonatomic) BOOL motionHeld;
// Covered by something opaque the owner lays over the whole of the bounds (the player's Animated artwork
// clip): the Fluid copies are hidden rather than composited under it for nothing, and come back where they
// were when it is NO again. Set it only once the cover is opaque, and back before it starts to fade.
@property (nonatomic) BOOL covered;
// The backdrop's height in points from the top of the bounds; 0 is the window's height.
@property (nonatomic) CGFloat backdropHeight;
// SGRNeutralField until a color arrives.
@property (nonatomic, readonly) UIColor *fieldColor;

// The color from the artwork's main color rather than its bottom edge (SGRPaletteRequest's mainColor): a
// playlist, album or artist page, whose cover dissolves into the field. The player keeps the edge, where its
// backdrop meets the color. Set before the first artwork.
@property (nonatomic) BOOL mainColor;

// A color Spotify already has for the page (the player's background color, the album's wash), made fit
// to be a field and shown until the first artwork has been read; ignored after that.
- (void)setProvisionalColor:(UIColor *)color;
// Reads the artwork off the main thread and crossfades the result in (without animation when
// `animated` is NO or the field is not in a window). The same image, or the same non-nil identity,
// as the last call is a no-op, and a result that lands after a newer call is dropped. nil keeps
// what the field shows.
- (void)setArtwork:(UIImage *)image identity:(NSString *)identity animated:(BOOL)animated;

// A page that comes in whole rather than a piece at a time: until the field has read its first artwork, a veil
// of the neutral field lies over everything `page` holds but its pinned ⋯ (SGRPinnedMore), and then fades away
// at once, with the cover, the color and the text that arrived under it. The back button is the navigation
// bar's, outside the page, and stays. A page whose artwork never comes is shown after SGRFieldHoldLimit, and
// one that knows it has none releases itself (-showPage). Called from the page's own pass, which keeps the
// veil on top; nothing once the page has been shown, so a page coming back is never held again.
- (void)holdPage:(UIView *)page;
- (void)showPage;
@end

// How long a page waits for its artwork before it is shown anyway. The Music app shows something at once
// (HIG, Loading: "Show something as soon as possible"), so the wait is short; a page then loads as it used to.
extern const NSTimeInterval SGRFieldHoldLimit;
