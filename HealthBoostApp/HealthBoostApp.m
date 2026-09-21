// HealthBoostApp.m - UCS App 主程序（全新实现）
// 功能：手动生成虚拟步数/距离/楼层到 HealthKit；定时自动生成；微信同步触发
// 环境：roothide (Dopamine) / arm64e / iOS 15+
#import <UIKit/UIKit.h>
#import <HealthKit/HealthKit.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

// ================= 共享路径（/var/mobile/Documents 为 mobile 用户共享目录，launchd 脚本与 App 均可见） =================
// 注意（v1.0.1 修复）：App 沙盒视图下 /var/mobile/Documents 物理落盘到 /rootfs/private/var/mobile/Documents/，
// 与 launchd 脚本读的真实视图 inode 不同。App 写入保持 /var/mobile/Documents（落 rootfs 视图），
// 脚本优先读 rootfs 视图、回退真实视图，两侧统一。
#define UCS_CFG      @"/var/mobile/Documents/ucs_config.plist"
#define UCS_CFG_ALT  @"/rootfs/private/var/mobile/Documents/ucs_config.plist"
#define UCS_MARKER   @"/var/mobile/Documents/ucs_wake.marker"
#define UCS_LASTGEN  @"/var/mobile/Documents/ucs_lastgen.txt"
#define UCS_LOG      @"/var/mobile/Documents/ucs.log"

// ================= jbroot 路径解析（roothide：把 /var/jb 等映射到真实物理路径） =================
// 用于 App 沙盒内调用 /var/jb/usr/bin/ 下的工具（killall/uiopen），dlsym 避免链接期符号缺失
static NSString *JBPath(NSString *path) {
    static void *jb_sym = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ jb_sym = dlsym(RTLD_DEFAULT, "jbroot"); });
    if (jb_sym) {
        typedef const char *(*fn_t)(const char *);
        fn_t fn = (fn_t)jb_sym;
        const char *real = fn([path UTF8String]);
        if (real && *real) return [NSString stringWithUTF8String:real];
    }
    return path;
}

// 多候选探测可执行文件：jbroot 解析后的 /var/jb 路径 -> 原始路径
static const char *FindTool(NSString *jailPath, NSString *plainPath) {
    NSString *jb = JBPath(jailPath);
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:jb]) return jb.UTF8String;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:plainPath]) return plainPath.UTF8String;
    return NULL;
}

// ================= 日志（追加写入，便于排查） =================
// v1.0.1：双视图写入（App 沙盒落盘视图 + 真实视图），SSH root 视图也能看到
void ULog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[UCS_LOG, @"/rootfs/private/var/mobile/Documents/ucs.log"];
    for (NSString *p in paths) {
        if (![fm fileExistsAtPath:p]) {
            [fm createFileAtPath:p contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    NSLog(@"UCS %@", msg);
}

// ================= 配置读写（XML plist，launchd 脚本可用 plutil 读取） =================
// v1.0.1：读配置双路（先 App 沙盒实际落盘视图，再真实视图），保证与 launchd 脚本一致
static NSDictionary *UCSLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:UCS_CFG];
    if (d) return d;
    return [NSDictionary dictionaryWithContentsOfFile:UCS_CFG_ALT];
}

static void UCSSaveConfig(NSDictionary *dict) {
    [dict writeToFile:UCS_CFG atomically:YES];
    chmod(UCS_CFG.UTF8String, 0666);
    // 同时写入真实视图，保证 launchd 脚本（root 视图）也能读到最新配置
    [dict writeToFile:UCS_CFG_ALT atomically:YES];
    chmod(UCS_CFG_ALT.UTF8String, 0666);
}

static NSDictionary *UCSDefaultConfig(void) {
    return @{
        @"virtualSteps"   : @5200,
        @"walkDistance"   : @3640,   // 米，0 表示按步数自动换算（约 0.7m/步）
        @"flights"        : @0,      // 楼层，0 表示不生成
        @"scheduleEnabled": @NO,
        @"scheduleTime"   : @"09:00",
    };
}

// ================= HealthKit 管理器 =================
@interface UCSHealth : NSObject
@property (nonatomic, strong) HKHealthStore *store;
- (BOOL)isAuthorized;
- (void)requestAuth:(void(^)(BOOL))cb;
- (void)generateNow:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb;
+ (NSString *)todayString;
@end

@implementation UCSHealth

- (instancetype)init {
    if (self = [super init]) {
        _store = [[HKHealthStore alloc] init];
    }
    return self;
}

- (HKQuantityType *)stepType   { return [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount]; }
- (HKQuantityType *)distType   { return [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning]; }
- (HKQuantityType *)flightsType{ return [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed]; }

- (BOOL)isAuthorized {
    return [self.store authorizationStatusForType:[self stepType]] == HKAuthorizationStatusSharingAuthorized;
}

- (void)requestAuth:(void(^)(BOOL))cb {
    NSSet *share = [NSSet setWithObjects:[self stepType], [self distType], [self flightsType], nil];
    NSSet *read  = [NSSet setWithObjects:[self stepType], [self distType], [self flightsType], nil];
    [self.store requestAuthorizationToShareTypes:share readTypes:read completion:^(BOOL success, NSError *error) {
        if (error) ULog(@"requestAuth error: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{ cb(success); });
    }];
}

// 删除旧的虚拟样本：窗口覆盖全部历史(-730天) ~ +48h（未来样本也删得到）
// v1.0.2 修复跨天污染：
//   1) metadata 同时认 ucsVirtual（本 App）与 com.sykes.ucs.virtualStep（原 sykeswzq/UCS 残留标记，
//      旧版只认 ucsVirtual 导致原项目老样本永远删不掉，微信跨天窗口把它们算进今天）
//   2) 窗口从 -48h 扩到 -730天：历史虚拟样本只应属于其生成当天，跨天后必须清空，
//      否则微信 iOS（读取窗口宽于当天）会把昨天/前天的虚拟残留算进今天的步数
- (void)deleteOldVirtual:(void(^)(BOOL))cb {
    NSDate *start = [[NSDate date] dateByAddingTimeInterval:-730*24*3600];
    NSDate *end   = [[NSDate date] dateByAddingTimeInterval: 48*3600];
    NSPredicate *timePred = [HKQuery predicateForSamplesWithStartDate:start endDate:end options:HKQueryOptionStrictStartDate];
    NSPredicate *m1 = [HKQuery predicateForObjectsWithMetadataKey:@"ucsVirtual"];
    NSPredicate *m2 = [HKQuery predicateForObjectsWithMetadataKey:@"com.sykes.ucs.virtualStep"];
    NSPredicate *metaPred = [NSCompoundPredicate orPredicateWithSubpredicates:@[m1, m2]];
    NSPredicate *pred = [NSCompoundPredicate andPredicateWithSubpredicates:@[timePred, metaPred]];
    NSArray *types = @[[self stepType], [self distType], [self flightsType]];
    [self deleteTypeInArray:types index:0 predicate:pred cb:cb];
}

// v1.0.2：App 每次启动后台清理历史虚拟残留（含原项目 com.sykes.ucs.virtualStep 老样本），
// 不再只依赖「生成时」清理——若当天尚未生成，昨天/前天的虚拟残留会留在 HealthKit 里，
// 微信跨天读取窗口会把它们算进今天的步数（用户实测 5901 = 前天/昨天残留 + 今天 1701）
- (void)cleanupOnLaunch {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self deleteOldVirtual:^(BOOL ok) {
            ULog(@"cleanupOnLaunch: deleteOldVirtual ok=%d", ok);
        }];
    });
}

- (void)deleteTypeInArray:(NSArray *)types index:(NSUInteger)i predicate:(NSPredicate *)pred cb:(void(^)(BOOL))cb {
    if (i >= types.count) { cb(YES); return; }
    HKQuantityType *type = types[i];
    [self.store deleteObjectsOfType:type predicate:pred withCompletion:^(BOOL success, NSUInteger count, NSError *error) {
        if (error) ULog(@"deleteOldVirtual(%@) error: %@", type.identifier, error);
        ULog(@"deleted %lu old virtual %@ samples", (unsigned long)count, type.identifier);
        [self deleteTypeInArray:types index:i+1 predicate:pred cb:cb];
    }];
}

// 写入新样本：优先使用最近 120 分钟内无真实样本的「空分钟」（往过去写，时间贴近实际且不被去重）；
// 空分钟不足时回退到 now+5min 起未来时间（兜底，保持可用）
// v1.0.2 跨天修复：兜底未来时间钳制到「当天 23:59:00」——23:58 生成时 now+5min 会落到明天 00:03，
// 样本跨天导致当天/昨天的统计都被搅乱
- (void)writeSamples:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    NSInteger batch = 500;
    NSInteger n = MAX(1, (steps + batch - 1) / batch);
    [self findEmptyMinutes:^(NSArray<NSDate *> *emptyMin) {
        NSMutableArray *samples = [NSMutableArray array];
        NSDate *nowDate = [NSDate date];
        NSTimeInterval nowT = [nowDate timeIntervalSinceReferenceDate];
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *startOfDay = [cal startOfDayForDate:nowDate];
        NSDate *endOfDay = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:startOfDay options:0];
        NSTimeInterval maxSt = [endOfDay timeIntervalSinceReferenceDate] - 60.0;   // 当天 23:59:00
        NSInteger remaining = steps;
        double distRemaining = dist;
        NSInteger flightsRemaining = flights;
        NSInteger perFlights = (flights + n - 1) / n;
        NSDictionary *meta = @{ @"ucsVirtual": @YES };

        for (NSInteger i = 0; i < n; i++) {
            NSTimeInterval st;
            if (i < (NSInteger)emptyMin.count) {
                st = [emptyMin[i] timeIntervalSinceReferenceDate];   // 空分钟（最近优先）
            } else {
                st = nowT + (i + 1) * 5 * 60;                        // 兜底：未来时间
                if (st > maxSt) st = maxSt;                          // v1.0.2：钳制当天 23:59
            }
            NSTimeInterval en = st + 60;
            NSDate *sd = [NSDate dateWithTimeIntervalSinceReferenceDate:st];
            NSDate *ed = [NSDate dateWithTimeIntervalSinceReferenceDate:en];

            NSInteger s = MIN(batch, remaining); remaining -= s;
            double d = 0;
            if (distRemaining > 0.001) { d = MIN(dist / n, distRemaining); distRemaining -= d; }
            NSInteger f = MIN(perFlights, flightsRemaining); flightsRemaining -= f;

            if (s > 0) {
                HKQuantitySample *ss = [HKQuantitySample quantitySampleWithType:[self stepType]
                    quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:s]
                    startDate:sd endDate:ed metadata:meta];
                [samples addObject:ss];
            }
            if (d > 0.001) {
                HKQuantitySample *ds = [HKQuantitySample quantitySampleWithType:[self distType]
                    quantity:[HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:d]
                    startDate:sd endDate:ed metadata:meta];
                [samples addObject:ds];
            }
            if (f > 0) {
                HKQuantitySample *fs = [HKQuantitySample quantitySampleWithType:[self flightsType]
                    quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:f]
                    startDate:sd endDate:ed metadata:meta];
                [samples addObject:fs];
            }
        }

        if (samples.count == 0) { ULog(@"writeSamples: nothing to write"); cb(NO); return; }
        [self.store saveObjects:samples withCompletion:^(BOOL success, NSError *error) {
            if (error) ULog(@"saveObjects error: %@", error);
            ULog(@"saved %lu samples (steps=%ld dist=%.0fm flights=%ld, emptyMin=%lu)",
                 (unsigned long)samples.count, (long)steps, dist, (long)flights, (unsigned long)emptyMin.count);
            cb(success);
        }];
    }];
}

// 查询最近 120 分钟内的「空分钟」：没有真实步数样本占用的整分钟，从最近到最旧排序
// v1.0.2 跨天修复：窗口起点钳制到「今天 0 点」——凌晨自动生成时（如 00:30），
// 原窗口 now-120min 会覆盖昨天 22:30~23:59，把虚拟样本写进昨天的分钟里，
// 微信跨天窗口会把它们算进「今天」。钳制后凌晨生成的样本只会落在今天。
- (void)findEmptyMinutes:(void(^)(NSArray<NSDate *> *))cb {
    NSDate *now = [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-120*60];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:now];
    if ([start compare:startOfDay] == NSOrderedAscending) start = startOfDay;
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionStrictStartDate];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:[self stepType] predicate:pred limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray<HKSample *> *results, NSError *error) {
        NSMutableSet *occ = [NSMutableSet set];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyyMMddHHmm";
        for (HKSample *s in results) {
            [occ addObject:[f stringFromDate:s.startDate]];
            [occ addObject:[f stringFromDate:s.endDate]];
        }
        NSMutableArray *empty = [NSMutableArray array];
        for (NSInteger m = 119; m >= 0; m--) {   // 从最近往回找
            NSDate *cand = [start dateByAddingTimeInterval:(m + 1) * 60];
            if (![occ containsObject:[f stringFromDate:cand]]) {
                [empty addObject:cand];
            }
        }
        ULog(@"findEmptyMinutes: %lu empty of 120", (unsigned long)empty.count);
        cb(empty);
    }];
    [self.store executeQuery:q];
}

+ (NSString *)todayString {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    return [df stringFromDate:[NSDate date]];
}

// 生成主流程：删旧 -> 写新
- (void)generateNow:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    [self deleteOldVirtual:^(BOOL ok) {
        [self writeSamples:steps distance:dist flights:flights completion:^(BOOL ok2) {
            cb(ok && ok2);
        }];
    }];
}

// 微信同步：杀微信 -> 等待 -> 重新拉起微信，触发其读取 HealthKit 并上传服务器
// iOS 上 system() 不可用，改用 posix_spawn（spawn.h 已在文件头引入）
// v1.0.1：工具路径经 jbroot 解析，App 沙盒视图下 /var/jb 不可直接访问
+ (void)syncWeChat {
    ULog(@"syncWeChat: killing WeChat");
    extern char **environ;
    pid_t pid;
    // 1) 杀微信
    char *kill_argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    const char *kill_path = FindTool(@"/var/jb/usr/bin/killall", @"/usr/bin/killall");
    int rc1 = kill_path ? posix_spawn(&pid, kill_path, NULL, NULL, kill_argv, environ) : -1;
    ULog(@"syncWeChat: kill rc=%d (tool=%s)", rc1, kill_path ?: "none");
    // 2) 等待 2 秒让微信完全退出
    usleep(2 * 1000000);
    // 3) 重新拉起微信，触发服务器同步
    char *ui_argv[] = { (char *)"uiopen", (char *)"com.tencent.xin", NULL };
    const char *ui_path = FindTool(@"/var/jb/usr/bin/uiopen", @"/usr/bin/uiopen");
    int rc2 = ui_path ? posix_spawn(&pid, ui_path, NULL, NULL, ui_argv, environ) : -1;
    ULog(@"syncWeChat: uiopen rc=%d (tool=%s)", rc2, ui_path ?: "none");
}

@end

// ================= 主界面（对齐旧 UCS：InsetGrouped 三区表格） =================
@interface HBMainViewController : UITableViewController
@property (nonatomic, strong) UCSHealth *health;
@property (nonatomic, assign) long steps;
@property (nonatomic, assign) long walkMeters;   // 0 = 自动按 0.7m/步 换算
@property (nonatomic, assign) long flights;
@property (nonatomic, assign) BOOL scheduleOn;
@property (nonatomic, assign) NSInteger schedHour;
@property (nonatomic, assign) NSInteger schedMinute;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIDatePicker *timePicker;
@end

@implementation HBMainViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"UCS";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.health = [[UCSHealth alloc] init];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 48)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.numberOfLines = 0;
    self.tableView.tableFooterView = self.statusLabel;

    [self loadSettings];

    // App 在 mobile 用户上下文运行，自行加载/兜底 LaunchAgent
    // （postinst 以 root 运行 bootstrap 可能失败 exit=45，App 内加载才是 roothide 验证过的方式）
    [self ensureLaunchAgentLoaded];
    // v1.0.2：每次启动即清理历史虚拟残留（跨天污染修复，不依赖生成时清理）
    [self.health cleanupOnLaunch];
    [self updateStatus:@"点击「生成运动数据」后，步数将写入健康，微信运动自动同步。"];

    // 首次请求 HealthKit 授权（仅首次弹窗）
    if (![self.health isAuthorized]) {
        __weak typeof(self) ws = self;
        [self.health requestAuth:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws updateStatus:ok ? @"健康权限已授权" : @"健康权限被拒绝，请到设置中开启"];
            });
        }];
    }
}

- (void)loadSettings {
    NSDictionary *cfg = UCSLoadConfig();
    if (!cfg) { cfg = UCSDefaultConfig(); UCSSaveConfig(cfg); }
    self.steps = [cfg[@"virtualSteps"] integerValue];
    self.walkMeters = [cfg[@"walkDistance"] integerValue];
    self.flights = [cfg[@"flights"] integerValue];
    self.scheduleOn = [cfg[@"scheduleEnabled"] boolValue];
    NSString *t = cfg[@"scheduleTime"];
    NSArray *parts = [t componentsSeparatedByString:@":"];
    self.schedHour = parts.count > 0 ? [parts[0] integerValue] : 9;
    self.schedMinute = parts.count > 1 ? [parts[1] integerValue] : 0;
}

- (void)saveSettings {
    NSDictionary *cfg = @{
        @"virtualSteps"   : @(self.steps),
        @"walkDistance"   : @(self.walkMeters),
        @"flights"        : @(self.flights),
        @"scheduleEnabled": @(self.scheduleOn),
        @"scheduleTime"   : [NSString stringWithFormat:@"%02ld:%02ld", (long)self.schedHour, (long)self.schedMinute],
    };
    UCSSaveConfig(cfg);
}

- (void)updateStatus:(NSString *)msg {
    self.statusLabel.text = msg;
}

// App 在 mobile 用户上下文运行，自行加载/兜底 LaunchAgent
// （postinst 以 root 运行 bootstrap 可能失败 exit=45，App 内加载才是 roothide 验证过的方式）
// v1.0.1：plist 双视图检查 + launchctl 路径 jbroot 解析
// v1.0.4：不再用 popen（App 沙盒里 /bin/sh 相对链接解析失败 → pclose=32512/exit 127、输出为空，
//         且会先 bootout 删掉可用 job 再 bootstrap，导致用户一打开 App 定时 job 就消失）。
//         改为 posix_spawn 直调 launchctl（与 syncWeChat 同款已验证路径），stdout/stderr 重定向到
//         日志文件再读回；先 launchctl print 检查 job 是否已加载——已加载直接跳过（绝不 bootout），
//         未加载才 bootstrap。
- (void)ensureLaunchAgentLoaded {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *plist = @"/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist";
        if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
            // App 沙盒视图：尝试 rootfs 物理视图
            NSString *alt = @"/rootfs/private/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist";
            if ([[NSFileManager defaultManager] fileExistsAtPath:alt]) {
                plist = alt;
            } else {
                ULog(@"ensureLaunchAgent: plist missing: %@ (alt %@)", plist, alt);
                return;
            }
        }
        NSString *lcStr = JBPath(@"/var/jb/usr/bin/launchctl");
        const char *lc = lcStr.UTF8String;
        if (access(lc, X_OK) != 0) lc = "/usr/bin/launchctl";
        extern char **environ;
        NSString *outFile = @"/var/mobile/Documents/ucs_launchctl_out.log";
        // 1) 先检查 job 是否已加载：launchctl print（stdout+stderr 都进日志文件，读回写 ULog）
        {
            char *args[] = { (char *)"launchctl", (char *)"print", (char *)"user/foreground/com.sykes.ucs.schedule", NULL };
            pid_t pid;
            posix_spawn_file_actions_t fa;
            posix_spawn_file_actions_init(&fa);
            int fd = open(outFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                posix_spawn_file_actions_adddup2(&fa, fd, STDOUT_FILENO);
                posix_spawn_file_actions_adddup2(&fa, fd, STDERR_FILENO);
                posix_spawn_file_actions_addclose(&fa, fd);
            }
            int rc = posix_spawn(&pid, lc, &fa, NULL, args, environ);
            if (fd >= 0) close(fd);
            int status = 0;
            if (rc == 0) waitpid(pid, &status, 0);
            NSString *out = [NSString stringWithContentsOfFile:outFile encoding:NSUTF8StringEncoding error:nil];
            ULog(@"ensureLaunchAgent: print rc=%d exit=%d out=%@", rc,
                 (rc == 0 && WIFEXITED(status)) ? WEXITSTATUS(status) : -1, out ?: @"(empty)");
            if (rc == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                ULog(@"ensureLaunchAgent: job already loaded, skip");
                return;
            }
        }
        // 2) job 未加载才 bootstrap（不再 bootout 已有 job）
        {
            char *args[] = { (char *)"launchctl", (char *)"bootstrap", (char *)"user/foreground", (char *)plist.UTF8String, NULL };
            pid_t pid;
            posix_spawn_file_actions_t fa;
            posix_spawn_file_actions_init(&fa);
            int fd = open(outFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                posix_spawn_file_actions_adddup2(&fa, fd, STDOUT_FILENO);
                posix_spawn_file_actions_adddup2(&fa, fd, STDERR_FILENO);
                posix_spawn_file_actions_addclose(&fa, fd);
            }
            int rc = posix_spawn(&pid, lc, &fa, NULL, args, environ);
            if (fd >= 0) close(fd);
            int status = 0;
            if (rc == 0) waitpid(pid, &status, 0);
            NSString *out = [NSString stringWithContentsOfFile:outFile encoding:NSUTF8StringEncoding error:nil];
            ULog(@"ensureLaunchAgent: bootstrap rc=%d exit=%d out=%@", rc,
                 (rc == 0 && WIFEXITED(status)) ? WEXITSTATUS(status) : -1, out ?: @"(empty)");
        }
    });
}

- (double)displayKM {
    double meters = self.walkMeters > 0 ? (double)self.walkMeters : (double)self.steps * 0.7;
    return meters / 1000.0;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"今日数据";
    if (s == 1) return @"操作";
    return @"定时生成";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;
    if (s == 1) return 1;
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.tintColor = [UIColor systemOrangeColor];

    if (ip.section == 0) {
        if (ip.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"figure.walk"];
            cell.textLabel.text = @"步数";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 步", self.steps];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            cell.imageView.image = [UIImage systemImageNamed:@"ruler"];
            cell.textLabel.text = @"距离";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3f 公里", [self displayKM]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"stairs"];
            cell.textLabel.text = @"楼层";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 层", self.flights];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 1) {
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
        cell.textLabel.text = @"生成运动数据";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.detailTextLabel.text = nil;
    } else {
        if (ip.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"clock"];
            cell.textLabel.text = @"每日自动生成";
            cell.detailTextLabel.text = nil;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = self.scheduleOn;
            [sw addTarget:self action:@selector(scheduleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"timer"];
            cell.textLabel.text = @"生成时间";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)self.schedHour, (long)self.schedMinute];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) {
        [self editIntegerWithTitle:@"步数" message:@"设置虚拟步数（在真实步数上累加）" current:self.steps handler:^(long v){
            self.steps = v;
            [self saveSettings];
            [self updateStatus:[NSString stringWithFormat:@"已设置：虚拟步数增量 %ld（点击「生成」按钮生效）", v]];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 0 && ip.row == 1) {
        [self editIntegerWithTitle:@"距离" message:@"设置步行距离（米，0=自动按 0.7m/步 换算）" current:self.walkMeters handler:^(long v){
            self.walkMeters = v;
            [self saveSettings];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 0 && ip.row == 2) {
        [self editIntegerWithTitle:@"楼层" message:@"设置爬楼层数" current:self.flights handler:^(long v){
            self.flights = v;
            [self saveSettings];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 1) {
        [self generateNow];
    } else if (ip.section == 2 && ip.row == 1) {
        [self pickTime];
    }
}

- (void)editIntegerWithTitle:(NSString *)title message:(NSString *)message current:(long)current handler:(void(^)(long))handler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", current];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        long v = [a.textFields.firstObject.text integerValue];
        if (v < 0) v = 0;
        handler(v);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// 滚轮时间选择器（模态导航，对齐旧 UCS）
- (void)pickTime {
    UIViewController *pickerVC = [[UIViewController alloc] init];
    pickerVC.view.backgroundColor = [UIColor systemBackgroundColor];
    pickerVC.title = @"选择生成时间";

    UIDatePicker *p = [[UIDatePicker alloc] init];
    p.datePickerMode = UIDatePickerModeTime;
    p.preferredDatePickerStyle = UIDatePickerStyleWheels;
    p.translatesAutoresizingMaskIntoConstraints = NO;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.hour = self.schedHour; c.minute = self.schedMinute;
    p.date = [cal dateFromComponents:c] ?: [NSDate date];
    [pickerVC.view addSubview:p];
    self.timePicker = p;
    [NSLayoutConstraint activateConstraints:@[
        [p.leadingAnchor constraintEqualToAnchor:pickerVC.view.leadingAnchor],
        [p.trailingAnchor constraintEqualToAnchor:pickerVC.view.trailingAnchor],
        [p.centerYAnchor constraintEqualToAnchor:pickerVC.view.centerYAnchor],
        [p.heightAnchor constraintEqualToConstant:216]
    ]];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(pickTimeDone:)];
    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(dismissPicker)];
    pickerVC.navigationItem.rightBarButtonItem = done;
    pickerVC.navigationItem.leftBarButtonItem = cancel;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pickerVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)pickTimeDone:(id)sender {
    UIDatePicker *p = self.timePicker;
    if (p) {
        NSCalendar *c2 = [NSCalendar currentCalendar];
        NSDateComponents *cc = [c2 components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:p.date];
        self.schedHour = cc.hour;
        self.schedMinute = cc.minute;
        [self saveSettings];
        [self.tableView reloadData];
        [self updateStatus:[NSString stringWithFormat:@"已设置每日 %02ld:%02ld 生成", (long)self.schedHour, (long)self.schedMinute]];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dismissPicker {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)scheduleSwitchChanged:(UISwitch *)sender {
    self.scheduleOn = sender.isOn;
    [self saveSettings];
    [self updateStatus:self.scheduleOn
        ? [NSString stringWithFormat:@"已开启每日 %02ld:%02ld 定时生成", (long)self.schedHour, (long)self.schedMinute]
        : @"已关闭定时"];
}

- (void)generateNow {
    if (self.busy) return;
    if (self.steps <= 0) {
        [self updateStatus:@"请先设置有效的虚拟步数（>0）"];
        return;
    }
    long steps = self.steps;
    double dist = self.walkMeters > 0 ? (double)self.walkMeters : (double)steps * 0.7;
    long flights = self.flights;

    self.busy = YES;
    [self updateStatus:[NSString stringWithFormat:@"正在生成：%ld 步 / %.0f 米 / %ld 层...", (long)steps, dist, (long)flights]];

    __weak typeof(self) ws = self;
    [self.health generateNow:steps distance:dist flights:flights completion:^(BOOL ok) {
        NSString *today = [UCSHealth todayString];
        // lastgen 双视图写入（App 沙盒视图 + 真实视图）
        [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [today writeToFile:@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [UCSHealth syncWeChat];
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.busy = NO;
            [ws updateStatus:ok
                ? [NSString stringWithFormat:@"生成成功：%ld 步 / %.0f 米 / %ld 层\n已写入健康，微信运动已重新拉起同步。", (long)steps, dist, (long)flights]
                : @"生成失败，请查看日志 /var/mobile/Documents/ucs.log"];
            [ws.tableView reloadData];
        });
    }];
}

@end

// ================= AppDelegate（处理 ucs:// URL 与 marker 唤醒） =================
@interface UCSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation UCSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // launchd 定时唤醒：marker 存在 -> 自动生成 -> 退出（不弹 UI）——双视图检查
    if ([[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER] ||
        [[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/mobile/Documents/ucs_wake.marker"]) {
        ULog(@"wake by launchd marker");
        [self runAutoIfDue];
        exit(0);
    }
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[HBMainViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([url.scheme isEqualToString:@"ucs"]) {
        ULog(@"openURL ucs:// (%@)", url.host ?: @"generate");
        // 脚本已写入 marker；若因时序未写入则直接按唤醒处理（双视图检查）
        if (![[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/mobile/Documents/ucs_wake.marker"]) {
            [[NSFileManager defaultManager] createFileAtPath:UCS_MARKER contents:nil attributes:nil];
        }
        [self runAutoIfDue];
        exit(0);
    }
    return YES;
}

// 自动生成流程（headless：不弹授权框，不显示 UI；完成后 exit）
// v1.0.1：marker/lastgen 双视图处理
- (void)runAutoIfDue {
    @autoreleasepool {
        // marker 双视图删除（脚本可能只写了一份）
        [[NSFileManager defaultManager] removeItemAtPath:UCS_MARKER error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:@"/rootfs/private/var/mobile/Documents/ucs_wake.marker" error:nil];

        NSDictionary *cfg = UCSLoadConfig() ?: UCSDefaultConfig();
        if (![cfg[@"scheduleEnabled"] boolValue]) {
            ULog(@"auto skip: schedule disabled");
            return;
        }
        NSString *today = [UCSHealth todayString];
        NSString *last = [NSString stringWithContentsOfFile:UCS_LASTGEN encoding:NSUTF8StringEncoding error:nil];
        if (![last isEqualToString:today]) {
            last = [NSString stringWithContentsOfFile:@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt" encoding:NSUTF8StringEncoding error:nil];
        }
        if ([last isEqualToString:today]) {
            ULog(@"auto skip: already generated today");
            return;
        }
        UCSHealth *h = [[UCSHealth alloc] init];
        if (![h isAuthorized]) {
            ULog(@"auto skip: HealthKit not authorized, open UCS once to authorize");
            return;
        }
        NSInteger steps = [cfg[@"virtualSteps"] integerValue];
        double dist = [cfg[@"walkDistance"] doubleValue];
        if (dist <= 0) dist = steps * 0.7;
        NSInteger flights = [cfg[@"flights"] integerValue];

        ULog(@"auto generate: steps=%ld dist=%.0f flights=%ld", (long)steps, dist, (long)flights);
        __block BOOL done = NO;
        [h generateNow:steps distance:dist flights:flights completion:^(BOOL ok) {
            ULog(@"auto generate result ok=%d", ok);
            // lastgen 双视图写入
            [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [today writeToFile:@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [UCSHealth syncWeChat];
            done = YES;
            CFRunLoopStop(CFRunLoopGetMain());
        }];
        // 等待 HealthKit 异步回调完成
        while (!done) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, YES);
        }
    }
}

@end

// ================= main =================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([UCSAppDelegate class]));
    }
}
