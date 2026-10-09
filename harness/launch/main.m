// What the mod adds to every remote-config flag Spotify reads as it starts: Flags.x hands each read to
// SGForcedFlagValue, which asks every forcer and the All flags override. Run on the Mac (Mac Catalyst,
// so the tweak's UIKit headers compile) over the generated table of every flag Spotify 9.1.78 has,
// with the forcers registered the way the tweak registers them: AdBlock.m's from its constructor, the
// redesign's through SGRedesignForceFlags, and one standing in for LyricsSources.m's (a dispatch_once
// and a nil, which is what it costs with the lyrics sources off).
//
// The stored switches are a typical install's: Hide ads and Hide upsells on, three overrides from the
// All flags page. Prints the cost of one pass over the table, the best of several, and checks that
// every answer is the same with and without the mod's launch snapshot, so a faster answer is never a
// different one.
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import "Core/SGFlagForce.h"
#import "Core/SGPrefs.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/Flags/Flags.h"
#import "Redesigned/Kit/SGRedesign.h"

static double now(void) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom / 1e6;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        for (NSString *key in [store dictionaryRepresentation]) {
            if ([key hasPrefix:@"spotifyglass."]) [store removeObjectForKey:key];
        }
        [store setBool:YES forKey:SGKeyHideAds];
        [store setBool:YES forKey:SGKeyHideUpsells];
        SGSetFlagOverride(@"ios-account-switching.is_enabled", @YES);
        SGSetFlagOverride(@"ios-account-switching.max_accounts", @4);
        SGSetFlagOverride(@"ios-feature-adonappopen.enabled", @YES);
        // Two flags outside the table, for the override report after the passes: one Spotify asks for
        // late and one a forcer that beats an override answers.
        SGSetFlagOverride(@"ios-harness.late", @YES);
        SGSetFlagOverride(@"ios-harness.beaten", @NO);

        // LyricsSources.m's forcer, off: a dispatch_once and a nil.
        SGRegisterFlagForcer(NO, ^id(NSString *key) {
            static BOOL on;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ on = NO; });
            return on ? @5000 : nil;
        }, nil);
        SGRedesignForceFlags(@"harness", @{@"ios-feature-nowplaying.sheet_style": @YES});

        NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:SGFlagCount];
        for (NSUInteger i = 0; i < SGFlagCount; i++) [keys addObject:@(SGFlagTable[i].key)];

        // Every answer, for the check after the passes; this first pass also reads what is read once.
        NSMutableDictionary<NSString *, id> *answers = [NSMutableDictionary dictionary];
        double first = now();
        for (NSString *key in keys) answers[key] = SGForcedFlagValue(key) ?: NSNull.null;
        first = now() - first;

        double best = INFINITY;
        for (int pass = 0; pass < 20; pass++) {
            double start = now();
            for (NSString *key in keys) (void)SGForcedFlagValue(key);
            best = MIN(best, now() - start);
        }
        printf("%lu flags, first pass %.2f ms, then one pass: %.2f ms, %.2f us a read (best of 20)\n",
               (unsigned long)keys.count, first, best, best * 1000 / keys.count);

        NSUInteger forced = 0, wrong = 0;
        for (NSString *key in keys) {
            id expected = SGFlagOverride(key) ?: SGAdBlockForcedFlag(key);
            id got = SGForcedFlagValue(key);
            if (got) forced++;
            if (!(expected == got || [expected isEqual:got])) {
                printf("wrong answer for %s\n", key.UTF8String);
                wrong++;
            }
            if (!([answers[key] isEqual:got ?: NSNull.null])) {
                printf("answer changed between passes for %s\n", key.UTF8String);
                wrong++;
            }
        }
        printf("%lu flags forced, %lu wrong\n", (unsigned long)forced, (unsigned long)wrong);

        // The override report Flags.x logs 15 s after launch, and what it says once the late flag is asked.
        SGRegisterFlagForcer(YES, ^id(NSString *key) { return [key isEqualToString:@"ios-harness.beaten"] ? @YES : nil; }, nil);
        if (![SGForcedFlagValue(@"ios-harness.beaten") isEqual:@YES]) { printf("the beating forcer lost\n"); wrong++; }
        NSString *report = SGFlagOverrideReport();
        printf("report: %s\n", report.UTF8String);
        if (![report isEqualToString:@"5 overrides stored, 3 asked for and forced, 1 answered by another switch: "
                                     @"ios-harness.beaten (1, not 0), 1 not asked for yet: ios-harness.late"]) {
            printf("wrong report\n");
            wrong++;
        }
        if (![SGForcedFlagValue(@"ios-harness.late") isEqual:@YES]) { printf("the late override lost\n"); wrong++; }
        report = SGFlagOverrideReport();
        printf("report after the late ask: %s\n", report.UTF8String);
        if (![report hasPrefix:@"5 overrides stored, 4 asked for and forced, 1 answered by another switch"] ||
            ![report hasSuffix:@", 0 not asked for yet"]) {
            printf("wrong report after the late ask\n");
            wrong++;
        }
        return wrong ? 1 : 0;
    }
}
