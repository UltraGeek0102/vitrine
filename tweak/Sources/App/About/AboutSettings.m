#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "App/Onboarding/Onboarding.h"

// Every key of the mod's is under one prefix, so a reset is a sweep of the defaults with the stock
// marker of SGPrefs.h left behind; the hooks read them at launch, so it ends in a restart.
static void resetAll(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSUInteger removed = 0;
    for (NSString *key in [store persistentDomainForName:NSBundle.mainBundle.bundleIdentifier].allKeys) {
        if (![key hasPrefix:@"spotifyglass."]) continue;
        [store removeObjectForKey:key];
        removed++;
    }
    [store setBool:YES forKey:SGKeyStock];
    SGLog(@"reset: removed %lu keys", (unsigned long)removed);
    SGRestartSpotify();
}

static void confirmReset(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset all settings?"
                                                                  message:@"Every switch goes off, flag overrides and the tab bar layout are cleared, and Spotify restarts as it came, with the mod doing nothing until asked. Spotify's own settings are untouched."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset and restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { resetAll(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModRow *withSymbol(SGModRow *row, NSString *symbol) {
    row.symbol = symbol;
    return row;
}

// Which build this is, whether GitHub has a newer release, and where to reach the mod: without these
// rows a build that is already installed has no way of telling its user that anything moved on.
UIViewController *SGAboutPage(void) {
    SGModRow *reset = withSymbol(SGActionRow(@"Reset all settings", nil, ^{ confirmReset(); }), @"trash");
    reset.color = SGRed();
    NSString *spotify = SGSpotifyVersion();
    if ([SGSpotifyLikelyWorksVersions containsObject:spotify]) spotify = [spotify stringByAppendingString:@", likely works"];
    else if (![SGSpotifySupportedVersions containsObject:spotify]) spotify = [NSString stringWithFormat:@"%@, made for %@", spotify, SGSpotifyMadeFor];
    // The row reads out where the build stands and opens the changelog of everything newer than it.
    SGModRow *updates = SGPageRow(@"Updates", ^UIViewController *{ return SGUpdatePage(); });
    updates.value = ^NSString *{ return SGUpdateStatus(); };
    // A release build can opt into betas; a beta build starts opted in. Either way a check follows at
    // once, since the stored list only holds what counted at the last one.
    SGModRow *betas = SGSwitchRow(@"Include betas", @"Offer test builds ahead of each release", SGKeyUpdateBetas);
    betas.defaultOn = SGBuildIsBeta();
    betas.changed = ^(BOOL on) { SGCheckForUpdate(YES); };
    NSMutableArray<SGModRow *> *links = [NSMutableArray array];
    if (SGRepoURL) [links addObject:withSymbol(SGLinkRow(@"GitHub", nil, SGRepoURL), @"chevron.left.forwardslash.chevron.right")];
    [links addObjectsFromArray:@[
        withSymbol(SGPageRow(@"Licenses", ^UIViewController *{ return SGLicensesPage(); }), @"doc.text"),
        withSymbol(SGActionRow(@"Welcome tour", nil, ^{ SGShowOnboarding(); }), @"map"),
    ]];
    if (SGWhatsNewChanges().count) [links insertObject:withSymbol(SGActionRow(@"What's New", nil, ^{ SGShowWhatsNew(); }), @"sparkles") atIndex:links.count - 1];
    NSMutableArray<SGModRow *> *build = [NSMutableArray arrayWithObjects:updates, betas,
        SGStatRow(@"Version", ^NSString *{ return @(SG_VERSION); }),
        SGStatRow(@"Spotify", ^NSString *{ return spotify; }), nil];
    SGModRow *signedUntil = SGSigningExpiryRow();
    if (signedUntil) [build addObject:signedUntil];
    return [[SGModPage alloc] initWithTitle:@"Mod" intro:nil sections:@[
        SGSection(nil, build),
        SGSection(nil, links),
        SGSection(nil, @[
            withSymbol(SGActionRow(@"Export settings", nil, ^{ SGExportSettings(); }), @"square.and.arrow.up"),
            withSymbol(SGActionRow(@"Import settings", nil, ^{ SGImportSettings(); }), @"square.and.arrow.down"),
        ]),
        SGSection(nil, @[reset]),
    ] footer:nil];
}
