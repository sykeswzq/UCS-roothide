#!/bin/bash
# build.sh - UCS roothide 单 DEB 构建脚本（全新实现）
# 约定（roothide 官方）：
#   1) App 放相对路径 ./Applications/UCS.app -> 安装到 /var/roothide/Applications/UCS.app
#   2) 注入库放 ./Library/MobileSubstrate/DynamicLibraries/
#   3) ldid -M -S<entitlements> 签名
#   4) 单 arm64e 架构（arm64+arm64e 双 slice 会导致不注入，勿改）
set -eu

VER=1.0.2
PKG=com.sykes.ucs
OUT="${PKG}_${VER}_iphoneos-arm64e.deb"
BIN=UCS

echo "=============================================="
echo "UCS build v${VER} -> ${OUT}"
echo "=============================================="

rm -rf staging tweak_staging
mkdir -p staging/Applications/UCS.app
mkdir -p staging/Library/MobileSubstrate/DynamicLibraries
mkdir -p staging/DEBIAN
mkdir -p tweak_staging/Library/MobileSubstrate/DynamicLibraries

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "[1/5] Compile App (arm64e only)"
xcrun --sdk iphoneos clang \
  -framework UIKit \
  -framework Foundation \
  -framework HealthKit \
  -framework Security \
  -framework UserNotifications \
  -fobjc-arc \
  -arch arm64e \
  -mios-version-min=15.0 \
  -isysroot "$SDK" \
  -o staging/Applications/UCS.app/${BIN} \
  HealthBoostApp/HealthBoostApp.m
chmod 755 staging/Applications/UCS.app/${BIN}
echo "  app binary: $(wc -c < staging/Applications/UCS.app/${BIN}) bytes"

echo "[2/5] Copy resources + sign App"
cp HealthBoostApp/Info.plist          staging/Applications/UCS.app/
cp HealthBoostApp/AppIcon60x60@2x.png staging/Applications/UCS.app/
cp HealthBoostApp/PkgInfo             staging/Applications/UCS.app/
chmod 644 staging/Applications/UCS.app/Info.plist
chmod 644 staging/Applications/UCS.app/AppIcon60x60@2x.png
chmod 644 staging/Applications/UCS.app/PkgInfo

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid not installed"; exit 1
fi
ldid -M -SHealthBoost.entitlements.plist staging/Applications/UCS.app/${BIN}
# 校验签名包含 healthkit + no-sandbox
ldid -e staging/Applications/UCS.app/${BIN} 2>/dev/null | grep -q "healthkit" || { echo "ERROR: missing healthkit entitlement"; exit 1; }
ldid -e staging/Applications/UCS.app/${BIN} 2>/dev/null | grep -q "no-sandbox" || { echo "ERROR: missing no-sandbox entitlement"; exit 1; }
# 校验 Mach-O magic：单 arm64e 小端 = cffaedfe（cafebabe 是 FAT，本工程禁止）
magic=$(xxd -p -l4 staging/Applications/UCS.app/${BIN} 2>/dev/null | tr -d '\n')
if [ "$magic" != "cffaedfe" ]; then
  echo "ERROR: App Mach-O magic=$magic (expected cffaedfe single arm64e)"
  exit 1
fi
echo "  app signed OK (magic=$magic)"

echo "[3/5] Compile StepFaker tweak (arm64e only)"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -framework Foundation \
  -framework CoreFoundation \
  -framework CoreMotion \
  -framework HealthKit \
  -arch arm64e \
  -mios-version-min=15.0 \
  -isysroot "$SDK" \
  -o tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib \
  tweak/StepFaker.m
chmod 755 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib

cp tweak/StepFaker.plist tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 644 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

ldid -M -S tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null | tr -d '\n')
if [ "$smagic" != "cffaedfe" ]; then
  echo "ERROR: StepFaker Mach-O magic=$smagic (expected cffaedfe single arm64e)"
  exit 1
fi
echo "  tweak signed OK (magic=$smagic, $(wc -c < tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes)"

echo "[4/5] Merge tweak + control + postinst"
cp -R tweak_staging/Library staging/

cat > staging/DEBIAN/control << EOF
Package: ${PKG}
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 2048
Depends: firmware (>= 15.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: UCS 运动数据生成工具：手动/定时自动生成健康与微信步数，单 DEB 安装即用
Section: Utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'POSTINST_EOF'
#!/bin/sh
LOG=/var/mobile/Documents/ucs_install.log
mkdir -p /var/mobile/Documents
chmod 777 /var/mobile/Documents
echo "=== postinst $(date) ===" > "$LOG"

# 默认配置（XML plist，供 launchd 脚本 plutil 读取；App 首次打开会覆盖）
CFG=/var/mobile/Documents/ucs_config.plist
if [ ! -f "$CFG" ]; then
  cat > "$CFG" << 'CFGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>virtualSteps</key><integer>5200</integer>
	<key>walkDistance</key><integer>0</integer>
	<key>flights</key><integer>0</integer>
	<key>scheduleEnabled</key><false/>
	<key>scheduleTime</key><string>09:00</string>
</dict>
</plist>
CFGEOF
  chmod 666 "$CFG"
fi
echo "config ready" >> "$LOG"

# 定时轮询脚本（mobile 用户共享目录，uid 必须是 501）
SCRIPT=/var/mobile/Documents/ucs_schedule.sh
cat > "$SCRIPT" << 'SCREOF'
#!/bin/sh
LOG=/var/mobile/Documents/ucs_launchd.log
echo "tick $(date) uid=$(id -u)" >> "$LOG"
# 配置双路读取：App（mobile 沙盒）实际写入的物理位置是 /rootfs/private/var/mobile/Documents/，
# postinst 默认写 /var/mobile/Documents/；两个视图 inode 不同，必须都尝试
CFG=""
for c in /rootfs/private/var/mobile/Documents/ucs_config.plist /var/mobile/Documents/ucs_config.plist; do
  if [ -f "$c" ]; then CFG="$c"; break; fi
done
[ -n "$CFG" ] || { echo "config missing" >> "$LOG"; exit 0; }
echo "using cfg=$CFG" >> "$LOG"
# v1.0.2：iOS /usr/bin/plutil 不支持 -extract（实测 rc=255 / 报错），脚本里读配置恒为空导致到点不触发。
# 改为 sed 直接解析 XML plist（兼容 App 落盘的换行缩进格式，先压成单行再提取）。
FLAT=$(tr -d '\n' < "$CFG")
ENABLED=$(echo "$FLAT" | sed -n 's:.*<key>scheduleEnabled</key>[[:space:]]*<\(true\|false\)/>.*:\1:p' | head -1)
echo "scheduleEnabled=$ENABLED" >> "$LOG"
[ "$ENABLED" = "true" ] || exit 0
NT=$(echo "$FLAT" | sed -n 's:.*<key>scheduleTime</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p' | head -1)
[ -n "$NT" ] || exit 0
NOWH=$(date +%H); NOWM=$(date +%M); N=$((10#$NOWH*60+10#$NOWM))
SH=$(echo "$NT" | cut -d: -f1); SM=$(echo "$NT" | cut -d: -f2)
S=$((10#$SH*60+10#$SM))
echo "now=$N sched=$S" >> "$LOG"
[ "$N" -lt "$S" ] && exit 0
# 今天已生成则跳过（双路读取 lastgen）
TODAY=$(date +%Y-%m-%d)
LAST=$(cat /rootfs/private/var/mobile/Documents/ucs_lastgen.txt 2>/dev/null)
[ -z "$LAST" ] && LAST=$(cat /var/mobile/Documents/ucs_lastgen.txt 2>/dev/null)
echo "lastgen=$LAST today=$TODAY" >> "$LOG"
[ "$LAST" = "$TODAY" ] && exit 0
# 到点：touch marker（双路：App 沙盒视图 + 真实视图）+ uiopen 拉起 App 自动生成
touch /rootfs/private/var/mobile/Documents/ucs_wake.marker 2>/dev/null
touch /var/mobile/Documents/ucs_wake.marker
chmod 666 /rootfs/private/var/mobile/Documents/ucs_wake.marker 2>/dev/null
chmod 666 /var/mobile/Documents/ucs_wake.marker
echo "wake $(date) now=$N sched=$S" >> "$LOG"
/var/jb/usr/bin/uiopen ucs://generate >> "$LOG" 2>&1 || /usr/bin/uiopen ucs://generate >> "$LOG" 2>&1 || true
SCREOF
chmod 755 "$SCRIPT"
chown mobile:mobile "$SCRIPT" 2>/dev/null || true
echo "script written: $(wc -l < "$SCRIPT") lines" >> "$LOG"

# LaunchAgent：双写 /var/mobile/Library/LaunchAgents/（root 视图，launchd 读）
# 与 /rootfs/private/var/mobile/Library/LaunchAgents/（App 沙盒视图，App 兜底检查）
mkdir -p /var/mobile/Library/LaunchAgents
PLIST=/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist
cat > "$PLIST" << 'PLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.sykes.ucs.schedule</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>/var/mobile/Documents/ucs_schedule.sh</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/var/mobile/Documents/ucs_launchd.log</string>
	<key>StandardErrorPath</key>
	<string>/var/mobile/Documents/ucs_launchd_err.log</string>
</dict>
</plist>
PLEOF
chmod 644 "$PLIST"
chown mobile:mobile "$PLIST" 2>/dev/null || true
# 同步到 App 沙盒视图（postinst 以 root 运行可写）
mkdir -p /rootfs/private/var/mobile/Library/LaunchAgents 2>/dev/null || true
cp "$PLIST" /rootfs/private/var/mobile/Library/LaunchAgents/ 2>/dev/null || true
chmod 644 /rootfs/private/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true
chown mobile:mobile /rootfs/private/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist 2>/dev/null || true

# 注册（roothide 域：user/foreground；必须以 mobile uid=501 运行，root 的 uiopen 拉起不了 App）
# 修复：去掉 su mobile（依赖密码）+ root fallback（uid=0），改用 asuser 501 直接以 mobile 身份 bootstrap
# 两个视图路径都尝试：mobile 上下文可能只能读到 rootfs 视图（App 沙盒物理落盘位置）
launchctl bootout user/foreground/com.sykes.ucs.schedule >> "$LOG" 2>&1 || true
launchctl asuser 501 launchctl bootout user/foreground/com.sykes.ucs.schedule >> "$LOG" 2>&1 || true
P1=/rootfs/private/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist
P2=/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist
launchctl asuser 501 launchctl bootstrap user/foreground "$P1" >> "$LOG" 2>&1 || \
launchctl asuser 501 launchctl bootstrap user/foreground "$P2" >> "$LOG" 2>&1 || true
echo "launchd bootstrap (asuser 501) rc=$?" >> "$LOG"

# 刷新图标缓存
if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -a >> "$LOG" 2>&1 || true
  /var/jb/usr/bin/uicache -p /Applications/UCS.app >> "$LOG" 2>&1 || true
elif [ -x /usr/bin/uicache ]; then
  /usr/bin/uicache -a >> "$LOG" 2>&1 || true
  /usr/bin/uicache -p /Applications/UCS.app >> "$LOG" 2>&1 || true
fi

# 强制杀微信使注入生效
for k in /var/jb/usr/bin/killall /usr/bin/killall killall; do
  if [ -x "$k" ]; then "$k" -9 WeChat >> "$LOG" 2>&1 || true; break; fi
done
echo "=== postinst done ===" >> "$LOG"
exit 0
POSTINST_EOF
chmod 755 staging/DEBIAN/postinst

echo "[5/5] dpkg-deb"
dpkg-deb -b -Zgzip staging "$OUT"
echo "DONE: $(ls -lh "$OUT" | awk '{print $5}') -> $OUT"
