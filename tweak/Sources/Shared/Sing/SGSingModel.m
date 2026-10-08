// The voice model on the phone (Sing.h): the five files of its compiled separator-ane.mlmodelc, downloaded one by one
// from the Hugging Face repo's separator-ane.mlmodelc folder, each kept only once its size and SHA-256 are the ones
// pinned here, then moved together into Application Support/Vitrine/Sing/separator-ane.mlmodelc, which backups leave
// out (210 MB that can be downloaded again). A dropped connection carries on from where it stopped, three times per
// file, and a stopped download keeps the file it was in the middle of (NSURLSession's resume data, kept beside the
// staging folder) for the next one to carry on from. A resumed request is answered 206, with the whole file handed
// over all the same. On a FLEX build a copy put in Sing/dev/ by hand comes first.
//
// The model Karaoke downloaded before (separator.mlmodelc, 489 MB, the same checkpoint with operations in float32 that
// the Neural Engine does not run) is kept and loaded until this one is in, so Karaoke works through the update: it is
// then the model, on the CPU alone, and this one's download an update (SGSingModelUpdateAvailable). Once this one is in,
// at launch or as its download ends, the old one is deleted (SGSingRemoveOldModel); what its own download left goes at
// launch either way.
//
// Threading: main thread, but for SGSingRemoveOldModel; the session's delegate runs on a queue of its own and hands
// back to the main thread.
#import <CommonCrypto/CommonDigest.h>
#import "Core/SGCore.h"
#import "Sing.h"

static NSString *const kRepo = @"https://huggingface.co/My-Name-Is-Jeff/vitrine-sing/resolve/main/separator-ane.mlmodelc/";
static const int kRetries = 3;
// Bytes a stopped download has kept, for the row that offers to carry on with it or remove it.
static NSString *const kPausedKey = @"spotifyglass.sing.downloadPaused";
// Room the download leaves on the disk besides itself.
static const long long kSpareSpace = 64ll * 1000 * 1000;

typedef struct {
    NSString *__unsafe_unretained path;
    long long size;
    const char *sha256;
} SGSingFile;

// The repo's separator-ane.mlmodelc (manifest.json beside the compiled folder; upload those exact files, as a
// recompile changes coremldata.bin), the weights last so the small files fail first.
static const SGSingFile kFiles[] = {
    {@"metadata.json", 2333, "101714d1a37ad29c70bf1705ec25ec99584c3cbce27f2245858ace06dacbfb44"},
    {@"coremldata.bin", 388, "bcfd38a8b121681dfb9fdfe6f9d88ffb29068e0dd6d24d4012f4c3a7bdcbc81b"},
    {@"analytics/coremldata.bin", 243, "55f78aab64f5b1250ce4d6016dff23aee43fb97feb77bbceab4e36b3d9ccffb3"},
    {@"model.mil", 1346642, "957024c1075fe331f7ca3410b8bf5e2f83a58c61763caf154729829ce0a92d08"},
    {@"weights/weight.bin", 209077208, "bb4a0effafb5121b9aaa5ea96371fa14d0d8dc30a5ae44a93e0c15a2f4077635"},
};
enum { kFileCount = sizeof kFiles / sizeof kFiles[0] };
// The old model's, checked by size only: it was checked as it came in.
static const SGSingFile kOldFiles[] = {
    {@"metadata.json", 2431, NULL},
    {@"coremldata.bin", 507, NULL},
    {@"analytics/coremldata.bin", 243, NULL},
    {@"model.mil", 669061, NULL},
    {@"weights/weight.bin", 488986336, NULL},
};

NSString *const SGSingChangedNotification = @"SGSingChangedNotification";

// Counts the changes to the model's folder, so SGSingModelURL checks it again only after one.
static NSUInteger sg_modelGeneration;

static long long totalBytes(void) {
    long long total = 0;
    for (int i = 0; i < kFileCount; i++) total += kFiles[i].size;
    return total;
}

static NSURL *singFolder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Vitrine" isDirectory:YES] URLByAppendingPathComponent:@"Sing" isDirectory:YES];
}

static NSURL *modelFolder(void) {
    return [singFolder() URLByAppendingPathComponent:@"separator-ane.mlmodelc" isDirectory:YES];
}

static NSURL *oldFolder(void) {
    return [singFolder() URLByAppendingPathComponent:@"separator.mlmodelc" isDirectory:YES];
}

static NSURL *stagingFolder(void) {
    return [singFolder() URLByAppendingPathComponent:@"download-ane" isDirectory:YES];
}

// A stopped download's resume data for file `index`, beside the staging folder: everything in that folder is moved
// into the model.
static NSURL *resumeFile(int index) {
    return [singFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"download-ane-%d.resume", index]];
}

static long long sizeOf(NSURL *url) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileSize] longLongValue];
}

// Whether every file of `files` is in `folder` at its size; the hashes were checked as each came in.
static BOOL completeWith(NSURL *folder, const SGSingFile *files, int count) {
    for (int i = 0; i < count; i++) {
        if (sizeOf([folder URLByAppendingPathComponent:files[i].path]) != files[i].size) return NO;
    }
    return YES;
}

static BOOL complete(NSURL *folder) {
    return completeWith(folder, kFiles, kFileCount);
}

static BOOL oldComplete(void) {
    return completeWith(oldFolder(), kOldFiles, sizeof kOldFiles / sizeof kOldFiles[0]);
}

// The file's SHA-256, read a megabyte at a time: the weights are too big to read whole.
static NSString *sha256Of(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!handle) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [handle readDataUpToLength:1 << 20 error:nil];
            if (!chunk.length) break;
            CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static void announce(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingChangedNotification object:nil];
}

#pragma mark - the download

@interface SGSingDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic) int file;               // the index of the file coming in
@property (nonatomic) long long received;     // its bytes so far
@property (nonatomic, copy) NSString *error;
@property (atomic, strong) NSURLSessionDownloadTask *task;   // the one running, so a stop (on the main thread) can keep what it has
@end

static SGSingDownloader *sg_downloader;   // while a download runs
static NSString *sg_lastError;
static double sg_progress;
static BOOL sg_waitingForNetwork;   // offline, or on cellular unless allowed: the session holds the request
static BOOL sg_cellular;            // the download may use cellular and Low Data Mode networks
static BOOL sg_checking;            // the weights' checksum is being read

@implementation SGSingDownloader {
    NSURLSession *_session;
    BOOL _resumed;                     // it carries on from resume data
    BOOL _restart;                     // resume data the server no longer takes: the file again from the start
    int _attempts;
    BOOL _cancelled;
}

- (void)start {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.timeoutIntervalForRequest = 60;
    // Offline, a request (a retry too) waits for the network rather than failing at once; and so it does on cellular
    // or a Low Data Mode network, 210 MB being a lot of a plan, until the user says it may use them.
    configuration.waitsForConnectivity = YES;
    configuration.allowsExpensiveNetworkAccess = sg_cellular;
    configuration.allowsConstrainedNetworkAccess = sg_cellular;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    NSError *error;
    [NSFileManager.defaultManager createDirectoryAtURL:stagingFolder() withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *folder = singFolder();
    [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    [queue addOperationWithBlock:^{ [self next]; }];
}

// Stopped, the file coming in is kept as resume data for the next download; the session goes once it is written.
- (void)cancel {
    _cancelled = YES;
    NSURLSession *session = _session;
    NSURLSessionDownloadTask *task = self.task;
    if (!task) {
        [session invalidateAndCancel];
        return;
    }
    NSURL *resume = resumeFile(self.file);
    [task cancelByProducingResumeData:^(NSData *data) {
        if (data) [data writeToURL:resume atomically:YES];
        SGLog(@"sing: the download is stopped%@", data ? @", what came in is kept" : @"");
        [session invalidateAndCancel];
    }];
}

- (void)download:(NSURL *)url resumeData:(NSData *)resume {
    _resumed = resume != nil;
    NSURLSessionDownloadTask *task = resume ? [_session downloadTaskWithResumeData:resume] : [_session downloadTaskWithURL:url];
    self.task = task;
    [task resume];
}

- (NSURL *)fileURL {
    return [NSURL URLWithString:[kRepo stringByAppendingString:kFiles[self.file].path]];
}

// The first file not already in the staging folder from an earlier try, or the move into place.
- (void)next {
    if (_cancelled) return;
    while (self.file < kFileCount && sizeOf([stagingFolder() URLByAppendingPathComponent:kFiles[self.file].path]) == kFiles[self.file].size) self.file++;
    self.received = 0;
    _attempts = 0;
    [self report];
    if (self.file == kFileCount) {
        [self finish];
        return;
    }
    // A stop's resume data is used once: if it fails, the file starts over.
    NSData *resume = [NSData dataWithContentsOfURL:resumeFile(self.file)];
    [NSFileManager.defaultManager removeItemAtURL:resumeFile(self.file) error:nil];
    [self download:[self fileURL] resumeData:resume];
    SGLog(@"sing: downloading %@%@", kFiles[self.file].path, resume ? @", carrying on from the last download" : @"");
}

- (void)finish {
    NSFileManager *files = NSFileManager.defaultManager;
    // Resume data a stop wrote after the next download had already looked for it.
    for (int i = 0; i < kFileCount; i++) [files removeItemAtURL:resumeFile(i) error:nil];
    [files removeItemAtURL:modelFolder() error:nil];
    NSError *error;
    BOOL moved = [files moveItemAtURL:stagingFolder() toURL:modelFolder() error:&error];
    [self endWithError:moved ? nil : [NSString stringWithFormat:@"The model could not be put in place (%@)", error.localizedDescription]];
}

- (void)endWithError:(NSString *)error {
    [_session finishTasksAndInvalidate];
    if (error) SGLog(@"sing: the model's download failed: %@", error);
    else SGLog(@"sing: the model is downloaded and checked");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_downloader != self) return;
        sg_downloader = nil;
        sg_waitingForNetwork = NO;
        sg_lastError = error;
        if (!error) [NSUserDefaults.standardUserDefaults removeObjectForKey:kPausedKey];
        // The update in: the old model goes now, and Sing.x loads this one the next time it wants the model.
        if (!error) SGSingRemoveOldModel();
        sg_modelGeneration++;
        announce();
    });
}

- (void)report {
    long long done = self.received;
    for (int i = 0; i < self.file && i < kFileCount; i++) done += kFiles[i].size;
    double progress = (double)done / totalBytes();
    // A few times a second is enough for the row and the button.
    static CFAbsoluteTime reported;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - reported < 0.25 && progress < 1) return;
    reported = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_progress = progress;
        sg_waitingForNetwork = NO;
        announce();
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written
 totalBytesWritten:(int64_t)totalWritten totalBytesExpectedToWrite:(int64_t)expected {
    self.received = MIN(totalWritten, kFiles[self.file].size);
    [self report];
}

- (void)URLSession:(NSURLSession *)session taskIsWaitingForConnectivity:(NSURLSessionTask *)task {
    SGLog(@"sing: waiting for the network to download %@", kFiles[self.file].path);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_downloader != self) return;
        sg_waitingForNetwork = YES;
        announce();
    });
}

// The file is checked here, before the session deletes it, and kept in the staging folder if it is the one
// pinned.
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    SGSingFile file = kFiles[self.file];
    NSInteger status = [task.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)task.response).statusCode : 0;
    BOOL answered = status == 200 || status == 206;
    if (!answered && _resumed) {
        // Resume data the server no longer takes, its signed address run out after a day: the file again.
        SGLog(@"sing: the server answered %ld to carrying on %@, so it starts over", (long)status, file.path);
        _restart = YES;
        return;
    }
    long long size = sizeOf(location);
    BOOL big = file.size > 1000 * 1000;
    if (big) dispatch_async(dispatch_get_main_queue(), ^{ sg_checking = YES; announce(); });
    NSString *hash = size == file.size ? sha256Of(location) : nil;
    if (big) dispatch_async(dispatch_get_main_queue(), ^{ sg_checking = NO; announce(); });
    SGLog(@"sing: %@ came in, %ld, %lld bytes", file.path, (long)status, size);
    if (!answered || size != file.size || ![hash isEqualToString:@(file.sha256)]) {
        self.error = !answered ? [NSString stringWithFormat:@"The server answered %ld for %@", (long)status, file.path]
                                 : [NSString stringWithFormat:@"%@ is not the file Karaoke expects (%lld bytes%@)", file.path, size, hash ? @", another checksum" : @""];
        return;
    }
    NSURL *target = [stagingFolder() URLByAppendingPathComponent:file.path];
    [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    NSError *error;
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:target error:&error]) {
        self.error = [NSString stringWithFormat:@"%@ could not be kept (%@)", file.path, error.localizedDescription];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_cancelled) return;
    if (_restart) {
        _restart = NO;
        [self download:[self fileURL] resumeData:nil];
        return;
    }
    if (self.error) {
        NSString *message = self.error;
        self.error = nil;
        [self endWithError:message];
        return;
    }
    if (!error) {
        self.file++;
        [self next];
        return;
    }
    NSData *resume = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (++_attempts <= kRetries) {
        SGLog(@"sing: %@ stopped (%@), trying again%@", kFiles[self.file].path, error.localizedDescription, resume ? @" from where it was" : @"");
        [self download:[self fileURL] resumeData:resume];
        return;
    }
    [self endWithError:error.localizedDescription];
}

@end

#pragma mark - what Sing asks

SGSingModelState SGSingModelCurrentState(void) {
    // The old model works on while its update downloads.
    if (sg_downloader && !SGSingModelUpdateAvailable()) return SGSingModelDownloading;
    return SGSingModelURL() ? SGSingModelReady : SGSingModelMissing;
}

NSURL *SGSingModelURL(void) {
    // Checked by size once a launch, and again after a download or a delete changes it.
    static int known = -1, oldKnown = -1;
    static NSURL *dev;
    static NSUInteger knownGeneration = NSUIntegerMax;
    if (knownGeneration != sg_modelGeneration) {
        knownGeneration = sg_modelGeneration;
        known = complete(modelFolder());
        oldKnown = oldComplete();
        // FLEX builds only (Diagnostics' SGIsDebugBuild, which the harnesses do not link): a copy put in Sing/dev/ by
        // hand, for a model not on Hugging Face yet, neither downloaded nor checked. Core ML crashes the process on a
        // compiled model with a file missing (model.mil, weights/weight.bin; a short file fails cleanly), so a copy
        // cut off halfway is not loaded.
        NSURL *folder = [[singFolder() URLByAppendingPathComponent:@"dev" isDirectory:YES] URLByAppendingPathComponent:@"separator-ane.mlmodelc" isDirectory:YES];
        int present = 0;
        for (int i = 0; i < kFileCount; i++) present += sizeOf([folder URLByAppendingPathComponent:kFiles[i].path]) > 0;
        BOOL there = present == kFileCount, flex = NSClassFromString(@"FLEXManager") != nil;
        if (there && flex && !dev) SGLog(@"sing: DEV MODEL: the voice model is the unchecked copy in %@, not a download (a FLEX build)", folder.path);
        if (there && !flex) SGLog(@"sing: a dev model is in %@, and only a FLEX build loads it", folder.path);
        if (present && !there) SGLog(@"sing: the dev model in %@ has %d of its %d files, so it is not loaded", folder.path, present, kFileCount);
        dev = there && flex ? folder : nil;
    }
    return dev ?: known ? modelFolder() : oldKnown ? oldFolder() : nil;
}

// This model in place, the dev copy or the download: nothing to download.
static BOOL hasModel(void) {
    return SGSingModelURL() && !SGSingModelUpdateAvailable();
}

double SGSingModelProgress(void) {
    return sg_downloader ? sg_progress : hasModel() ? 1 : 0;
}

BOOL SGSingModelWaitingForNetwork(void) {
    return sg_downloader && sg_waitingForNetwork;
}

NSString *SGSingModelError(void) {
    return sg_lastError;
}

NSString *SGSingModelSizeText(void) {
    return [NSByteCountFormatter stringFromByteCount:totalBytes() countStyle:NSByteCountFormatterCountStyleFile];
}

// What is still to come: the files not in the staging folder yet.
static long long bytesToCome(void) {
    long long left = 0;
    for (int i = 0; i < kFileCount; i++) {
        if (sizeOf([stagingFolder() URLByAppendingPathComponent:kFiles[i].path]) != kFiles[i].size) left += kFiles[i].size;
    }
    return left;
}

void SGSingDownloadModel(void) {
    if (sg_downloader || hasModel()) return;
    // The volume Application Support is on, which the staging folder's parent may not exist on yet.
    NSURL *support = singFolder().URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSNumber *free = [support resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil][NSURLVolumeAvailableCapacityForImportantUsageKey];
    long long wanted = bytesToCome() + kSpareSpace;
    if (free && free.longLongValue < wanted) {
        NSByteCountFormatterCountStyle style = NSByteCountFormatterCountStyleFile;
        sg_lastError = [NSString stringWithFormat:@"The iPhone has %@ free, and the voice model needs %@ more.",
                        [NSByteCountFormatter stringFromByteCount:free.longLongValue countStyle:style],
                        [NSByteCountFormatter stringFromByteCount:wanted - free.longLongValue countStyle:style]];
        SGLog(@"sing: the download does not start: %@", sg_lastError);
        announce();
        return;
    }
    sg_lastError = nil;
    sg_progress = 0;
    sg_waitingForNetwork = NO;
    sg_downloader = [SGSingDownloader new];
    [sg_downloader start];
    announce();
}

void SGSingDownloadModelOverCellular(void) {
    if (!sg_downloader) {
        sg_cellular = YES;
        SGSingDownloadModel();
        return;
    }
    if (sg_cellular) return;
    // The running download's session forbids cellular: it stops keeping what it has, and starts again allowed.
    SGSingCancelModelDownload();
    sg_cellular = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SGSingDownloadModel(); });
}

BOOL SGSingModelOverCellular(void) {
    return sg_cellular;
}

BOOL SGSingModelChecking(void) {
    return sg_downloader && sg_checking;
}

long long SGSingModelPausedBytes(void) {
    return sg_downloader || hasModel() ? 0 : [NSUserDefaults.standardUserDefaults integerForKey:kPausedKey];
}

void SGSingCancelModelDownload(void) {
    if (sg_downloader) [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)(sg_progress * totalBytes()) forKey:kPausedKey];
    [sg_downloader cancel];
    sg_downloader = nil;
    sg_modelGeneration++;
    announce();
}

void SGSingDeleteModel(void) {
    SGSingCancelModelDownload();
    [NSFileManager.defaultManager removeItemAtURL:singFolder() error:nil];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPausedKey];
    sg_modelGeneration++;
    announce();
}

// Deletes what of `urls` is there, adding the bytes freed to `freed`; whether there was any.
static BOOL removeAll(NSArray<NSURL *> *urls, long long *freed) {
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL found = NO;
    for (NSURL *url in urls) {
        if (![files fileExistsAtPath:url.path]) continue;
        found = YES;
        *freed += sizeOf(url);
        for (NSURL *file in [files enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileSizeKey] options:0 errorHandler:nil]) *freed += sizeOf(file);
        [files removeItemAtURL:url error:nil];
    }
    return found;
}

void SGSingRemoveOldModel(void) {
    // What the old model's download left: its staging folder and resume data, one per file (named one by one:
    // download-ane-N.resume is this model's own). The bytes a stopped download kept were the old model's.
    NSMutableArray<NSURL *> *leftovers = [NSMutableArray arrayWithObject:[singFolder() URLByAppendingPathComponent:@"download"]];
    for (int i = 0; i < 5; i++) [leftovers addObject:[singFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"download-%d.resume", i]]];
    long long freed = 0;
    BOOL left = removeAll(leftovers, &freed);
    if (left) [NSUserDefaults.standardUserDefaults removeObjectForKey:kPausedKey];
    // The old model itself only once this one is in: until then Karaoke runs on it.
    BOOL there = [NSFileManager.defaultManager fileExistsAtPath:oldFolder().path], replaced = complete(modelFolder());
    BOOL old = there && replaced && removeAll(@[oldFolder()], &freed);
    NSString *size = [NSByteCountFormatter stringFromByteCount:freed countStyle:NSByteCountFormatterCountStyleFile];
    if (old) SGLog(@"sing: the old voice model (separator.mlmodelc) is deleted, %@ freed; the model is separator-ane.mlmodelc", size);
    else if (left) SGLog(@"sing: what the old voice model's download left is deleted, %@ freed", size);
    // Which model is in use: a FLEX build's dev copy of the new one comes before the old.
    if (there && !replaced) {
        SGLog(SGSingModelUpdateAvailable()
              ? @"sing: the old voice model (separator.mlmodelc) is kept until separator-ane.mlmodelc is downloaded, and Karaoke runs on it, on the CPU alone"
              : @"sing: the old voice model (separator.mlmodelc) is kept until separator-ane.mlmodelc is downloaded; the dev copy is in use");
    }
}

BOOL SGSingModelUpdateAvailable(void) {
    return [SGSingModelURL() isEqual:oldFolder()];
}

BOOL SGSingModelUpdateDownloading(void) {
    return sg_downloader && SGSingModelUpdateAvailable();
}

NSString *SGSingModelInUseSizeText(void) {
    long long total = 0;
    for (size_t i = 0; i < sizeof kOldFiles / sizeof kOldFiles[0]; i++) total += kOldFiles[i].size;
    return [NSByteCountFormatter stringFromByteCount:SGSingModelUpdateAvailable() ? total : totalBytes() countStyle:NSByteCountFormatterCountStyleFile];
}

NSArray<NSString *> *SGSingComputeUnitNames(void) {
    return @[@"Automatic", @"CPU only"];
}

BOOL SGSingOSSupported(void) {
    if (@available(iOS 18.0, *)) return YES;
    return NO;
}
