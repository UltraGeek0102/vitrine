// Onboarding: a welcome page over Home the first time this build runs, in glass: Vitrine's logo landing,
// then a pick between the redesign (offered first on iOS 26) and Spotify's own look, and a line on
// holding Home for Mod Settings. The look is picked at launch, so a changed pick ends the welcome in a
// restart. After an update instead, a What's new sheet lists what the version brought. The Mod page
// offers both again.
#import <UIKit/UIKit.h>

#define SGKeyOnboardingSeen @"spotifyglass.onboarding.seen"
// The version whose What's new was last shown, or skipped because the tour came first.
#define SGKeyWhatsNewSeen @"spotifyglass.whatsnew.seen"

// Presents the tour over the top of the app; does nothing while it is already up.
void SGShowOnboarding(void);
// The tour or What's new holds the screen; other sheets wait for it (App/About).
BOOL SGOnboardingShowing(void);

// WhatsNew.m: this build's section of CHANGELOG.md, read through App/About/Update.m's parser; empty for a
// build with no section of its own, which then has no sheet and no row.
@class SGUpdateChange;
NSArray<SGUpdateChange *> *SGWhatsNewChanges(void);
void SGShowWhatsNew(void);
BOOL SGWhatsNewShowing(void);

// Environment.m: what about the install can work against the mod. Said once per install state, a few
// seconds after Spotify comes up and behind the tour, What's new and the signing sheet, and kept as
// warning rows at the top of Mod Settings while it lasts.
#define SGSpotifyMadeFor @"9.1.78"   // the Spotify this build is made for, and its flag table read from
#define SGSpotifyLikelyWorks @"9.1.88"   // a newer Spotify that ran cleanly in a short test: no warning for it
@class SGModRow;
// SGEeveeSpotifyInjected() is Shared/Lyrics/Lyrics.h's.
NSString *SGSpotifyVersion(void);
NSArray<SGModRow *> *SGEnvironmentWarningRows(void);
void SGCheckEnvironmentOnce(void);

// The tour's prominent glass button, also What's new's Continue.
UIButton *SGOnboardingButton(NSString *title);
