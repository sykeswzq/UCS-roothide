// SpringBoardTimer.m - 注入 SpringBoard，定时后台拉起 UCS --cli 写 HealthKit
// 不经过 uiopen，不闪 Launch Screen，锁屏也能触发（SpringBoard 永不挂）
#import <Foundation/Foundation.h>
#import <dlfcn.h>

static void SBLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *log = [NSString stringWithFormat:@"[%@] %@\n",
        [NSDate date], line];
    FILE *f = fopen("/var/mobile/Documents/ucs_sbtimer.log", "a");
    if (f) { fputs([log UTF8String], f); fclose(f); }
}

static NSString *SBReadFile(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static NSDictionary *SBReadConfig(void) {
    NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Documents/ucs_config.plist"];
    if (!c) c = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Documents/ucs_config.plist"];
    return c;
}

static void SBTick(void) {
    @try {
        NSDictionary *cfg = SBReadConfig();
        if (!cfg) { SBLog(@"config missing"); return; }
        if (![cfg[@"scheduleEnabled"] boolValue]) return;

        NSString *st = cfg[@"scheduleTime"];
        if (!st) return;
        NSArray *parts = [st componentsSeparatedByString:@":"];
        if (parts.count != 2) return;
        NSInteger schedH = [parts[0] integerValue];
        NSInteger schedM = [parts[1] integerValue];

        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *now = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
        if (now.hour < schedH || (now.hour == schedH && now.minute < schedM)) return;

        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyy-MM-dd";
        NSString *today = [f stringFromDate:[NSDate date]];
        NSString *last = SBReadFile(@"/var/mobile/Documents/ucs_lastgen.txt");
        if (!last) last = SBReadFile(@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt");
        if ([last isEqualToString:today]) return;

        SBLog(@"trigger UCS --cli (sched=%02ld:%02ld now=%02ld:%02ld)",
              (long)schedH, (long)schedM, (long)now.hour, (long)now.minute);
        // 后台拉起 UCS --cli，不经过 uiopen，不闪 UI
        system("/var/jb/Applications/UCS.app/UCS --cli > /var/mobile/Documents/ucs_cli.log 2>&1 &");
    } @catch (NSException *e) {
        SBLog(@"exception: %@", e);
    }
}

__attribute__((constructor))
static void SBInit(void) {
    SBLog(@"SpringBoardTimer loaded, uid=%d", getuid());
    SBTick();
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *_) {
        SBTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
