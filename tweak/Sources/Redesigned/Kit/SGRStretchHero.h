// A page header's picture across the top of the page that stretches when the page is pulled down, the Music
// app's: the album's (Album/AlbumHeader.x) and the artist's (Artist/ArtistHeader.x) build on it. The playlist's
// is its own (Playlist/PlaylistHeader.x): its stretch comes from Spotify's plane growing, not from the list.
//
// What it draws: `content`, where a subclass puts the picture and anything else that should dissolve (an
// animated cover), with its bottom masked away so the field shows through whatever color it is at that height
// -- a fade to the field's flat color showed as an edge pulled down, where the still field is fading to black
// (issue #169) -- and over it a scrim for the status bar. Only `content` is masked, so the scrim and whatever a
// subclass puts beside it (a shadow) are not drawn in the mask's offscreen pass.
//
// The mask is an opaque part and under it a dissolve of a fixed height, round(restHeight * SGRStretchHeroDissolve),
// pinned to the bottom with fixed stops: 0.28 of the picture left at 0.62 of the way, the curve the color fade
// had. Pulled down, the hero grows upward by the pull and only frames move: the opaque part grows, the dissolve
// keeps its height on the bottom, where the text is.
//
// The pull: the nearest scroll view above the hero (the page's list), whose contentOffset is watched while the
// hero is in a window and let go when it leaves. A step that is not a pull and follows none costs the scroll a
// read of the offset and a comparison. The host the hero sits in is assumed to move with the list's content,
// so the pull is how far above the host's top the hero has to reach; the first stretch past 24pt says once per
// page kind whether a view between the host and the list clips, which would cut the stretch off.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// How much of the rest height the dissolve covers; the scrim's height and its darkness at the top. The
// playlist's numbers (Playlist/PlaylistHeader.x keeps its own copy): one page.
extern const CGFloat SGRStretchHeroDissolve, SGRStretchHeroScrim, SGRStretchHeroScrimAlpha;

@interface SGRStretchHero : UIView
// Where the picture goes: the hero's bounds, masked at the bottom while `dissolves`. Laid out by the hero
// before a subclass's -layoutSubviews goes on from [super layoutSubviews].
@property (nonatomic, readonly) UIView *content;
// Over `content`, unmasked. A subclass may hide it.
@property (nonatomic, readonly) CAGradientLayer *scrim;
// Whether `content` is masked: YES unless a subclass turns it off (a square cover, whose square reaches into
// the dissolve). The one place the mask is assigned, and only when this changes.
@property (nonatomic) BOOL dissolves;
// The hero's height at rest, from the host's pass; -sgr_place adds the pull to it. Below 1, nothing is placed.
@property (nonatomic) CGFloat restHeight;
// How far the list is pulled down past its top, 0 without a list. What the hero grows upward by.
@property (nonatomic, readonly) CGFloat pull;
// How much taller than restHeight the hero is now: the pull it was last placed for, from its bounds.
@property (nonatomic, readonly) CGFloat stretch;
// The page in the one-time clip log line ("album", "artist").
@property (nonatomic, copy) NSString *logName;

// Its frame in its superview: the top of it and restHeight at rest, and pulled down, from `pull` above the top
// down to the same bottom. Writes nothing unless the frame changed. For the host's passes; the hero calls it
// itself on the list's steps.
- (void)sgr_place;
// The dissolve comes in from opaque all the way down, over `duration` on `curve`: for a mask that has just
// been turned on over a picture already showing, so nothing is cut into at once.
- (void)revealDissolveOver:(CFTimeInterval)duration curve:(CAMediaTimingFunction *)curve;
// For a subclass: called on every step of the list's offset, after the hero has been placed. Does nothing here.
- (void)listDidScroll;
@end
