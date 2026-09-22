// HealthBoostApp.m - UCS App 涓荤▼搴忥紙鍏ㄦ柊瀹炵幇锛?// 鍔熻兘锛氭墜鍔ㄧ敓鎴愯櫄鎷熸鏁?璺濈/妤煎眰鍒?HealthKit锛涘畾鏃惰嚜鍔ㄧ敓鎴愶紱寰俊鍚屾瑙﹀彂
// 鐜锛歳oothide (Dopamine) / arm64e / iOS 15+
#import <UIKit/UIKit.h>
#import <HealthKit/HealthKit.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

// ================= 鍏变韩璺緞锛?var/mobile/Documents 涓?mobile 鐢ㄦ埛鍏变韩鐩綍锛宭aunchd 鑴氭湰涓?App 鍧囧彲瑙侊級 =================
// 娉ㄦ剰锛坴1.0.1 淇锛夛細App 娌欑洅瑙嗗浘涓?/var/mobile/Documents 鐗╃悊钀界洏鍒?/rootfs/private/var/mobile/Documents/锛?// 涓?launchd 鑴氭湰璇荤殑鐪熷疄瑙嗗浘 inode 涓嶅悓銆侫pp 鍐欏叆淇濇寔 /var/mobile/Documents锛堣惤 rootfs 瑙嗗浘锛夛紝
// 鑴氭湰浼樺厛璇?rootfs 瑙嗗浘銆佸洖閫€鐪熷疄瑙嗗浘锛屼袱渚х粺涓€銆?#define UCS_CFG      @"/var/mobile/Documents/ucs_config.plist"
#define UCS_CFG_ALT  @"/rootfs/private/var/mobile/Documents/ucs_config.plist"
#define UCS_MARKER   @"/var/mobile/Documents/ucs_wake.marker"
#define UCS_LASTGEN  @"/var/mobile/Documents/ucs_lastgen.txt"
#define UCS_LOG      @"/var/mobile/Documents/ucs.log"

// ================= jbroot 璺緞瑙ｆ瀽锛坮oothide锛氭妸 /var/jb 绛夋槧灏勫埌鐪熷疄鐗╃悊璺緞锛?=================
// 鐢ㄤ簬 App 娌欑洅鍐呰皟鐢?/var/jb/usr/bin/ 涓嬬殑宸ュ叿锛坘illall/uiopen锛夛紝dlsym 閬垮厤閾炬帴鏈熺鍙风己澶?static NSString *JBPath(NSString *path) {
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

// 澶氬€欓€夋帰娴嬪彲鎵ц鏂囦欢锛歫broot 瑙ｆ瀽鍚庣殑 /var/jb 璺緞 -> 鍘熷璺緞
static const char *FindTool(NSString *jailPath, NSString *plainPath) {
    NSString *jb = JBPath(jailPath);
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:jb]) return jb.UTF8String;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:plainPath]) return plainPath.UTF8String;
    return NULL;
}

// ================= 鏃ュ織锛堣拷鍔犲啓鍏ワ紝渚夸簬鎺掓煡锛?=================
// v1.0.1锛氬弻瑙嗗浘鍐欏叆锛圓pp 娌欑洅钀界洏瑙嗗浘 + 鐪熷疄瑙嗗浘锛夛紝SSH root 瑙嗗浘涔熻兘鐪嬪埌
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

// ================= 閰嶇疆璇诲啓锛圶ML plist锛宭aunchd 鑴氭湰鍙敤 plutil 璇诲彇锛?=================
// v1.0.1锛氳閰嶇疆鍙岃矾锛堝厛 App 娌欑洅瀹為檯钀界洏瑙嗗浘锛屽啀鐪熷疄瑙嗗浘锛夛紝淇濊瘉涓?launchd 鑴氭湰涓€鑷?static NSDictionary *UCSLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:UCS_CFG];
    if (d) return d;
    return [NSDictionary dictionaryWithContentsOfFile:UCS_CFG_ALT];
}

static void UCSSaveConfig(NSDictionary *dict) {
    [dict writeToFile:UCS_CFG atomically:YES];
    chmod(UCS_CFG.UTF8String, 0666);
    // 鍚屾椂鍐欏叆鐪熷疄瑙嗗浘锛屼繚璇?launchd 鑴氭湰锛坮oot 瑙嗗浘锛変篃鑳借鍒版渶鏂伴厤缃?    [dict writeToFile:UCS_CFG_ALT atomically:YES];
    chmod(UCS_CFG_ALT.UTF8String, 0666);
}

static NSDictionary *UCSDefaultConfig(void) {
    return @{
        @"virtualSteps"   : @5200,
        @"walkDistance"   : @3640,   // 绫筹紝0 琛ㄧず鎸夋鏁拌嚜鍔ㄦ崲绠楋紙绾?0.7m/姝ワ級
        @"flights"        : @0,      // 妤煎眰锛? 琛ㄧず涓嶇敓鎴?        @"scheduleEnabled": @NO,
        @"scheduleTime"   : @"09:00",
    };
}

// ================= HealthKit 绠＄悊鍣?=================
@interface UCSHealth : NSObject
@property (nonatomic, strong) HKHealthStore *store;
// v1.0.8锛氭娴嬪埌閿佸睆鍚?HealthKit 鏁版嵁淇濇姢锛圕ode 6锛夈€傛鏃跺垹/璇讳笉鍙敤锛?// 浣嗗啓鍏ヤ細琚帴鍙楀瓨涓存椂鏂囦欢銆佽В閿佸悗鍚堝苟鈥斺€斾細瀵艰嚧鏃ф牱鏈垹涓嶆帀銆佹柊鏍锋湰鍙犲姞銆?// 妫€娴嬪埌鍒欎笉鍐欐柊鏍锋湰銆佷笉鍐?lastgen锛岃 daemon 瑙ｉ攣鍚庨噸璇曘€?@property (nonatomic, assign) BOOL protectedLocked;
- (BOOL)isAuthorized;
- (void)requestAuth:(void(^)(BOOL))cb;
- (void)generateNow:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb;
+ (NSString *)todayString;
+ (void)syncWeChat;
+ (void)writeStepsFile:(NSInteger)steps;
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

// 鍒犻櫎鏃х殑铏氭嫙鏍锋湰锛氱獥鍙ｈ鐩栧叏閮ㄥ巻鍙?-730澶? ~ +48h锛堟湭鏉ユ牱鏈篃鍒犲緱鍒帮級
// v1.0.2 淇璺ㄥぉ姹℃煋锛?//   1) metadata 鍚屾椂璁?ucsVirtual锛堟湰 App锛変笌 com.sykes.ucs.virtualStep锛堝師 sykeswzq/UCS 娈嬬暀鏍囪锛?//      鏃х増鍙 ucsVirtual 瀵艰嚧鍘熼」鐩€佹牱鏈案杩滃垹涓嶆帀锛屽井淇¤法澶╃獥鍙ｆ妸瀹冧滑绠楄繘浠婂ぉ锛?//   2) 绐楀彛浠?-48h 鎵╁埌 -730澶╋細鍘嗗彶铏氭嫙鏍锋湰鍙簲灞炰簬鍏剁敓鎴愬綋澶╋紝璺ㄥぉ鍚庡繀椤绘竻绌猴紝
//      鍚﹀垯寰俊 iOS锛堣鍙栫獥鍙ｅ浜庡綋澶╋級浼氭妸鏄ㄥぉ/鍓嶅ぉ鐨勮櫄鎷熸畫鐣欑畻杩涗粖澶╃殑姝ユ暟
// v1.0.6锛歝leanupOnLaunch 鏀圭敤 deleteOldVirtualKeepToday锛堟帓闄や粖澶╋紝淇濈暀褰撳ぉ宸茬敓鎴愭暟鎹級锛?//         generateNow 浠嶇敤鍏ㄩ噺鐗堬紙鐢熸垚鍓嶆竻鐞嗛伩鍏嶅彔鍔狅級銆?- (void)deleteOldVirtual:(void(^)(BOOL))cb {
    NSDate *start = [[NSDate date] dateByAddingTimeInterval:-730*24*3600];
    NSDate *end   = [[NSDate date] dateByAddingTimeInterval: 48*3600];
    NSPredicate *timePred = [HKQuery predicateForSamplesWithStartDate:start endDate:end options:HKQueryOptionStrictStartDate];
    [self deleteVirtualWithPredicate:timePred cb:cb];
}

// v1.0.6锛欰pp 鍚姩娓呯悊涓撶敤绐楀彛鈥斺€斿彧鍒犮€屾槰澶╁強鏇存棭銆?-730d~浠婂ぉ0鐐? 涓庛€屾槑澶╁強浠ュ悗銆?浠婂ぉ23:59~+48h)锛?// 淇濈暀浠婂ぉ宸茬敓鎴愮殑铏氭嫙鏍锋湰锛堝惁鍒欑敤鎴锋瘡娆℃墦寮€ App 閮戒細鎶婂畾鏃?鎵嬪姩鍒氱敓鎴愮殑姝ユ暟鍒犳帀锛?// 瀹炴祴 12:09 鎵撳紑 App 鎶?11:57 瀹氭椂鐢熸垚鐨?1000 姝ュ叏鍒犱簡锛?- (void)deleteOldVirtualKeepToday:(void(^)(BOOL))cb {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDate *todayStart = [cal startOfDayForDate:now];
    NSDate *todayEnd = [todayStart dateByAddingTimeInterval:24*3600]; // 鏄庡ぉ 0 鐐?    NSDate *start = [now dateByAddingTimeInterval:-730*24*3600];
    NSDate *end   = [now dateByAddingTimeInterval: 48*3600];
    NSPredicate *hist = [HKQuery predicateForSamplesWithStartDate:start endDate:todayStart options:HKQueryOptionStrictStartDate];
    NSPredicate *futr = [HKQuery predicateForSamplesWithStartDate:todayEnd endDate:end options:HKQueryOptionStrictStartDate];
    NSPredicate *timePred = [NSCompoundPredicate orPredicateWithSubpredicates:@[hist, futr]];
    [self deleteVirtualWithPredicate:timePred cb:cb];
}

- (void)deleteVirtualWithPredicate:(NSPredicate *)timePred cb:(void(^)(BOOL))cb {
    NSPredicate *m1 = [HKQuery predicateForObjectsWithMetadataKey:@"ucsVirtual"];
    NSPredicate *m2 = [HKQuery predicateForObjectsWithMetadataKey:@"com.sykes.ucs.virtualStep"];
    NSPredicate *metaPred = [NSCompoundPredicate orPredicateWithSubpredicates:@[m1, m2]];
    NSPredicate *pred = [NSCompoundPredicate andPredicateWithSubpredicates:@[timePred, metaPred]];
    NSArray *types = @[[self stepType], [self distType], [self flightsType]];
    [self deleteTypeInArray:types index:0 predicate:pred cb:cb];
}

// v1.0.2锛欰pp 姣忔鍚姩鍚庡彴娓呯悊鍘嗗彶铏氭嫙娈嬬暀锛堝惈鍘熼」鐩?com.sykes.ucs.virtualStep 鑰佹牱鏈級锛?// 涓嶅啀鍙緷璧栥€岀敓鎴愭椂銆嶆竻鐞嗏€斺€旇嫢褰撳ぉ灏氭湭鐢熸垚锛屾槰澶?鍓嶅ぉ鐨勮櫄鎷熸畫鐣欎細鐣欏湪 HealthKit 閲岋紝
// 寰俊璺ㄥぉ璇诲彇绐楀彛浼氭妸瀹冧滑绠楄繘浠婂ぉ鐨勬鏁帮紙鐢ㄦ埛瀹炴祴 5901 = 鍓嶅ぉ/鏄ㄥぉ娈嬬暀 + 浠婂ぉ 1701锛?// v1.0.6锛氭敼鐢?KeepToday 绐楀彛锛屾墦寮€ App 涓嶅啀鍒犲綋澶╁凡鐢熸垚鐨勬暟鎹?- (void)cleanupOnLaunch {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self deleteOldVirtualKeepToday:^(BOOL ok) {
            ULog(@"cleanupOnLaunch: deleteOldVirtualKeepToday ok=%d", ok);
        }];
    });
}

- (void)deleteTypeInArray:(NSArray *)types index:(NSUInteger)i predicate:(NSPredicate *)pred cb:(void(^)(BOOL))cb {
    if (i >= types.count) { cb(YES); return; }
    HKQuantityType *type = types[i];
    [self.store deleteObjectsOfType:type predicate:pred withCompletion:^(BOOL success, NSUInteger count, NSError *error) {
        if (error) {
            ULog(@"deleteOldVirtual(%@) error: %@", type.identifier, error);
            // v1.0.8锛欻KError.Code 6 = errorDatabaseInaccessible锛堥攣灞?10鍒嗛挓锛屾暟鎹繚鎶ょ被宸查攣瀹氾級銆?            // 姝ゆ椂鍐欏叆铏借鎺ュ彈浣嗕細鍙犲姞锛屾爣璁?protectedLocked锛屼笂灞傛嵁姝ゆ斁寮冩湰娆″啓鍏ャ€?            if (error.code == 6) { self.protectedLocked = YES; }
        }
        ULog(@"deleted %lu old virtual %@ samples", (unsigned long)count, type.identifier);
        [self deleteTypeInArray:types index:i+1 predicate:pred cb:cb];
    }];
}

// 鍐欏叆鏂版牱鏈細浼樺厛浣跨敤鏈€杩?120 鍒嗛挓鍐呮棤鐪熷疄鏍锋湰鐨勩€岀┖鍒嗛挓銆嶏紙寰€杩囧幓鍐欙紝鏃堕棿璐磋繎瀹為檯涓斾笉琚幓閲嶏級锛?// 绌哄垎閽熶笉瓒虫椂鍥為€€鍒?now+5min 璧锋湭鏉ユ椂闂达紙鍏滃簳锛屼繚鎸佸彲鐢級
// v1.0.2 璺ㄥぉ淇锛氬厹搴曟湭鏉ユ椂闂撮挸鍒跺埌銆屽綋澶?23:59:00銆嶁€斺€?3:58 鐢熸垚鏃?now+5min 浼氳惤鍒版槑澶?00:03锛?// 鏍锋湰璺ㄥぉ瀵艰嚧褰撳ぉ/鏄ㄥぉ鐨勭粺璁￠兘琚悈涔?- (void)writeSamples:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    NSInteger batch = 500;
    NSInteger n = MAX(1, (steps + batch - 1) / batch);
    [self findEmptyMinutes:^(NSArray<NSDate *> *emptyMin) {
        NSMutableArray *samples = [NSMutableArray array];
        NSDate *nowDate = [NSDate date];
        NSTimeInterval nowT = [nowDate timeIntervalSinceReferenceDate];
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *startOfDay = [cal startOfDayForDate:nowDate];
        NSDate *endOfDay = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:startOfDay options:0];
        NSTimeInterval maxSt = [endOfDay timeIntervalSinceReferenceDate] - 60.0;   // 褰撳ぉ 23:59:00
        NSInteger remaining = steps;
        double distRemaining = dist;
        NSInteger flightsRemaining = flights;
        NSInteger perFlights = (flights + n - 1) / n;
        NSDictionary *meta = @{ @"ucsVirtual": @YES };

        for (NSInteger i = 0; i < n; i++) {
            NSTimeInterval st;
            if (i < (NSInteger)emptyMin.count) {
                st = [emptyMin[i] timeIntervalSinceReferenceDate];   // 绌哄垎閽燂紙鏈€杩戜紭鍏堬級
            } else {
                st = nowT + (i + 1) * 5 * 60;                        // 鍏滃簳锛氭湭鏉ユ椂闂?                if (st > maxSt) st = maxSt;                          // v1.0.2锛氶挸鍒跺綋澶?23:59
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

// 鏌ヨ鏈€杩?120 鍒嗛挓鍐呯殑銆岀┖鍒嗛挓銆嶏細娌℃湁鐪熷疄姝ユ暟鏍锋湰鍗犵敤鐨勬暣鍒嗛挓锛屼粠鏈€杩戝埌鏈€鏃ф帓搴?// v1.0.2 璺ㄥぉ淇锛氱獥鍙ｈ捣鐐归挸鍒跺埌銆屼粖澶?0 鐐广€嶁€斺€斿噷鏅ㄨ嚜鍔ㄧ敓鎴愭椂锛堝 00:30锛夛紝
// 鍘熺獥鍙?now-120min 浼氳鐩栨槰澶?22:30~23:59锛屾妸铏氭嫙鏍锋湰鍐欒繘鏄ㄥぉ鐨勫垎閽熼噷锛?// 寰俊璺ㄥぉ绐楀彛浼氭妸瀹冧滑绠楄繘銆屼粖澶┿€嶃€傞挸鍒跺悗鍑屾櫒鐢熸垚鐨勬牱鏈彧浼氳惤鍦ㄤ粖澶┿€?- (void)findEmptyMinutes:(void(^)(NSArray<NSDate *> *))cb {
    NSDate *now = [NSDate date];
    NSDate *start = [now dateByAddingTimeInterval:-120*60];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:now];
    if ([start compare:startOfDay] == NSOrderedAscending) start = startOfDay;
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionStrictStartDate];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:[self stepType] predicate:pred limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray<HKSample *> *results, NSError *error) {
        // v1.0.17锛氶攣灞忔煡璇細鎶?Code6锛宺esults=nil銆傛鏃朵笉鑳芥妸"鏌ヤ笉鍒?褰撴垚"鍏ㄧ┖"锛?        // 鍚﹀垯鏂版牱鏈細钀藉埌宸叉湁鏃ц櫄鎷熸牱鏈殑鍒嗛挓琚幓閲嶃€傛煡璇㈠け璐ョ洿鎺ュ洖璋冪┖鏁扮粍锛?        // 璁?writeSamples 璧?now+5min 鏈潵鏃堕棿鍏滃簳锛岄伩寮€鍐茬獊銆?        if (error) {
            ULog(@"findEmptyMinutes query error: %@ -> fallback future times", error);
            cb(@[]);
            return;
        }
        NSMutableSet *occ = [NSMutableSet set];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyyMMddHHmm";
        for (HKSample *s in results) {
            [occ addObject:[f stringFromDate:s.startDate]];
            [occ addObject:[f stringFromDate:s.endDate]];
        }
        NSMutableArray *empty = [NSMutableArray array];
        for (NSInteger m = 119; m >= 0; m--) {   // 浠庢渶杩戝線鍥炴壘
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

// 鐢熸垚涓绘祦绋嬶細鍒犳棫 -> 鍐欐柊
// v1.0.8锛氳嫢鍒犳棫闃舵妫€娴嬪埌鏁版嵁淇濇姢閿佸畾锛圕ode 6锛夛紝鏀惧純鍐欏叆锛堥伩鍏嶆棫鏍锋湰鍒犱笉鎺夊鑷村彔鍔狅級锛?// 鐩存帴鍥炶皟 NO锛岀敱涓婂眰鍐冲畾涓嶅啓 lastgen銆佺瓑 daemon 閲嶈瘯銆?- (void)generateNow:(NSInteger)steps distance:(double)dist flights:(NSInteger)flights completion:(void(^)(BOOL))cb {
    [self deleteOldVirtual:^(BOOL ok) {
        if (self.protectedLocked) {
            // v1.0.16锛欰pple 瀹樻柟 errorDatabaseInaccessible 璇存槑鈥斺€旈攣灞忔椂鏌ヨ浼氭姤 Code6锛?            // 浣?save 浠嶈鎺ュ彈锛堟殏瀛樹复鏃舵枃浠讹紝瑙ｉ攣鍚庤嚜鍔ㄥ悎骞讹級銆傛晠閿佸睆鏃朵笉鏀惧純鍐欏叆锛?            // 璺宠繃鏈 delete锛堝巻鍙叉牱鏈潬涓嬫瑙ｉ攣鍚?cleanupOnLaunch 娓呯悊锛夛紝鐩存帴 save銆?            ULog(@"generateNow: locked, skip delete but save directly (Apple: locked save allowed)");
        }
        [self writeSamples:steps distance:dist flights:flights completion:^(BOOL ok2) {
            cb(ok2);
        }];
    }];
}

// 寰俊鍚屾锛氭潃寰俊 -> 绛夊緟 -> 閲嶆柊鎷夎捣寰俊锛岃Е鍙戝叾璇诲彇 HealthKit 骞朵笂浼犳湇鍔″櫒
// iOS 涓?system() 涓嶅彲鐢紝鏀圭敤 posix_spawn锛坰pawn.h 宸插湪鏂囦欢澶村紩鍏ワ級
// v1.0.1锛氬伐鍏疯矾寰勭粡 jbroot 瑙ｆ瀽锛孉pp 娌欑洅瑙嗗浘涓?/var/jb 涓嶅彲鐩存帴璁块棶
+ (void)syncWeChat {
    ULog(@"syncWeChat: killing WeChat");
    extern char **environ;
    pid_t pid;
    // 1) 鏉€寰俊
    char *kill_argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    const char *kill_path = FindTool(@"/var/jb/usr/bin/killall", @"/usr/bin/killall");
    int rc1 = kill_path ? posix_spawn(&pid, kill_path, NULL, NULL, kill_argv, environ) : -1;
    ULog(@"syncWeChat: kill rc=%d (tool=%s)", rc1, kill_path ?: "none");
    // 2) 绛夊緟 2 绉掕寰俊瀹屽叏閫€鍑?    usleep(2 * 1000000);
    // 3) 閲嶆柊鎷夎捣寰俊锛岃Е鍙戞湇鍔″櫒鍚屾
    char *ui_argv[] = { (char *)"uiopen", (char *)"com.tencent.xin", NULL };
    const char *ui_path = FindTool(@"/var/jb/usr/bin/uiopen", @"/usr/bin/uiopen");
    int rc2 = ui_path ? posix_spawn(&pid, ui_path, NULL, NULL, ui_argv, environ) : -1;
    ULog(@"syncWeChat: uiopen rc=%d (tool=%s)", rc2, ui_path ?: "none");
}

// ================= v1.0.11锛氬啓 hb_steps.txt 渚?StepFaker tweak 璇诲彇锛堢Щ妞嶈嚜 v4.4.25 楠岃瘉鐗堬級 =================
// StepFaker 娉ㄥ叆鍒板井淇¤繘绋嬪悗锛屼粠澶氭潯閫氶亾璇汇€岃櫄鎷熸鏁板閲忋€嶏紝hook CMPedometer/HealthKit 杩斿洖 鐪熷疄+铏氭嫙銆?// 寰俊鏄櫘閫?App Store 搴旂敤銆佽窇鍦ㄦ矙鐩掗噷璇讳笉鍒板閮ㄦ枃浠讹紝鏁呭繀椤绘妸 hb_steps.txt 鍐欒繘寰俊鑷繁鐨勬暟鎹鍣ㄣ€?// 鏂囦欢鏍煎紡锛氱涓€琛屾暟瀛楋紝绗簩琛?date:YYYY-MM-DD锛坱weak 鎹鍋氥€屼粖澶┿€嶆牎楠岋紝閬垮厤璺ㄥぉ娈嬬暀锛夈€?+ (NSString *)hbDateLine {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"date:%@", [f stringFromDate:[NSDate date]]];
}

+ (void)hbWriteContent:(NSString *)content toPath:(NSString *)path label:(NSString *)label {
    NSError *err = nil;
    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    if (ok) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
    ULog(@"hb_steps %@ ok=%d path=%@", label, ok, path);
}

// 鎵弿鎵€鏈夊井淇＄浉鍏虫暟鎹鍣紙涓诲井淇?com.tencent.xin銆乁GGD銆乧om.tencent.* 鎵╁睍锛?+ (NSArray<NSString *> *)hbWeChatContainers {
    NSMutableArray *out = [NSMutableArray array];
    // roothide App 瑙嗗浘 + 鐪熷疄瑙嗗浘閮芥壂涓€閬?    NSArray *bases = @[ @"/var/mobile/Containers/Data/Application",
                        @"/var/roothide/var/mobile/Containers/Data/Application",
                        @"/rootfs/private/var/mobile/Containers/Data/Application" ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *base in bases) {
        NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *d in dirs) {
            NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
            NSString *ident = dict[@"MCMMetadataIdentifier"];
            if ([ident isEqualToString:@"com.tencent.xin"] ||
                [ident isEqualToString:@"UGGD"] ||
                [ident hasPrefix:@"com.tencent"]) {
                [out addObject:[base stringByAppendingFormat:@"/%@", d]];
            }
        }
    }
    return out;
}

+ (void)writeStepsFile:(NSInteger)steps {
    @autoreleasepool {
        NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", (long)steps, [self hbDateLine]];
        NSFileManager *fm = [NSFileManager defaultManager];

        // 閫氶亾 1锛氬啓杩涘井淇¤嚜宸辩殑鏁版嵁瀹瑰櫒 Documents锛堟矙鐩掑唴蹇呭畾鍙锛屼富閫氶亾锛?        NSArray *containers = [self hbWeChatContainers];
        for (NSString *c in containers) {
            NSString *doc = [c stringByAppendingPathComponent:@"Documents"];
            if (![fm fileExistsAtPath:doc]) [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *p = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
            if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
            [self hbWriteContent:content toPath:p label:@"wechat-container"];
        }
        ULog(@"hb_steps wechat containers count=%lu", (unsigned long)containers.count);

        // 閫氶亾 2锛?var/mobile/Documents锛圓pp 瑙嗗浘 + rootfs 鐪熷疄瑙嗗浘锛?        [self hbWriteContent:content toPath:@"/var/mobile/Documents/hb_steps.txt" label:@"var-mobile-doc"];
        [self hbWriteContent:content toPath:@"/rootfs/private/var/mobile/Documents/hb_steps.txt" label:@"rootfs-doc"];

        // 閫氶亾 3锛欰pp 鑷韩瀹瑰櫒 Documents锛坱weak 鈶 浼氭灇涓?com.sykes.ucs.app 瀹瑰櫒锛?        NSString *ownDoc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (ownDoc) [self hbWriteContent:content toPath:[ownDoc stringByAppendingPathComponent:@"hb_steps.txt"] label:@"own-container"];

        // 閫氶亾 4锛?var/mobile/Media/HealthBoost锛堟棤娌欑洅杩涚▼鍙锛?        NSString *mediaDir = @"/var/mobile/Media/HealthBoost";
        if (![fm fileExistsAtPath:mediaDir]) [fm createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:nil];
        [self hbWriteContent:content toPath:[mediaDir stringByAppendingPathComponent:@"hb_steps.txt"] label:@"media"];

        // 閫氶亾 5锛欳FPreferences 绯荤粺鍩?        CFPreferencesSetValue(CFSTR("steps"), (__bridge CFNumberRef)@(steps),
                              CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("stepsDate"), (__bridge CFStringRef)[[self hbDateLine] substringFromIndex:5],
                              CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
        ULog(@"hb_steps writeStepsFile done steps=%ld", (long)steps);
    }
}

@end

// ================= 涓荤晫闈紙瀵归綈鏃?UCS锛欼nsetGrouped 涓夊尯琛ㄦ牸锛?=================
@interface HBMainViewController : UITableViewController
@property (nonatomic, strong) UCSHealth *health;
@property (nonatomic, assign) long steps;
@property (nonatomic, assign) long walkMeters;   // 0 = 鑷姩鎸?0.7m/姝?鎹㈢畻
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

    // App 鍦?mobile 鐢ㄦ埛涓婁笅鏂囪繍琛岋紝鑷鍔犺浇/鍏滃簳 LaunchAgent
    // 锛坧ostinst 浠?root 杩愯 bootstrap 鍙兘澶辫触 exit=45锛孉pp 鍐呭姞杞芥墠鏄?roothide 楠岃瘉杩囩殑鏂瑰紡锛?    [self ensureLaunchAgentLoaded];
    // v1.0.2锛氭瘡娆″惎鍔ㄥ嵆娓呯悊鍘嗗彶铏氭嫙娈嬬暀锛堣法澶╂薄鏌撲慨澶嶏紝涓嶄緷璧栫敓鎴愭椂娓呯悊锛?    [self.health cleanupOnLaunch];
    [self updateStatus:@"鐐瑰嚮銆岀敓鎴愯繍鍔ㄦ暟鎹€嶅悗锛屾鏁板皢鍐欏叆鍋ュ悍锛屽井淇¤繍鍔ㄨ嚜鍔ㄥ悓姝ャ€?];

    // 棣栨璇锋眰 HealthKit 鎺堟潈锛堜粎棣栨寮圭獥锛?    if (![self.health isAuthorized]) {
        __weak typeof(self) ws = self;
        [self.health requestAuth:^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws updateStatus:ok ? @"鍋ュ悍鏉冮檺宸叉巿鏉? : @"鍋ュ悍鏉冮檺琚嫆缁濓紝璇峰埌璁剧疆涓紑鍚?];
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

// App 鍦?mobile 鐢ㄦ埛涓婁笅鏂囪繍琛岋紝鑷鍔犺浇/鍏滃簳 LaunchAgent
// 锛坧ostinst 浠?root 杩愯 bootstrap 鍙兘澶辫触 exit=45锛孉pp 鍐呭姞杞芥墠鏄?roothide 楠岃瘉杩囩殑鏂瑰紡锛?// v1.0.1锛歱list 鍙岃鍥炬鏌?+ launchctl 璺緞 jbroot 瑙ｆ瀽
// v1.0.4锛氫笉鍐嶇敤 popen锛圓pp 娌欑洅閲?/bin/sh 鐩稿閾炬帴瑙ｆ瀽澶辫触 鈫?pclose=32512/exit 127銆佽緭鍑轰负绌猴紝
//         涓斾細鍏?bootout 鍒犳帀鍙敤 job 鍐?bootstrap锛屽鑷寸敤鎴蜂竴鎵撳紑 App 瀹氭椂 job 灏辨秷澶憋級銆?//         鏀逛负 posix_spawn 鐩磋皟 launchctl锛堜笌 syncWeChat 鍚屾宸查獙璇佽矾寰勶級锛宻tdout/stderr 閲嶅畾鍚戝埌
//         鏃ュ織鏂囦欢鍐嶈鍥烇紱鍏?launchctl print 妫€鏌?job 鏄惁宸插姞杞解€斺€斿凡鍔犺浇鐩存帴璺宠繃锛堢粷涓?bootout锛夛紝
//         鏈姞杞芥墠 bootstrap銆?// v1.0.5锛欰pp 娌欑洅鍐?launchctl print 瑙嗚涓?root 涓嶄竴鑷达紙瀹炴祴 print 鎶?Could not find service锛?//         bootstrap 蹇呮姤 Operation not permitted锛夛紝涓?job 鐢?postinst root 鐩磋繛 bootstrap 鎸傝浇
//         锛堝凡楠岃瘉鍙锛夈€侫pp 鍐呭彧鍋?print 妫€鏌ュ啓鏃ュ織锛岀粷涓?bootstrap/bootout锛屾墦寮€闆跺壇浣滅敤銆?- (void)ensureLaunchAgentLoaded {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *lcStr = JBPath(@"/var/jb/usr/bin/launchctl");
        const char *lc = lcStr.UTF8String;
        if (access(lc, X_OK) != 0) lc = "/usr/bin/launchctl";
        extern char **environ;
        NSString *outFile = @"/var/mobile/Documents/ucs_launchctl_out.log";
        // 鍙妫€鏌ワ細launchctl print锛坰tdout+stderr 閮借繘鏃ュ織鏂囦欢锛岃鍥炲啓 ULog锛?        char *args[] = { (char *)"launchctl", (char *)"print", (char *)"user/foreground/com.sykes.ucs.schedule", NULL };
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
        posix_spawn_file_actions_destroy(&fa);
        // 鏃犺鏄惁宸插姞杞斤紝App 鍐呴兘涓嶅仛浠讳綍淇敼锛坆ootstrap 鍦ㄦ矙鐩掑唴蹇呭け璐ワ紝涓?job 鐢?postinst 璐熻矗锛?    });
}

- (double)displayKM {
    double meters = self.walkMeters > 0 ? (double)self.walkMeters : (double)self.steps * 0.7;
    return meters / 1000.0;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"浠婃棩鏁版嵁";
    if (s == 1) return @"鎿嶄綔";
    return @"瀹氭椂鐢熸垚";
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
            cell.textLabel.text = @"姝ユ暟";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 姝?, self.steps];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            cell.imageView.image = [UIImage systemImageNamed:@"ruler"];
            cell.textLabel.text = @"璺濈";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3f 鍏噷", [self displayKM]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"stairs"];
            cell.textLabel.text = @"妤煎眰";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 灞?, self.flights];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 1) {
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
        cell.textLabel.text = @"鐢熸垚杩愬姩鏁版嵁";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.detailTextLabel.text = nil;
    } else {
        if (ip.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"clock"];
            cell.textLabel.text = @"姣忔棩鑷姩鐢熸垚";
            cell.detailTextLabel.text = nil;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = self.scheduleOn;
            [sw addTarget:self action:@selector(scheduleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"timer"];
            cell.textLabel.text = @"鐢熸垚鏃堕棿";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)self.schedHour, (long)self.schedMinute];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) {
        [self editIntegerWithTitle:@"姝ユ暟" message:@"璁剧疆铏氭嫙姝ユ暟锛堝湪鐪熷疄姝ユ暟涓婄疮鍔狅級" current:self.steps handler:^(long v){
            self.steps = v;
            [self saveSettings];
            [self updateStatus:[NSString stringWithFormat:@"宸茶缃細铏氭嫙姝ユ暟澧為噺 %ld锛堢偣鍑汇€岀敓鎴愩€嶆寜閽敓鏁堬級", v]];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 0 && ip.row == 1) {
        [self editIntegerWithTitle:@"璺濈" message:@"璁剧疆姝ヨ璺濈锛堢背锛?=鑷姩鎸?0.7m/姝?鎹㈢畻锛? current:self.walkMeters handler:^(long v){
            self.walkMeters = v;
            [self saveSettings];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 0 && ip.row == 2) {
        [self editIntegerWithTitle:@"妤煎眰" message:@"璁剧疆鐖ゼ灞傛暟" current:self.flights handler:^(long v){
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
    [a addAction:[UIAlertAction actionWithTitle:@"鍙栨秷" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"纭畾" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        long v = [a.textFields.firstObject.text integerValue];
        if (v < 0) v = 0;
        handler(v);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// 婊氳疆鏃堕棿閫夋嫨鍣紙妯℃€佸鑸紝瀵归綈鏃?UCS锛?- (void)pickTime {
    UIViewController *pickerVC = [[UIViewController alloc] init];
    pickerVC.view.backgroundColor = [UIColor systemBackgroundColor];
    pickerVC.title = @"閫夋嫨鐢熸垚鏃堕棿";

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

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"瀹屾垚"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(pickTimeDone:)];
    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"鍙栨秷"
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
        [self updateStatus:[NSString stringWithFormat:@"宸茶缃瘡鏃?%02ld:%02ld 鐢熸垚", (long)self.schedHour, (long)self.schedMinute]];
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
        ? [NSString stringWithFormat:@"宸插紑鍚瘡鏃?%02ld:%02ld 瀹氭椂鐢熸垚", (long)self.schedHour, (long)self.schedMinute]
        : @"宸插叧闂畾鏃?];
}

- (void)generateNow {
    if (self.busy) return;
    if (self.steps <= 0) {
        [self updateStatus:@"璇峰厛璁剧疆鏈夋晥鐨勮櫄鎷熸鏁帮紙>0锛?];
        return;
    }
    long steps = self.steps;
    double dist = self.walkMeters > 0 ? (double)self.walkMeters : (double)steps * 0.7;
    long flights = self.flights;

    self.busy = YES;
    [self updateStatus:[NSString stringWithFormat:@"姝ｅ湪鐢熸垚锛?ld 姝?/ %.0f 绫?/ %ld 灞?..", (long)steps, dist, (long)flights]];

    __weak typeof(self) ws = self;
    [self.health generateNow:steps distance:dist flights:flights completion:^(BOOL ok) {
        NSString *today = [UCSHealth todayString];
        // lastgen 鍙岃鍥惧啓鍏ワ紙App 娌欑洅瑙嗗浘 + 鐪熷疄瑙嗗浘锛?        [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [today writeToFile:@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (ok) {
            // v1.0.11锛氬啓 hb_steps.txt 渚?StepFaker 璇诲彇鍚庯紝鍐嶉噸鍚井淇?            [UCSHealth writeStepsFile:steps];
            [UCSHealth syncWeChat];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.busy = NO;
            [ws updateStatus:ok
                ? [NSString stringWithFormat:@"鐢熸垚鎴愬姛锛?ld 姝?/ %.0f 绫?/ %ld 灞俓n宸插啓鍏ュ仴搴凤紝寰俊杩愬姩宸查噸鏂版媺璧峰悓姝ャ€?, (long)steps, dist, (long)flights]
                : @"鐢熸垚澶辫触锛岃鏌ョ湅鏃ュ織 /var/mobile/Documents/ucs.log"];
            [ws.tableView reloadData];
        });
    }];
}

@end

// ================= AppDelegate锛堝鐞?ucs:// URL 涓?marker 鍞ら啋锛?=================
@interface UCSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation UCSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // launchd 瀹氭椂鍞ら啋锛歮arker 瀛樺湪 -> 鑷姩鐢熸垚 -> 閫€鍑猴紙涓嶅脊 UI锛夆€斺€斿弻瑙嗗浘妫€鏌?    if ([[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER] ||
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
        // 鑴氭湰宸插啓鍏?marker锛涜嫢鍥犳椂搴忔湭鍐欏叆鍒欑洿鎺ユ寜鍞ら啋澶勭悊锛堝弻瑙嗗浘妫€鏌ワ級
        if (![[NSFileManager defaultManager] fileExistsAtPath:UCS_MARKER] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/mobile/Documents/ucs_wake.marker"]) {
            [[NSFileManager defaultManager] createFileAtPath:UCS_MARKER contents:nil attributes:nil];
        }
        [self runAutoIfDue];
        exit(0);
    }
    return YES;
}

// 鑷姩鐢熸垚娴佺▼锛坔eadless锛氫笉寮规巿鏉冩锛屼笉鏄剧ず UI锛涘畬鎴愬悗 exit锛?// v1.0.1锛歮arker/lastgen 鍙岃鍥惧鐞?- (void)runAutoIfDue {
    @autoreleasepool {
        // marker 鍙岃鍥惧垹闄わ紙鑴氭湰鍙兘鍙啓浜嗕竴浠斤級
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
            // v1.0.8锛氶攣灞忔暟鎹繚鎶ら攣瀹氭椂 ok=NO 涓?protectedLocked=YES锛?            // 涓嶅啓 lastgen銆佷笉鍚屾寰俊鈥斺€攄aemon 涓嬩竴杞紙瑙ｉ攣鍚庯級浼氶噸璇曘€?            if (ok) {
                // v1.0.16锛歴ave 鎴愬姛鍗宠惤鐩橈紙閿佸睆涓?Apple 鍏佽 save锛岃В閿佽嚜鍔ㄥ悎骞讹級銆?                // lastgen 鍙岃鍥惧啓鍏ワ紝鏍囪浠婂ぉ宸茬敓鎴愶紝閬垮厤閲嶅銆?                [today writeToFile:UCS_LASTGEN atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [today writeToFile:@"/rootfs/private/var/mobile/Documents/ucs_lastgen.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
                // 鍐?hb_steps.txt 渚?StepFaker 璇诲彇
                [UCSHealth writeStepsFile:steps];
                if (!h.protectedLocked) {
                    // 浜睆锛氶噸鍚井淇¤Е鍙戜笂浼?                    [UCSHealth syncWeChat];
                } else {
                    // 閿佸睆锛氭媺涓嶈捣寰俊鍓嶅彴锛宧b_steps 宸插啓浠婂ぉ锛涜В閿佸悗寮€寰俊鍗宠浠婂ぉ鍊?                    ULog(@"locked: saved, wechat will pick up on next open");
                }
            }
            done = YES;
            CFRunLoopStop(CFRunLoopGetMain());
        }];
        // 绛夊緟 HealthKit 寮傛鍥炶皟瀹屾垚
        while (!done) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, YES);
        }
    }
}

@end

// ================= main =================
// v1.0.7锛?-cli 鍛戒护琛屾ā寮忋€俤aemon 涓嶅啀 uiopen 鎷夎捣 UI锛堥攣灞忔椂 SpringBoard 涓嶅搷搴斾細鎸備綇锛夛紝
// 鑰屾槸鐩存帴浠?mobile 韬唤鎵ц UCS --cli锛岃窇 runAutoIfDue锛堝垹鏃?>鍐欐柊->鍚屾寰俊->鍐?lastgen锛夛紝
// 涓嶅惎鍔?UIKit銆佷笉渚濊禆浜睆锛岄攣灞?鍒掓帀 App 涔熻兘瀹屾垚鐢熸垚銆?int main(int argc, char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--cli") == 0) {
                NSLog(@"UCS CLI mode start");
                @autoreleasepool {
                    id del = [[NSClassFromString(@"UCSAppDelegate") alloc] init];
                    [del performSelector:@selector(runAutoIfDue)];
                }
                NSLog(@"UCS CLI mode exit");
                return 0;
            }
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([UCSAppDelegate class]));
    }
}
