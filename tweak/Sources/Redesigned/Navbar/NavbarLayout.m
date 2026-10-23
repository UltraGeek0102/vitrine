// The saved composition of the redesign's bar, as NSUserDefaults property lists, apart from the native look's.
#import "Navbar.h"
#import "Shared/Navigation/Links.h"

NSString *const SGRNavbarID = @"id";
NSString *const SGRNavbarTitle = @"title";
NSString *const SGRNavbarURI = @"uri";
NSString *const SGRNavbarIcon = @"icon";
NSString *const SGRNavbarIconSet = @"iconSet";
NSString *const SGRNavbarHidden = @"hidden";

static NSString *const kNavbarLayout = @"spotifyglass.redesign.navbar.layout";
static NSString *const kNavbarStock = @"spotifyglass.redesign.navbar.stock";
static NSString *const kNavbarSplit = @"spotifyglass.redesign.navbar.apart";
static NSString *const kNavbarSplitWas = @"spotifyglass.redesign.navbar.split";

// Only property list types go in, so a corrupt read cannot be anything but an array of dictionaries.
static NSArray *listOfKind(NSString *key, Class kind) {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:key];
    for (id item in list) if (![item isKindOfClass:kind]) return @[];
    return list ?: @[];
}

NSArray<NSDictionary *> *SGRNavbarLayout(void) {
    return listOfKind(kNavbarLayout, NSDictionary.class);
}

void SGRSetNavbarLayout(NSArray<NSDictionary *> *layout) {
    [NSUserDefaults.standardUserDefaults setObject:layout ?: @[] forKey:kNavbarLayout];
}

// A tab of the mod's own leaves the bar's list with its entry; one of Spotify's is named by its identity. The bar's order
// is kept: it was the order on the right. A hidden tab was shown nowhere, set apart or not, and stays where it is,
// hidden: the split list shows whatever is on it, so the bar looks as it did.
void SGRMigrateNavbarSplit(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if (![store objectForKey:kNavbarSplitWas]) return;
    if ([store objectForKey:kNavbarSplit]) {
        [store removeObjectForKey:kNavbarSplitWas];
        return;
    }
    NSMutableOrderedSet<NSString *> *split = [NSMutableOrderedSet orderedSetWithArray:listOfKind(kNavbarSplitWas, NSString.class)];
    NSMutableArray<NSDictionary *> *layout = [NSMutableArray array], *apart = [NSMutableArray array];
    for (NSDictionary *entry in SGRNavbarLayout()) {
        NSString *ident = entry[SGRNavbarID];
        BOOL listed = [ident isKindOfClass:NSString.class] && [split containsObject:ident];
        if (listed) [split removeObject:ident];
        if (!listed || [entry[SGRNavbarHidden] boolValue]) {
            [layout addObject:entry];
            continue;
        }
        if (entry[SGRNavbarURI]) [apart addObject:entry];
        else {
            [layout addObject:entry];
            [apart addObject:@{SGRNavbarID: ident, SGRNavbarTitle: entry[SGRNavbarTitle] ?: ident}];
        }
    }
    // Spotify's tabs the bar's list never named stood where Spotify put them: in Spotify's order, not the old list's,
    // which was saved from a set and so in none.
    NSArray<NSString *> *stock = SGRNavbarStock();
    NSArray<NSString *> *rest = [split.array sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger ia = [stock indexOfObject:a], ib = [stock indexOfObject:b];
        return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSString *ident in rest) [apart addObject:@{SGRNavbarID: ident, SGRNavbarTitle: ident}];
    SGRSetNavbarLayout(layout);
    SGRSetNavbarSplit(apart);
    [store removeObjectForKey:kNavbarSplitWas];
}

NSArray<NSDictionary *> *SGRNavbarSplit(void) {
    return listOfKind(kNavbarSplit, NSDictionary.class);
}

void SGRSetNavbarSplit(NSArray<NSDictionary *> *split) {
    [NSUserDefaults.standardUserDefaults setObject:split ?: @[] forKey:kNavbarSplit];
}

NSArray<NSString *> *SGRNavbarStock(void) {
    return listOfKind(kNavbarStock, NSString.class);
}

void SGRSetNavbarStock(NSArray<NSString *> *stock) {
    [NSUserDefaults.standardUserDefaults setObject:stock ?: @[] forKey:kNavbarStock];
}

NSURL *SGRNavbarTabURL(NSString *uri) {
    NSURL *url = SGSpotifyURIFromText(uri);
    if ([url.absoluteString isEqualToString:@"spotify:collection:playlists"]) return [NSURL URLWithString:@"spotify:playlists"];
    return url;
}
