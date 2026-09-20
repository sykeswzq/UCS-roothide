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

// ================= 共享路径（/var/mobile/Documents 为 mobile 用户共享目录，launchd 脚本与 App 均可见） =================
#define UCS_CFG      @"/var/mobile/Documents/ucs_config.plist"
#define UCS_MARKER   @"/var/mobile/Documents/ucs_wake.marker"
#define UCS_LASTGEN  @"/var/mobile/Documents/ucs_lastgen.txt"
#define UCS_LOG      @"/var/mobile/Documents/ucs.log"

// ================= 日志（追加写入，便于排查） =================
void ULog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:UCS_LOG]) {
        [fm createFileAtPath:UCS_LOG contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:UCS_LOG];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"UCS %@", msg);
}

// ================= 配置读写（XML plist，launchd 脚本可用 plutil 读取） =================
static NSDictionary *UCSLoadConfig(void) {
    return [NSDictionary dictionaryWithContentsOfFile:UCS_CFG];
}

static void UCSSaveConfig(NSDictionary *dict) {
    [dict writeToFile:UCS_CFG atomically:YES];
    chmod(UCS_CFG.UTF8String, 0666);
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

// 删除旧的虚拟样本：metadata ucsVirtual=YES，窗口覆盖 -48h ~ +48h（未来样本也删得到）
// BUG 修复：原来只删 stepType，导致楼层/距离每次生成都叠加；现改为串行删除三种类型
- (void)deleteOldVirtual:(void(^)(BOOL))cb {
    NSDate *start = [[NSDate date] dateByAddingTimeInterval:-48*3600];
    NSDate *end   = [[NSDate date] dateByAddingTimeInterval: 48*3600];
    NSPredicate *timePred = [HKQuery predicateForSamplesWithStartDate:start endDate:end options:HKQueryOptionStrictStartDate];
    NSPredicate *metaPred = [HKQuery predicateForObjectsWithMetadataKey:@"ucsVirtual"];
    NSPredicate *pred = [NSCompoundPredicate andPredicateWithSubpredicates:@[timePred, metaPred]];
    NSArray *types = @[[self stepType], [self distType], [self flightsType]];
    [self deleteTypeInArray:types index:0 predicate:pred cb:cb];
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
- (void)writeSamples:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    NSInteger batch = 500;
    NSInteger n = MAX(1, (steps + batch - 1) / batch);
    [self findEmptyMinutes:^(NSArray<NSDate *> *emptyMin) {
        NSMutableArray *samples = [NSMutableArray array];
        NSTimeInterval nowT = [[NSDate date] timeIntervalSinceReferenceDate];
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
- (void)findEmptyMinutes:(void(^)(NSArray<NSDate *> *))cb {
    NSDate *now = [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-120*60];
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
+ (void)syncWeChat {
    ULog(@"syncWeChat: killing WeChat");
    extern char **environ;
    pid_t pid;
    // 1) 杀微信
    char *kill_argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    int rc1 = posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, kill_argv, environ);
    if (rc1 != 0) {
        // 回退到 /usr/bin/killall（非 roothide 布局）
        rc1 = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, kill_argv, environ);
    }
    ULog(@"syncWeChat: kill rc=%d", rc1);
    // 2) 等待 2 秒让微信完全退出
    usleep(2 * 1000000);
    // 3) 重新拉起微信，触发服务器同步
    char *ui_argv[] = { (char *)"uiopen", (char *)"com.tencent.xin", NULL };
    int rc2 = posix_spawn(&pid, "/var/jb/usr/bin/uiopen", NULL, NULL, ui_argv, environ);
    if (rc2 != 0) {
        rc2 = posix_spawn(&pid, "/usr/bin/uiopen", NULL, NULL, ui_argv, environ);
    }
    ULog(@"syncWeChat: uiopen rc=%d", rc2);
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
- (void)ensureLaunchAgentLoaded {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *plist = @"/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist";
        if (![[NSFileManager defaultManager] fileExistsAtPath:plist]) {
            ULog(@"ensureLaunchAgent: plist missing: %@", plist);
            return;
        }
        const char *lc = "/var/jb/usr/bin/launchctl";
        if (access(lc, X_OK) != 0) lc = "/usr/bin/launchctl";
        pid_t pid;
        // bootstrap 已在运行则先 bootout（幂等）
        char *b1[] = { (char *)"launchctl", (char *)"bootout", (char *)"user/foreground/com.sykes.ucs.schedule", NULL };
        posix_spawn(&pid, lc, NULL, NULL, b1, NULL);
        usleep(300 * 1000);
        char *b2[] = { (char *)"launchctl", (char *)"bootstrap", (char *)"user/foreground", (char *)[plist UTF8String], NULL };
        int rc = posix_spawn(&pid, lc, NULL, NULL, b2, NULL);
        int st = 0; if (rc == 0) waitpid(pid, &st, 0);
        ULog(@"ensureLaunchAgent: bootstrap rc=%d status=%d", rc, st);
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
        [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    // launchd 定时唤醒：marker 存在 -> 自动生成 -> 退出（不弹 UI）
    if ([[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER]) {
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
        // 脚本已写入 marker；若因时序未写入则直接按唤醒处理
        if (![[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER]) {
            [[NSFileManager defaultManager] createFileAtPath:UCS_MARKER contents:nil attributes:nil];
        }
        [self runAutoIfDue];
        exit(0);
    }
    return YES;
}

// 自动生成流程（headless：不弹授权框，不显示 UI；完成后 exit）
- (void)runAutoIfDue {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:UCS_MARKER error:nil];

        NSDictionary *cfg = UCSLoadConfig() ?: UCSDefaultConfig();
        if (![cfg[@"scheduleEnabled"] boolValue]) {
            ULog(@"auto skip: schedule disabled");
            return;
        }
        NSString *today = [UCSHealth todayString];
        NSString *last = [NSString stringWithContentsOfFile:UCS_LASTGEN encoding:NSUTF8StringEncoding error:nil];
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
            [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
