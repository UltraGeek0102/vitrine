// The Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke), under either look: the card at its top
// (SGSingCard.m: the song, what Sing is doing, the vocals and the rest traced live, play and pause, the vocals'
// level and its three stops), Sing's switch, which turns the mic on and off at once, Ignore heat warnings, the voice
// model and its removal, spatial voice's page (its preview, SGSpatialPreview.m, and its switch), and Runs on under
// Advanced. While the page is on screen with Spotify in front, the card's reads of its lines keep Sing separating
// the playing song even at As sung, where it otherwise rests (SGSingReadLevels), so what the card shows and what
// its slider sets are heard at once; popped, covered or in the background, the page no longer counts.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Sing.h"
#import <sys/utsname.h>

// Chips before the A14 (the iPhone XS, XR, 11 and SE 2: iPhone11,x and iPhone12,x) are untested and may not keep up.
static BOOL untestedChip(void) {
    struct utsname name;
    int major = 0;
    return uname(&name) == 0 && sscanf(name.machine, "iPhone%d,", &major) == 1 && major < 13;
}

UIView *SGSingCardView(void);   // SGSingCard.m

static void tell(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void ask(NSString *title, NSString *message, NSString *action, BOOL destructive, void (^then)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { then(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

NSString *SGSingLevelText(double level) {
    if (level <= 0.001) return @"Gone";
    if (level < 0.999) return [NSString stringWithFormat:@"%.0f%%", level * 100];
    if (level <= 1.001) return @"As sung";
    if (level >= 1.999) return @"Vocals only";
    return [NSString stringWithFormat:@"Backing %.0f%%", (2 - level) * 100];
}

static NSString *bytes(long long count) {
    return [NSByteCountFormatter stringFromByteCount:count countStyle:NSByteCountFormatterCountStyleFile];
}

// The row's state: with the old model, its update reads as the model's download, worded as an update.
static SGSingModelState rowState(void) {
    if (SGSingModelUpdateDownloading()) return SGSingModelDownloading;
    if (SGSingModelUpdateAvailable()) return SGSingModelMissing;
    return SGSingModelCurrentState();
}

static NSString *modelValue(void) {
    if (!SGSingOSSupported()) return @"Unavailable";
    BOOL update = SGSingModelUpdateAvailable();
    switch (rowState()) {
        case SGSingModelDownloading:
            if (SGSingModelChecking()) return @"Checking…";
            if (SGSingModelWaitingForNetwork()) return SGSingModelOverCellular() ? @"Waiting for the network" : @"Waiting for Wi-Fi";
            return [NSString stringWithFormat:@"%.0f%%", SGSingModelProgress() * 100];
        case SGSingModelReady: return [NSString stringWithFormat:@"Downloaded · %@", SGSingModelSizeText()];
        case SGSingModelMissing:
            if (SGSingModelError()) return update ? @"Update failed, try again" : @"Failed, try again";
            if (SGSingModelPausedBytes()) {
                return [NSString stringWithFormat:@"%@ · %@ of %@", update ? @"Update paused" : @"Paused", bytes(SGSingModelPausedBytes()), SGSingModelSizeText()];
            }
            return [NSString stringWithFormat:update ? @"Update available · %@" : @"Download, %@", SGSingModelSizeText()];
    }
    return @"";
}

static void modelTapped(UITableViewController *page) {
    if (!SGSingOSSupported()) {
        tell(@"Voice model", SGSingMissing());
        return;
    }
    switch (rowState()) {
        case SGSingModelMissing: {
            BOOL update = SGSingModelUpdateAvailable();
            NSString *message = [NSString stringWithFormat:@"%@%@%@ from Hugging Face. It waits for Wi-Fi unless you let it use cellular. It stays on this iPhone, and no audio leaves it.",
                                 SGSingModelError() ? [NSString stringWithFormat:@"The last try failed: %@\n\n", SGSingModelError()] : @"",
                                 update ? @"The new voice model runs on the Neural Engine, faster and cooler, and Karaoke keeps the one it has until it is in. " : @"",
                                 SGSingModelSizeText()];
            if (untestedChip()) message = [message stringByAppendingString:@"\n\nKaraoke is tested on the iPhone 15 Pro. On iPhones older than the iPhone 12 it may not keep up."];
            NSString *title = SGSingModelPausedBytes() ? (update ? @"Carry on with the update?" : @"Carry on with the download?")
                                                       : (update ? @"Download the update?" : @"Download the voice model?");
            ask(title, message, @"Download", NO, ^{ SGSingDownloadModel(); });
            break;
        }
        case SGSingModelDownloading:
            if (SGSingModelWaitingForNetwork() && !SGSingModelOverCellular()) {
                ask(@"Download over cellular?", [NSString stringWithFormat:@"The download waits for Wi-Fi. Over cellular or a Low Data Mode network it uses up to %@ of your plan.",
                                                 SGSingModelSizeText()], @"Use cellular", NO, ^{ SGSingDownloadModelOverCellular(); });
                break;
            }
            ask(@"Stop the download?", @"What has come in is kept, so the next download carries on from it.", @"Stop", YES, ^{ SGSingCancelModelDownload(); });
            break;
        case SGSingModelReady:
            ask(@"Delete the voice model?", [NSString stringWithFormat:@"It frees %@. Karaoke needs it again to turn the vocals down.", SGSingModelInUseSizeText()],
                @"Delete", YES, ^{
                    SGSetSingOn(NO);
                    SGSingDeleteModel();
                    // Sing's switch goes off with it.
                    [page.tableView reloadData];
                });
            break;
    }
}

// Spatial voice's page, under Sing's: the preview at its top and the switch.
@interface SGSpatialVoicePage : SGModPage
@property (nonatomic, readonly) SGSpatialPreview *preview;
@end

@implementation SGSpatialVoicePage

- (void)viewDidLoad {
    [super viewDidLoad];
    _preview = [[SGSpatialPreview alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 0)];
    self.tableView.tableHeaderView = _preview;
}

// Its caption follows Dynamic Type and what the preview is doing, so the header is sized to it, and handed back
// only when that size changes (SGFitNote's way: the table lays out again on every handing back).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGSize size = [_preview sizeThatFits:CGSizeMake(table.bounds.size.width, 0)];
    if (CGSizeEqualToSize(_preview.bounds.size, size)) return;
    _preview.frame = (CGRect){_preview.frame.origin, size};
    table.tableHeaderView = _preview;
}

@end

UIViewController *SGSpatialVoiceSettingsPage(void) {
    SGModRow *spatial = SGOptionRow(@"Spatial voice", nil, SGKeySingSpatial);
    __block __weak SGSpatialVoicePage *page;
    spatial.changed = ^(BOOL on) {
        SGSetSingSpatial(on);
        [page.preview refresh];
    };
    SGSpatialVoicePage *made = [[SGSpatialVoicePage alloc] initWithTitle:@"Spatial voice" intro:nil sections:@[
        SGNotedSection(nil, @[spatial],
                       @"The singer's voice keeps its place in front of you as you turn your head, while the rest of the song turns with "
                       @"you; stay turned, and it comes round in front again. It follows your head through headphones that "
                       @"track it: AirPods Pro, AirPods 3 or later, AirPods Max, and asks for Motion & Fitness the first time. "
                       @"While iOS's own Spatialize Stereo is on, which already holds the whole song in place, the voice is left to it."),
    ] footer:nil];
    page = made;
    return made;
}

// The Sing page: the card (SGSingCard.m) as the table's header, sized to Dynamic Type, then its rows.
@interface SGSingPage : SGModPage
@end

@implementation SGSingPage {
    UIView *_card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _card = SGSingCardView();
    self.tableView.tableHeaderView = _card;
}

// Handed back only when its size changes (SGFitNote's way: the table lays out again on every handing back).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGSize size = [_card sizeThatFits:CGSizeMake(table.bounds.size.width, 0)];
    if (CGSizeEqualToSize(_card.bounds.size, size)) return;
    _card.frame = (CGRect){_card.frame.origin, size};
    table.tableHeaderView = _card;
}

@end

NSNotificationName const SGSingButtonDidChangeNotification = @"SGSingButtonDidChangeNotification";

UIViewController *SGSingSettingsPage(void) {
    SGModRow *sing = SGOptionRow(@"Karaoke", nil, SGKeySing);
    sing.changed = ^(BOOL on) { SGSetSingOn(on); };
    // Only the redesign's lyrics have the mic.
    SGModRow *button = SGSwitchRow(@"Toggle from lyrics", @"The mic in the corner of the lyrics", SGKeySingButton);
    button.changed = ^(BOOL on) { [NSNotificationCenter.defaultCenter postNotificationName:SGSingButtonDidChangeNotification object:nil]; };
    button.visible = ^BOOL { return SGRedesignedUIStored(); };
    SGModRow *heat = SGOptionRow(@"Ignore heat warnings", @"Keeps Karaoke going on a hot iPhone, which then gets hotter", SGKeySingIgnoreHeat);
    heat.changed = ^(BOOL on) { SGSetSingIgnoresHeat(on); };
    __block __weak SGModPage *page;
    SGModRow *model = SGStatActionRow(@"Voice model", nil, ^NSString *{ return modelValue(); }, ^{ modelTapped(page); });
    SGModRow *remove = SGActionRow(@"Remove voice model", nil, ^{
        BOOL partial = SGSingModelCurrentState() != SGSingModelReady;
        ask(partial ? @"Remove the paused download?" : @"Remove the voice model?",
            partial ? [NSString stringWithFormat:@"It frees %@. A new download starts from the beginning.", bytes(SGSingModelPausedBytes())]
                    : [NSString stringWithFormat:@"It frees %@. Karaoke needs it again to turn the vocals down.", SGSingModelInUseSizeText()],
            @"Remove", YES, ^{
                SGSetSingOn(NO);
                SGSingDeleteModel();
                [page.tableView reloadData];
            });
    });
    remove.color = SGRed();
    remove.visible = ^BOOL { return SGSingModelCurrentState() == SGSingModelReady || SGSingModelPausedBytes() > 0; };
    SGModRow *spatial = SGPageRow(@"Spatial voice", ^UIViewController *{ return SGSpatialVoiceSettingsPage(); });
    spatial.subtitle = @"With AirPods, the voice stays in front of you as you turn your head";
    spatial.value = ^NSString *{ return SGSingSpatial() ? @"On" : @"Off"; };
    // Facts about the iPhone, which do not change while the page shows.
    spatial.visible = ^BOOL { return SGSingSpatialAvailable(); };
    SGModRow *units = SGChoiceRow(@"Runs on", nil, SGKeySingComputeUnits, SGSingComputeUnitNames(), 0);
    units.choiceNotes = @[@"The Neural Engine, the fastest, with the CPU while it loads", @"Slower and warmer, and a little less memory"];
    units.choiceFooter = @"Karaoke loads the voice model on the CPU first and starts with it. On Automatic a second copy then loads on "
                         @"the Neural Engine and takes over, in the background too. The iPhone prepares it the first time after Vitrine "
                         @"is installed or updated, for a minute or so, and Karaoke runs on the CPU until then, unless Prepare after "
                         @"updates did it already. If it does not load, "
                         @"Karaoke stays on the CPU until Spotify is opened again.";
    units.chosen = ^(NSInteger index) { SGSingComputeUnitsChanged(); };
    SGModRow *prepare = SGSwitchRow(@"Prepare after updates",
                                    @"Readies the Neural Engine in the background after Vitrine or iOS updates, so Karaoke starts at full speed", SGKeySingPrepareAhead);
    SGSingPage *made = [[SGSingPage alloc] initWithTitle:@"Karaoke" intro:nil sections:@[
        SGSection(nil, @[sing, button, heat, model, remove]),
        SGSection(nil, @[spatial]),
        SGNotedSection(@"Advanced", @[units, prepare],
                       @"Karaoke turns a song's vocals down to sing over, or the rest down to hear the vocals alone, with a voice model that "
                       @"runs only on this iPhone: no audio leaves it. It listens a few seconds ahead of what plays, so the vocals change a "
                       @"few seconds after a song starts or after a seek."),
    ] footer:nil];
    page = made;
    return made;
}
