// HealthBoostApp.m - UCS App 主程序（全新实现）
// 功能：手动生成虚拟步数/距离/楼层到 HealthKit；定时自动生成；微信同步触发
// 环境：roothide (Dopamine) / arm64e / iOS 15+
#import <UIKit/UIKit.h>
#import <HealthKit/HealthKit.h>
#import <dlfcn.h>
#import <spawn.h>
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
- (void)deleteOldVirtual:(void(^)(BOOL))cb {
    NSDate *start = [[NSDate date] dateByAddingTimeInterval:-48*3600];
    NSDate *end   = [[NSDate date] dateByAddingTimeInterval: 48*3600];
    NSPredicate *timePred = [HKQuery predicateForSamplesWithStartDate:start endDate:end options:HKQueryOptionStrictStartDate];
    NSPredicate *metaPred = [HKQuery predicateForObjectsWithMetadataKey:@"ucsVirtual"];
    NSPredicate *pred = [NSCompoundPredicate andPredicateWithSubpredicates:@[timePred, metaPred]];
    [self.store deleteObjectsOfType:[self stepType] predicate:pred withCompletion:^(BOOL success, NSUInteger count, NSError *error) {
        if (error) ULog(@"deleteOldVirtual error: %@", error);
        ULog(@"deleted %lu old virtual samples", (unsigned long)count);
        cb(success);
    }];
}

// 写入新样本：从 now+5min 起，每批 2 分钟间隔（未来时间可避免被 HealthKit 按真实样本去重）
- (void)writeSamples:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    NSMutableArray *samples = [NSMutableArray array];
    NSInteger batch = 500;
    NSInteger n = MAX(1, (steps + batch - 1) / batch);
    NSTimeInterval base = [[NSDate date] timeIntervalSinceReferenceDate] + 5*60;
    NSInteger remaining = steps;
    double distRemaining = dist;
    NSInteger flightsRemaining = flights;
    NSInteger perFlights = (flights + n - 1) / n;
    NSDictionary *meta = @{ @"ucsVirtual": @YES };

    for (NSInteger i = 0; i < n; i++) {
        NSTimeInterval st = base + i*2*60;
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
        ULog(@"saved %lu samples (steps=%ld dist=%.0fm flights=%ld)", (unsigned long)samples.count, (long)steps, dist, (long)flights);
        cb(success);
    }];
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

// ================= 手动生成界面 =================
@interface UCSViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UCSHealth *health;
@property (nonatomic, strong) UITextField *stepsField;
@property (nonatomic, strong) UITextField *distField;
@property (nonatomic, strong) UITextField *flightsField;
@property (nonatomic, strong) UITextField *timeField;
@property (nonatomic, strong) UISwitch *schedSwitch;
@property (nonatomic, strong) UIButton *genButton;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation UCSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.health = [[UCSHealth alloc] init];

    NSDictionary *cfg = UCSLoadConfig();
    if (!cfg) { cfg = UCSDefaultConfig(); UCSSaveConfig(cfg); }

    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 120;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, w-40, 32)];
    title.text = @"UCS 运动数据生成";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(20, 96, w-40, 16)];
    ver.text = @"v1.0.0 · roothide · arm64e";
    ver.font = [UIFont systemFontOfSize:12];
    ver.textColor = [UIColor secondaryLabelColor];
    ver.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:ver];

    // 步数
    _stepsField = [self fieldWithFrame:CGRectMake(20, y, w-40, 44) placeholder:@"虚拟步数（如 5200）" text:[cfg[@"virtualSteps"] stringValue]];
    [self.view addSubview:_stepsField];
    y += 52;

    // 距离（可选，0=自动按 0.7m/步 换算）
    _distField = [self fieldWithFrame:CGRectMake(20, y, w-40, 44) placeholder:@"步行距离 米（留空=自动换算）" text:[cfg[@"walkDistance"] stringValue]];
    [self.view addSubview:_distField];
    y += 52;

    // 楼层（可选，0=不生成）
    _flightsField = [self fieldWithFrame:CGRectMake(20, y, w-40, 44) placeholder:@"爬楼楼层（留空=0 不生成）" text:[cfg[@"flights"] stringValue]];
    [self.view addSubview:_flightsField];
    y += 52;

    // 定时开关
    UILabel *schedLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w-120, 40)];
    schedLabel.text = @"每日定时自动生成";
    [self.view addSubview:schedLabel];
    _schedSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w-70, y+5, 60, 30)];
    _schedSwitch.on = [cfg[@"scheduleEnabled"] boolValue];
    [self.view addSubview:_schedSwitch];
    y += 48;

    // 定时时间
    _timeField = [self fieldWithFrame:CGRectMake(20, y, w-40, 44) placeholder:@"定时时间 HH:mm（如 09:00）" text:cfg[@"scheduleTime"]];
    _timeField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    [self.view addSubview:_timeField];
    y += 52;

    // 生成按钮
    _genButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _genButton.frame = CGRectMake(20, y, w-40, 48);
    _genButton.backgroundColor = [UIColor systemBlueColor];
    [_genButton setTitle:@"生成运动数据" forState:UIControlStateNormal];
    [_genButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _genButton.layer.cornerRadius = 10;
    [_genButton addTarget:self action:@selector(onGenerate) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_genButton];
    y += 60;

    // 状态
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w-40, 120)];
    _statusLabel.numberOfLines = 0;
    _statusLabel.font = [UIFont systemFontOfSize:13];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.text = @"点击「生成运动数据」后，步数将写入健康，微信运动自动同步。";
    [self.view addSubview:_statusLabel];

    // 首次请求 HealthKit 授权
    if (![self.health isAuthorized]) {
        [self.health requestAuth:^(BOOL ok) {
            self->_statusLabel.text = ok ? @"健康权限已授权" : @"健康权限被拒绝，请到设置中开启";
        }];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKB)];
    [self.view addGestureRecognizer:tap];
}

- (UITextField *)fieldWithFrame:(CGRect)frame placeholder:(NSString *)ph text:(NSString *)text {
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.placeholder = ph;
    f.text = text;
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.delegate = self;
    return f;
}

- (void)dismissKB { [self.view endEditing:YES]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)onGenerate {
    [self.view endEditing:YES];
    NSInteger steps = [self.stepsField.text integerValue];
    if (steps <= 0) {
        self.statusLabel.text = @"请输入有效的虚拟步数（>0）";
        return;
    }
    double dist = [self.distField.text doubleValue];
    if (dist <= 0) dist = steps * 0.7; // 自动换算
    NSInteger flights = [self.flightsField.text integerValue];

    // 保存配置（含定时设置）
    NSString *time = self.timeField.text;
    if (time.length < 5) time = @"09:00";
    NSDictionary *cfg = @{
        @"virtualSteps"   : @(steps),
        @"walkDistance"   : @((NSInteger)dist),
        @"flights"        : @(flights),
        @"scheduleEnabled": @(self.schedSwitch.isOn),
        @"scheduleTime"   : time,
    };
    UCSSaveConfig(cfg);

    self.genButton.enabled = NO;
    self.statusLabel.text = [NSString stringWithFormat:@"正在生成：%ld 步 / %.0f 米 / %ld 层...", (long)steps, dist, (long)flights];

    __weak typeof(self) ws = self;
    [self.health generateNow:steps distance:dist flights:flights completion:^(BOOL ok) {
        NSString *today = [UCSHealth todayString];
        [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [UCSHealth syncWeChat];
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.genButton.enabled = YES;
            ws.statusLabel.text = ok
                ? [NSString stringWithFormat:@"生成成功：%ld 步 / %.0f 米 / %ld 层\n已写入健康，微信运动已重新拉起同步。", (long)steps, dist, (long)flights]
                : @"生成失败，请查看日志 /var/mobile/Documents/ucs.log";
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
    self.window.rootViewController = [[UCSViewController alloc] init];
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
