#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Navbar.h"
#import "Shared/Navigation/AddTabSheet.h"
#import "Redesigned/Kit/SGRTokens.h"

// What "Add a tab" offers: URIs Spotify's own router resolves to a page of its own, each with the
// name of the SPTEncoreIcon class method that draws its glyph. Playlists was spotify:collection:playlists
// until 0.20, which 9.1.78 knows only from its old iPad sidebar table and has no handler for (#66);
// spotify:playlists is the form its collection URI parser lists, next to spotify:playlists:by-you.
// The picker still asks the dispatcher about each one and leaves out what it has nowhere to send.
static NSArray<NSDictionary *> *tabPresets(void) {
    return @[
        @{SGTabTitle: @"Home", SGTabURI: @"spotify:home", SGTabIcon: @"home"},
        @{SGTabTitle: @"Search", SGTabURI: @"spotify:search", SGTabIcon: @"search"},
        @{SGTabTitle: @"Your Library", SGTabURI: @"spotify:collection", SGTabIcon: @"collection"},
        @{SGTabTitle: @"Liked Songs", SGTabURI: @"spotify:collection:tracks", SGTabIcon: @"heart"},
        @{SGTabTitle: @"Playlists", SGTabURI: @"spotify:playlists", SGTabIcon: @"playlist"},
        @{SGTabTitle: @"Albums", SGTabURI: @"spotify:collection:albums", SGTabIcon: @"album"},
        @{SGTabTitle: @"Artists", SGTabURI: @"spotify:collection:artists", SGTabIcon: @"artist"},
        @{SGTabTitle: @"Podcasts", SGTabURI: @"spotify:collection:podcasts", SGTabIcon: @"podcasts"},
        @{SGTabTitle: @"Audiobooks", SGTabURI: @"spotify:collection:audiobooks", SGTabIcon: @"audiobook"},
        @{SGTabTitle: @"Downloads", SGTabURI: @"spotify:collection:downloads", SGTabIcon: @"downloaded"},
        @{SGTabTitle: @"Your Episodes", SGTabURI: @"spotify:collection:your-episodes", SGTabIcon: @"bookmark"},
        @{SGTabTitle: @"Browse", SGTabURI: @"spotify:browse", SGTabIcon: @"browse"},
        @{SGTabTitle: @"New Releases", SGTabURI: @"spotify:new-releases", SGTabIcon: @"star"},
        @{SGTabTitle: @"Made For You", SGTabURI: @"spotify:made-for-you", SGTabIcon: @"user"},
        @{SGTabTitle: @"Concerts", SGTabURI: @"spotify:concerts", SGTabIcon: @"events"},
        @{SGTabTitle: @"Queue", SGTabURI: @"spotify:now-playing:queue", SGTabIcon: @"queue"},
        @{SGTabTitle: @"Create", SGTabURI: @"spotify:create-menu", SGTabIcon: @"plus"},
    ];
}

// The list the Navbar page edits: the saved order first, then every tab of Spotify's it does not
// name, in Spotify's order. Entries for tabs Spotify no longer has drop out.
static NSMutableArray<NSMutableDictionary *> *navbarEntries(void) {
    NSArray<NSString *> *stock = SGRNavbarStock();
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *entry in SGRNavbarLayout()) {
        NSString *ident = entry[SGRNavbarID];
        if (![ident isKindOfClass:NSString.class] || [seen containsObject:ident]) continue;
        if (!entry[SGRNavbarURI] && ![stock containsObject:ident]) continue;
        [seen addObject:ident];
        [entries addObject:[entry mutableCopy]];
    }
    for (NSString *ident in stock) {
        if ([seen containsObject:ident]) continue;
        [entries addObject:[@{SGRNavbarID: ident, SGRNavbarTitle: ident} mutableCopy]];
    }
    return entries;
}

// A tab of the mod's own carries an identity of its own, so the same page can sit on the bar twice
// and renaming one does not shuffle the order.
static NSMutableDictionary *tabEntry(NSDictionary *tab) {
    NSMutableDictionary *entry = [@{SGRNavbarID: NSUUID.UUID.UUIDString, SGRNavbarTitle: tab[SGTabTitle],
                                    SGRNavbarURI: tab[SGTabURI], SGRNavbarIcon: tab[SGTabIcon]} mutableCopy];
    entry[SGRNavbarIconSet] = tab[SGTabIconSet];
    return entry;
}

static void appendTab(NSDictionary *tab) {
    SGRSetNavbarLayout([navbarEntries() arrayByAddingObject:tabEntry(tab)]);
    SGRRefreshTabBar();
}

// The identities of Spotify's own tabs that stand in the split list: they leave the bar's list while they do.
static NSSet<NSString *> *splitStockIDs(void) {
    NSMutableSet<NSString *> *idents = [NSMutableSet set];
    for (NSDictionary *entry in SGRNavbarSplit()) if (!entry[SGRNavbarURI] && entry[SGRNavbarID]) [idents addObject:entry[SGRNavbarID]];
    return idents;
}

// The Add a Tab sheet's tab for an entry of the mod's own, and the entry it gives back, keeping its identity and place.
static NSDictionary *sheetTab(NSDictionary *entry) {
    NSMutableDictionary *tab = [@{SGTabTitle: entry[SGRNavbarTitle] ?: @"", SGTabURI: entry[SGRNavbarURI], SGTabIcon: entry[SGRNavbarIcon] ?: @"star"} mutableCopy];
    tab[SGTabIconSet] = entry[SGRNavbarIconSet];
    return tab;
}

static NSMutableDictionary *editedEntry(NSDictionary *entry, NSDictionary *edited) {
    NSMutableDictionary *now = [entry mutableCopy];
    now[SGRNavbarTitle] = edited[SGTabTitle];
    now[SGRNavbarURI] = edited[SGTabURI];
    now[SGRNavbarIcon] = edited[SGTabIcon];
    now[SGRNavbarIconSet] = edited[SGTabIconSet];
    return now;
}

// Takes a tab of Spotify's off the split list.
static void hideFromSplit(NSString *ident) {
    if (![splitStockIDs() containsObject:ident]) return;
    NSMutableArray<NSDictionary *> *split = [NSMutableArray array];
    for (NSDictionary *entry in SGRNavbarSplit()) if (entry[SGRNavbarURI] || ![entry[SGRNavbarID] isEqual:ident]) [split addObject:entry];
    SGRSetNavbarSplit(split);
}

// A tab of Spotify's moved over to the split list is shown there, so it is not left hidden on the bar's list: the
// editor would have it both hidden and apart.
static void showStockTab(NSString *ident) {
    NSMutableArray<NSDictionary *> *layout = [SGRNavbarLayout() mutableCopy];
    for (NSUInteger i = 0; i < layout.count; i++) {
        if (![layout[i][SGRNavbarID] isEqual:ident] || ![layout[i][SGRNavbarHidden] boolValue]) continue;
        NSMutableDictionary *shown = [layout[i] mutableCopy];
        [shown removeObjectForKey:SGRNavbarHidden];
        layout[i] = shown;
        SGRSetNavbarLayout(layout);
        return;
    }
}

static UIImage *glyphFor(NSDictionary *entry, BOOL active);

// Split tabs: the tabs set apart at the trailing end of the bar, a list of their own, in the order they stand on the
// right, which the handles change. A tab is added the way one is added to the bar (the same Add a Tab sheet) and is
// not on the bar's list, so removing it from either leaves the other alone; a tap on one opens it in that sheet to
// rename it, change its icon or remove it, as on the bar's page. Spotify's own tabs can be moved over from the third
// section; a tab of Spotify's stands in one place only, so it leaves the bar while it is here and comes back when it
// is removed. It comes over shown: the split list shows whatever is on it.
typedef NS_ENUM(NSInteger, SGRSplitSection) {
    SGRSplitSectionApart,
    SGRSplitSectionAdd,
    SGRSplitSectionStock,
    SGRSplitSectionCount,
};

@interface SGRSplitTabsPage : SGPage
@end

@implementation SGRSplitTabsPage {
    NSMutableArray<NSDictionary *> *_split;
    NSArray<NSString *> *_stock;   // Spotify's tabs that are not in the split list
    UIView *_intro;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Split Tabs";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    _intro = SGNote(@"Tabs here sit apart from the others at the right end of the bar, the way the Music "
                    "app sets Search apart. They are not on the bar's own list.");
    self.tableView.tableHeaderView = _intro;
    [self load];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)load {
    _split = [SGRNavbarSplit() mutableCopy];
    NSSet<NSString *> *taken = splitStockIDs();
    NSMutableArray<NSString *> *stock = [NSMutableArray array];
    for (NSString *ident in SGRNavbarStock()) if (![taken containsObject:ident]) [stock addObject:ident];
    _stock = stock;
}

- (void)save {
    SGRSetNavbarSplit(_split);
    SGRRefreshTabBar();
    [self load];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGRSplitSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGRSplitSectionAdd) return 1;
    return (NSInteger)(section == SGRSplitSectionApart ? _split.count : _stock.count);
}

- (NSString *)headerFor:(NSInteger)section {
    if (section == SGRSplitSectionApart) return _split.count ? @"Apart, on the right" : nil;
    if (section == SGRSplitSectionStock) return _stock.count ? @"Spotify's tabs" : nil;
    return nil;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self headerFor:section];
    return title ? SGSectionHeader(table, title) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return [self headerFor:section] ? SGSectionHeaderHeight() : SGSectionGap;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"split");
    if (path.section == SGRSplitSectionAdd) {
        SGFillCell(cell, @"Add a tab", nil, SGRAccent(), nil);
        cell.accessibilityTraits = UIAccessibilityTraitButton;
    } else if (path.section == SGRSplitSectionApart) {
        NSDictionary *entry = _split[(NSUInteger)path.row];
        SGFillCell(cell, entry[SGRNavbarTitle], nil, nil, nil);
        UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
        content.image = glyphFor(entry, NO);
        content.imageProperties.tintColor = UIColor.whiteColor;
        content.imageProperties.maximumSize = CGSizeMake(24, 24);
        content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
        cell.contentConfiguration = content;
        cell.accessibilityHint = entry[SGRNavbarURI] ? @"Opens the tab to edit it" : nil;
    } else {
        SGFillCell(cell, _stock[(NSUInteger)path.row], nil, nil, nil);
        cell.accessibilityHint = @"Moves the tab to the right end of the bar";
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRSplitSectionApart;
}

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRSplitSectionApart;
}

// Dragged past either end of the list, the tab stops at that end.
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section == SGRSplitSectionApart) return to;
    return [NSIndexPath indexPathForRow:to.section < SGRSplitSectionApart ? 0 : (NSInteger)_split.count - 1 inSection:SGRSplitSectionApart];
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSDictionary *entry = _split[(NSUInteger)from.row];
    [_split removeObjectAtIndex:(NSUInteger)from.row];
    [_split insertObject:entry atIndex:(NSUInteger)to.row];
    SGRSetNavbarSplit(_split);
    SGRRefreshTabBar();
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRSplitSectionApart ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || path.section != SGRSplitSectionApart) return;
    [_split removeObjectAtIndex:(NSUInteger)path.row];
    [self save];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == SGRSplitSectionAdd) {
        __weak typeof(self) weakSelf = self;
        SGPresentAddTabSheet(self, tabPresets(), ^(NSDictionary *tab) {
            typeof(self) page = weakSelf;
            if (!page) return;
            [page->_split addObject:tabEntry(tab)];
            [page save];
        });
    } else if (path.section == SGRSplitSectionApart) {
        if (_split[(NSUInteger)path.row][SGRNavbarURI]) [self editRow:path.row];
    } else if (path.section == SGRSplitSectionStock) {
        NSString *ident = _stock[(NSUInteger)path.row];
        showStockTab(ident);
        [_split addObject:@{SGRNavbarID: ident, SGRNavbarTitle: ident}];
        [self save];
    }
}

// The row of the list as it is now with this identity; the list is read again on every save.
- (NSUInteger)rowWithID:(NSString *)ident {
    for (NSUInteger row = 0; row < _split.count; row++) if ([_split[row][SGRNavbarID] isEqualToString:ident]) return row;
    return NSNotFound;
}

// The Add a Tab sheet over one of the mod's own tabs, as the bar's page opens it: Save keeps its place and identity.
- (void)editRow:(NSInteger)row {
    NSDictionary *entry = _split[(NSUInteger)row];
    NSString *ident = entry[SGRNavbarID];
    __weak typeof(self) weakSelf = self;
    SGPresentEditTabSheet(self, tabPresets(), sheetTab(entry), ^(NSDictionary *edited) {
        typeof(self) page = weakSelf;
        NSUInteger now = [page rowWithID:ident];
        if (!page || now == NSNotFound) return;
        page->_split[now] = editedEntry(page->_split[now], edited);
        [page save];
    }, ^{
        typeof(self) page = weakSelf;
        NSUInteger now = [page rowWithID:ident];
        if (!page || now == NSNotFound) return;
        [page->_split removeObjectAtIndex:now];
        [page save];
    });
}

@end

#pragma mark - the preview

// Spotify's own tabs in Spotify's order, as entries, all shown: what the bar has with Custom tab bar off.
static NSArray<NSDictionary *> *stockEntries(void) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *ident in SGRNavbarStock()) [entries addObject:@{SGRNavbarID: ident, SGRNavbarTitle: ident}];
    return entries;
}

static UIImage *glyphFor(NSDictionary *entry, BOOL active) {
    return SGRNavbarGlyph(entry, active) ?: [UIImage systemImageNamed:@"square.dashed"];
}

static UITabBar *previewBar(void) {
    UITabBar *bar = [UITabBar new];
    // Dark whatever the system is, as TabBar.x's bars are.
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.userInteractionEnabled = NO;
    bar.tintColor = SGRAccent();
    return bar;
}

// TabBar.x's split bar: UIKit draws a bar's platter 21 pt in from its sides, a split tab takes a 62 pt circle,
// and the main bar runs under the split bar's leading inset to leave 12 pt between the two platters.
static const CGFloat kPlatterInset = 21, kApartItemWidth = 62, kPlatterGap = 12;

// The glass bar as it will look, drawn by the same system UITabBar TabBar.x puts over Spotify's bar, from the
// list as it stands on the page: the shown tabs in order, the first selected, the split tabs on a bar of
// their own, names under the glyphs unless Icons only is picked. It takes no touches.
@interface SGRTabBarPreview : UIView
- (void)showEntries:(NSArray<NSDictionary *> *)entries;
@end

@implementation SGRTabBarPreview {
    UITabBar *_main, *_apart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _main = previewBar();
    _apart = previewBar();
    [self addSubview:_main];
    [self addSubview:_apart];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Tab bar preview";
    return self;
}

static NSArray<UITabBarItem *> *itemsFor(NSArray<NSDictionary *> *entries, BOOL names) {
    NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:names ? entry[SGRNavbarTitle] : nil image:glyphFor(entry, NO) tag:(NSInteger)items.count];
        item.selectedImage = glyphFor(entry, YES);
        [items addObject:item];
    }
    return items;
}

// What Navbar.x composes from the same list: with nothing left shown, Spotify's own tabs come back.
- (void)showEntries:(NSArray<NSDictionary *> *)entries {
    BOOL custom = SGEnabled(SGRKeyNavbar), names = !SGHidden(SGRKeyNavbarHideLabels);
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray array];
    if (custom) for (NSDictionary *entry in entries) if (![entry[SGRNavbarHidden] boolValue]) [shown addObject:entry];
    if (!shown.count) [shown addObjectsFromArray:stockEntries()];
    NSSet<NSString *> *splitStock = custom ? splitStockIDs() : nil;
    NSMutableArray<NSDictionary *> *main = [NSMutableArray array], *apart = [NSMutableArray array];
    for (NSDictionary *entry in shown) if (![splitStock containsObject:entry[SGRNavbarID]]) [main addObject:entry];
    if (custom) [apart addObjectsFromArray:SGRNavbarSplit()];
    if (!main.count) {
        main = shown;
        apart = [NSMutableArray array];
    }
    [_main setItems:itemsFor(main, names) animated:NO];
    _main.selectedItem = _main.items.firstObject;
    [_apart setItems:itemsFor(apart, names) animated:NO];
    _apart.selectedItem = nil;
    _apart.hidden = !apart.count;
    self.accessibilityValue = [[shown valueForKey:SGRNavbarTitle] componentsJoinedByString:@", "];
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, [_main sizeThatFits:CGSizeMake(size.width, 49)].height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds, main = bounds, apart = CGRectZero;
    if (!_apart.hidden) {
        CGFloat width = MIN(bounds.size.width / 2, _apart.items.count * kApartItemWidth + 2 * kPlatterInset);
        CGRectDivide(bounds, &apart, &main, width, CGRectMaxXEdge);
        main.size.width += 2 * kPlatterInset - kPlatterGap;
    }
    _main.frame = main;
    _apart.frame = apart;
    for (UITabBar *bar in @[_main, _apart]) {
        [bar layoutIfNeeded];
        SGRShrinkTabTitles(bar);
    }
}

@end

#pragma mark - the labels' cards

// One of the two ways the bar can label its tabs, as a picture of the bar's first three tabs with or without
// their names, the choice's name under it and a check circle under that.
@interface SGRLabelCard : UIControl
@property (nonatomic, readonly) BOOL names;
- (instancetype)initWithTitle:(NSString *)title names:(BOOL)names;
- (void)showEntries:(NSArray<NSDictionary *> *)entries;
@end

@implementation SGRLabelCard {
    UIView *_picture;
    NSMutableArray<UIImageView *> *_glyphs;
    NSMutableArray<UIView *> *_bars;   // a gray bar under each glyph stands for its name
    UILabel *_title;
    UIImageView *_check;
}

static const CGFloat kPictureHeight = 76;

- (instancetype)initWithTitle:(NSString *)title names:(BOOL)names {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _names = names;
    _picture = [UIView new];
    _picture.backgroundColor = SGCardBackground();
    _picture.layer.cornerRadius = 18;
    _picture.layer.cornerCurve = kCACornerCurveContinuous;
    _picture.userInteractionEnabled = NO;
    [self addSubview:_picture];
    _glyphs = [NSMutableArray array];
    _bars = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        UIImageView *glyph = [UIImageView new];
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = UIColor.whiteColor;
        [_picture addSubview:glyph];
        [_glyphs addObject:glyph];
        UIView *bar = [UIView new];
        bar.backgroundColor = SGGrey();
        bar.layer.cornerRadius = 2;
        bar.hidden = !names;
        [_picture addSubview:bar];
        [_bars addObject:bar];
    }
    _title = [UILabel new];
    _title.text = title;
    _title.font = SGSubtitleFont();
    _title.textColor = UIColor.whiteColor;
    _title.textAlignment = NSTextAlignmentCenter;
    _title.adjustsFontSizeToFitWidth = YES;
    _title.minimumScaleFactor = 0.8;
    [self addSubview:_title];
    _check = [UIImageView new];
    _check.contentMode = UIViewContentModeCenter;
    [self addSubview:_check];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    return self;
}

- (void)showEntries:(NSArray<NSDictionary *> *)entries {
    for (NSUInteger i = 0; i < 3; i++) {
        NSDictionary *entry = i < entries.count ? entries[i] : nil;
        _glyphs[i].image = entry ? [glyphFor(entry, NO) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
        _bars[i].alpha = entry ? 1 : 0;
    }
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    _picture.layer.borderWidth = selected ? 2 : 0;
    _picture.layer.borderColor = SGRAccent().CGColor;
    UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    _check.image = [UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"circle" withConfiguration:size];
    _check.tintColor = selected ? SGRAccent() : SGGrey();
    self.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _picture.alpha = highlighted ? 0.6 : 1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _picture.frame = CGRectMake(0, 0, width, kPictureHeight);
    CGFloat slot = (width - 16) / 3, glyphTop = _names ? 18 : 26;
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat x = 8 + i * slot;
        _glyphs[i].frame = CGRectMake(x + (slot - 24) / 2, glyphTop, 24, 24);
        _bars[i].frame = CGRectMake(x + (slot - 20) / 2, glyphTop + 32, 20, 4);
    }
    _title.font = SGSubtitleFont();
    _title.numberOfLines = [SGRLabelCard titleLines];
    CGFloat titleHeight = _title.numberOfLines * ceil(_title.font.lineHeight);
    _title.frame = CGRectMake(0, kPictureHeight + 8, width, titleHeight);
    _check.frame = CGRectMake((width - 44) / 2, CGRectGetMaxY(_title.frame) - 6, 44, 44);
}

// The name takes a second line at the accessibility sizes, where half the row is too narrow for it.
+ (NSInteger)titleLines {
    return SGAccessibilityTextSize() ? 2 : 1;
}

+ (CGFloat)height {
    return kPictureHeight + 8 + [self titleLines] * ceil(SGSubtitleFont().lineHeight) - 6 + 44;
}

@end

#pragma mark - the page

typedef NS_ENUM(NSInteger, SGRNavbarSection) {
    SGRNavbarSectionSwitch,
    SGRNavbarSectionLabels,
    SGRNavbarSectionTabs,
    SGRNavbarSectionLinks,   // Add a tab, Use Spotify's tabs
    SGRNavbarSectionSplit,
    SGRNavbarSectionCount,
};

// A tab of the list: a check circle that shows or hides it, its glyph, its name, and the table's drag handle.
@interface SGRTabCell : UITableViewCell
@property (nonatomic, strong) UIButton *check;
@end

@implementation SGRTabCell
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.contentView.bounds.size.height;
    self.check.frame = CGRectMake(4, (height - 44) / 2, 44, 44);
}
@end

// The labels' cell: clear, so it drops the inset-grouped corner mask that clipped the cards' outer corners.
@interface SGRUnclippedCell : UITableViewCell
@end

@implementation SGRUnclippedCell

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = 0;
    self.layer.masksToBounds = NO;
    self.contentView.clipsToBounds = NO;
}

@end

// The tab editor: a preview of the bar, how it labels its tabs, the tabs in the order the bar shows them
// (the circle shows or hides one, the handle drags it, a tap on one of the mod's own opens it in the Add a
// Tab sheet to edit or remove), then adding one, going back to Spotify's tabs and splitting tabs apart.
// Spotify's own tabs are named by their label and drawn by Spotify, so they can be hidden but not renamed,
// given another icon or removed. Mod Settings and the welcome tour show the same editor.
@interface SGRNavbarPage : SGPage
@end

@implementation SGRNavbarPage {
    NSMutableArray<NSMutableDictionary *> *_entries;
    SGRTabBarPreview *_preview;
    UIView *_header;
    SGRLabelCard *_withNames, *_iconsOnly;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Tab bar";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.editing = YES;
    _preview = [SGRTabBarPreview new];
    _header = [UIView new];
    [_header addSubview:_preview];
    self.tableView.tableHeaderView = _header;
    _withNames = [[SGRLabelCard alloc] initWithTitle:@"Icons and names" names:YES];
    _iconsOnly = [[SGRLabelCard alloc] initWithTitle:@"Icons only" names:NO];
    for (SGRLabelCard *card in @[_withNames, _iconsOnly]) [card addTarget:self action:@selector(labelsPicked:) forControlEvents:UIControlEventTouchUpInside];
    _entries = navbarEntries();
    [self showChoices];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Split tabs, a page pushed from here, changes what the preview shows.
    [self reload];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width;
    CGFloat height = [_preview sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height;
    _preview.frame = CGRectMake(0, 8, width, height);
    CGSize size = CGSizeMake(width, CGRectGetMaxY(_preview.frame) + 8);
    if (CGSizeEqualToSize(_header.bounds.size, size)) return;
    _header.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = _header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

// The preview and the cards, from the list as it stands.
- (void)showChoices {
    [_preview showEntries:_entries];
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray array];
    for (NSDictionary *entry in _entries) if (![entry[SGRNavbarHidden] boolValue]) [shown addObject:entry];
    BOOL names = !SGHidden(SGRKeyNavbarHideLabels);
    for (SGRLabelCard *card in @[_withNames, _iconsOnly]) {
        [card showEntries:shown.count ? shown : (NSArray *)_entries];
        card.selected = card.names == names;
    }
    [self.view setNeedsLayout];
}

- (void)reload {
    _entries = navbarEntries();
    [self.tableView reloadData];
    [self showChoices];
}

- (void)save {
    SGRSetNavbarLayout(_entries);
    SGRRefreshTabBar();
    [self showChoices];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGRNavbarSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGRNavbarSectionTabs) return (NSInteger)_entries.count;
    return section == SGRNavbarSectionLinks ? 2 : 1;
}

- (NSString *)headerFor:(NSInteger)section {
    return section == SGRNavbarSectionTabs ? @"Tabs" : nil;
}

- (NSString *)footerFor:(NSInteger)section {
    if (section == SGRNavbarSectionSwitch && !SGEnabled(SGRKeyNavbar))
        return @"Off, the bar shows Spotify's own tabs in Spotify's order. Your list is kept for when it is on again.";
    if (section == SGRNavbarSectionTabs)
        return @"Drag a tab to move it. Tap one you added to rename it or change its icon, or one of Spotify's to hide it.";
    return nil;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self headerFor:section];
    return title ? SGSectionHeader(table, title) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return [self headerFor:section] ? SGSectionHeaderHeight() : SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    NSString *text = [self footerFor:section];
    return text ? SGSectionFooter(table, text) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    NSString *text = [self footerFor:section];
    return text ? SGSectionFooterHeight(table, text) : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRNavbarSectionLabels ? [SGRLabelCard height] : UITableViewAutomaticDimension;
}

- (UITableViewCell *)labelsCell:(UITableView *)table {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"labels"] ?: [[SGRUnclippedCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"labels"];
    cell.contentConfiguration = nil;
    cell.backgroundColor = UIColor.clearColor;
    cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (_withNames.superview != cell.contentView) {
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_withNames, _iconsOnly]];
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 12;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        ]];
    }
    return cell;
}

- (UITableViewCell *)tabCell:(UITableView *)table at:(NSIndexPath *)path {
    SGRTabCell *cell = [table dequeueReusableCellWithIdentifier:@"tab"] ?: [[SGRTabCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"tab"];
    NSDictionary *entry = _entries[(NSUInteger)path.row];
    BOOL hidden = [entry[SGRNavbarHidden] boolValue];
    SGFillCell(cell, entry[SGRNavbarTitle], [splitStockIDs() containsObject:entry[SGRNavbarID]] ? @"Apart, on the right" : nil, hidden ? SGGrey() : nil, nil);
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    content.image = glyphFor(entry, NO);
    content.imageProperties.tintColor = hidden ? SGGrey() : UIColor.whiteColor;
    content.imageProperties.maximumSize = CGSizeMake(24, 24);
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    content.imageToTextPadding = 12;
    NSDirectionalEdgeInsets margins = content.directionalLayoutMargins;
    margins.leading = 52;
    content.directionalLayoutMargins = margins;
    cell.contentConfiguration = content;
    cell.separatorInset = UIEdgeInsetsMake(0, 52, 0, 0);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityValue = hidden ? @"Hidden" : @"Shown";
    cell.accessibilityHint = entry[SGRNavbarURI] ? @"Opens the tab to edit it" : @"Shows or hides the tab";

    if (!cell.check) {
        cell.check = [UIButton buttonWithType:UIButtonTypeSystem];
        [cell.check addTarget:self action:@selector(checkTapped:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:cell.check];
    }
    UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    [cell.check setImage:[UIImage systemImageNamed:hidden ? @"circle" : @"checkmark.circle.fill" withConfiguration:size] forState:UIControlStateNormal];
    cell.check.tintColor = hidden ? SGGrey() : SGRAccent();
    cell.check.accessibilityLabel = [NSString stringWithFormat:@"Show %@ on the bar", entry[SGRNavbarTitle]];
    cell.check.accessibilityValue = hidden ? @"Off" : @"On";
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == SGRNavbarSectionLabels) return [self labelsCell:table];
    if (path.section == SGRNavbarSectionTabs) return [self tabCell:table at:path];
    UITableViewCell *cell = SGDequeueCell(table, @"navbar");
    switch (path.section) {
        case SGRNavbarSectionSwitch: {
            SGFillCell(cell, @"Custom tab bar", @"Your order, hidden tabs and tabs you add", nil, nil);
            UISwitch *toggle = [UISwitch new];
            toggle.onTintColor = SGGreen();
            toggle.on = SGEnabled(SGRKeyNavbar);
            [toggle addTarget:self action:@selector(customToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case SGRNavbarSectionLinks:
            // Links in the accent color, as the system's own actions in a list are.
            SGFillCell(cell, path.row == 0 ? @"Add a tab" : @"Use Spotify's tabs", nil, SGRAccent(), nil);
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessibilityTraits = UIAccessibilityTraitButton;
            break;
        default:
            SGFillCell(cell, @"Split tabs", @"Place chosen tabs apart on the right", nil, @"rectangle.split.2x1");
            cell.accessoryView = SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRNavbarSectionTabs;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRNavbarSectionTabs;
}

// The circle stands where the delete control would; a tab of the mod's own is removed from its sheet.
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section == SGRNavbarSectionTabs) return to;
    // Dragged past either end of the list, the tab stops at that end.
    return [NSIndexPath indexPathForRow:to.section < SGRNavbarSectionTabs ? 0 : (NSInteger)_entries.count - 1 inSection:SGRNavbarSectionTabs];
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableDictionary *entry = _entries[(NSUInteger)from.row];
    [_entries removeObjectAtIndex:(NSUInteger)from.row];
    [_entries insertObject:entry atIndex:(NSUInteger)to.row];
    [self save];
}

- (void)toggleRow:(NSInteger)row {
    NSMutableDictionary *entry = _entries[(NSUInteger)row];
    entry[SGRNavbarHidden] = [entry[SGRNavbarHidden] boolValue] ? nil : @YES;
    // A Spotify tab hidden here while it stands apart leaves the split list too: hidden is hidden everywhere, and the
    // editor would have it both hidden and apart while the bar still showed it on the right.
    if (entry[SGRNavbarHidden]) hideFromSplit(entry[SGRNavbarID]);
    [self save];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:SGRNavbarSectionTabs]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)checkTapped:(UIButton *)check {
    UIView *view = check;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    NSIndexPath *path = view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
    if (path.section == SGRNavbarSectionTabs) [self toggleRow:path.row];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    __weak typeof(self) weakSelf = self;
    switch (path.section) {
        case SGRNavbarSectionTabs:
            if (_entries[(NSUInteger)path.row][SGRNavbarURI]) [self editRow:path.row];
            else [self toggleRow:path.row];
            break;
        case SGRNavbarSectionLinks: {
            if (path.row == 1) {
                [self reset];
                break;
            }
            SGPresentAddTabSheet(self, tabPresets(), ^(NSDictionary *tab) {
                appendTab(tab);
                [weakSelf reload];
            });
            break;
        }
        case SGRNavbarSectionSplit:
            [self.navigationController pushViewController:[SGRSplitTabsPage new] animated:YES];
            break;
    }
}

// The entry of the list as it is now with this identity; the list is read again whenever the page appears.
- (NSMutableDictionary *)entryWithID:(NSString *)ident {
    for (NSMutableDictionary *entry in _entries) if ([entry[SGRNavbarID] isEqualToString:ident]) return entry;
    return nil;
}

// The Add a Tab sheet over the tab as it is; Save keeps its place on the bar and its identity.
- (void)editRow:(NSInteger)row {
    NSDictionary *entry = _entries[(NSUInteger)row];
    NSString *ident = entry[SGRNavbarID];
    __weak typeof(self) weakSelf = self;
    SGPresentEditTabSheet(self, tabPresets(), sheetTab(entry), ^(NSDictionary *edited) {
        NSMutableDictionary *now = [weakSelf entryWithID:ident];
        if (!now) return;
        [now setDictionary:editedEntry(now, edited)];
        [weakSelf save];
        [weakSelf.tableView reloadData];
    }, ^{
        typeof(self) page = weakSelf;
        NSMutableDictionary *now = [page entryWithID:ident];
        if (!now) return;
        [page->_entries removeObjectIdenticalTo:now];
        [page save];
        [page.tableView reloadData];
    });
}

- (void)labelsPicked:(SGRLabelCard *)card {
    if (card.selected) return;
    SGSetEnabled(SGRKeyNavbarHideLabels, !card.names);
    [[UISelectionFeedbackGenerator new] selectionChanged];
    SGRRefreshTabBar();
    [self showChoices];
}

- (void)customToggled:(UISwitch *)toggle {
    SGSetEnabled(SGRKeyNavbar, toggle.on);
    SGRRefreshTabBar();
    [self showChoices];
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SGRNavbarSectionSwitch] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)reset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Use Spotify's tabs"
                                                                  message:@"Every tab of Spotify's comes back where Spotify put it, the tabs you added go, and no tab is split apart."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGRSetNavbarLayout(@[]);
        SGRSetNavbarSplit(@[]);
        SGRRefreshTabBar();
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGRNavbarSettingsPage(void) {
    return [SGRNavbarPage new];
}

UIViewController *SGRNavbarEditorPage(void) {
    return [SGRNavbarPage new];
}
