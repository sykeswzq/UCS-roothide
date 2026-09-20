// StepFaker.m - 微信计步注入模块（全新实现）
// 注入目标：com.tencent.xin (微信)
// 原理：hook CMPedometerData.numberOfSteps，返回「真实步数 + 虚拟步数」，
//       虚拟步数从共享配置 /var/mobile/Documents/ucs_config.plist 读取（经 jbroot 解析真实路径）。
// 服务器同步：微信进程启动时读取 HealthKit 总步数并上传；UCS 生成后杀微信并重新拉起即触发。
// 环境：roothide (Dopamine) / arm64e / iOS 15+
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// roothide 路径解析：微信进程运行在自身 .jbroot 沙盒中，
// 必须通过 jbroot() 把 /var/mobile/Documents/... 解析为真实路径才能读到共享配置。
// 使用 dlsym 获取 C 原型 const char* jbroot(const char*)，避免链接期符号未解析崩溃。
static NSString *StepFakerJbrootPath(NSString *path) {
    static const char *(*jbroot_fn)(const char *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sym = dlsym(RTLD_DEFAULT, "jbroot");
        if (sym) jbroot_fn = (const char *(*)(const char *))sym;
    });
    if (jbroot_fn) {
        const char *res = jbroot_fn([path UTF8String]);
        if (res) return [NSString stringWithUTF8String:res];
    }
    return path;
}

// 读取虚拟步数（失败返回 0）
static NSInteger StepFakerVirtualSteps(void) {
    @try {
        NSString *real = StepFakerJbrootPath(@"/var/mobile/Documents/ucs_config.plist");
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:real];
        NSNumber *v = cfg[@"virtualSteps"];
        if (v && [v isKindOfClass:[NSNumber class]]) {
            return [v integerValue];
        }
    } @catch (NSException *e) {
        // 忽略：返回 0
    }
    return 0;
}

// 原实现指针
static NSNumber *(*orig_numberOfSteps)(id, SEL);

// 替换实现：真实 + 虚拟
static NSNumber *hook_numberOfSteps(id self, SEL _cmd) {
    NSNumber *real = orig_numberOfSteps ? orig_numberOfSteps(self, _cmd) : @0;
    double base = real ? [real doubleValue] : 0.0;
    NSInteger virt = StepFakerVirtualSteps();
    if (virt > 0) {
        return @(base + (double)virt);
    }
    return real;
}

__attribute__((constructor))
static void StepFakerInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"CMPedometerData");
        if (!cls) return;
        Method m = class_getInstanceMethod(cls, @selector(numberOfSteps));
        if (!m) return;
        orig_numberOfSteps = (NSNumber *(*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_numberOfSteps);
        NSLog(@"[StepFaker] hooked CMPedometerData.numberOfSteps");
    }
}
