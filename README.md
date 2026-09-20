# UCS — iOS 越狱 (roothide) 运动数据生成工具

单个 DEB 安装即用：手动/定时自动生成健康（HealthKit）与微信运动步数，微信排行榜实时同步虚拟步数。

## 功能

- **手动生成**：一键生成虚拟步数、步行距离、爬楼层数，同时写入苹果健康与微信运动；支持自定义数值；自动去重避免与真实步数重叠
- **定时自动生成**：App 内设定每日定时时间，锁屏 + 划掉 App 后到点后台自动触发生成，支持跨天自动重置
- **微信步数同步**：内置 StepFaker 注入模块 hook 微信计步接口，生成后自动重启微信触发服务器同步
- **自动适配**：自动识别 roothide jbroot 路径变化

## 运行环境

- iOS 15+（已验证 iOS 16.5）
- roothide (Dopamine) 越狱
- arm64e 架构
- 微信 8.0.x

## 技术架构（单 DEB 集成）

```
UCS.app                            App 本体（UI + 手动生成 + HealthKit 写入）
Library/MobileSubstrate/
  DynamicLibraries/
    StepFaker.dylib                微信注入模块（注入 com.tencent.xin）
    StepFaker.plist                Filter: Bundles = (com.tencent.xin)
/var/mobile/Library/LaunchAgents/
  com.sykes.ucs.schedule.plist     定时 LaunchAgent（mobile 用户域，60s 轮询）
```

## 构建

GitHub Actions (macos-latest) 每次 push 到 `main` 自动构建并校验，产物为：
`com.sykes.ucs_<版本>_iphoneos-arm64e.deb`

本地为 Windows 无法交叉编译，全部构建在 CI 完成。

## 安装

1. 下载 `.deb`
2. Sileo/Zebra 安装（需 roothide 越狱环境）
3. 打开 UCS，首次授权健康权限
4. 输入虚拟步数，点「生成运动数据」；或开启「每日定时自动生成」并设定时间

## 说明

- 显示步数 = 真实步数 + 虚拟步数（虚拟步数以独立合成样本写入，可删除替换）
- 完整日志：`/var/mobile/Documents/ucs.log`、`/var/mobile/Documents/ucs_launchd.log`
- License: MIT
