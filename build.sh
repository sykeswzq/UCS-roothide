#!/bin/bash
# build.sh - UCS roothide 单 DEB 构建脚本（全新实现）
# 约定（roothide 官方）：
#   1) App 放相对路径 ./Applications/UCS.app -> 安装到 /var/roothide/Applications/UCS.app
#   2) 注入库放 ./Library/MobileSubstrate/DynamicLibraries/
#   3) App 用 ldid -S<entitlements>；tweak 用 ldid -S（无 -M，对齐 v4.4.25 可注入配置）
#   4) App 单 arm64e；StepFaker 必须 fat(arm64+arm64e)，微信主进程是 arm64 才会选 arm64 slice 加载
set -eu

VER=2.1.1
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

echo "[3/5] Compile StepFaker tweak (fat arm64 + arm64e)"
# v1.0.12：微信主进程是 arm64（实测 WeChatTweak 纯 arm64 能注入、纯 arm64e 不注入）。
# 必须含 arm64 slice 才能被微信 dyld 加载；arm64e slice 兜底。对齐原版 v4.4.25。
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc \
  -framework Foundation \
  -framework CoreFoundation \
  -framework CoreMotion \
  -framework HealthKit \
  -arch arm64 -arch arm64e \
  -mios-version-min=13.0 \
  -isysroot "$SDK" \
  -o tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib \
  tweak/StepFaker.m
chmod 755 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib

cp tweak/StepFaker.plist tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist
chmod 644 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist

# v1.0.13：tweak 签名用 ldid -S（无 -M），对齐 v4.4.25 金标准。
# 之前 v1.0.12 用 ldid -M -S 签 fat，dyld 拒载、微信进程无任何注入日志；实测去掉 -M 后注入正常。
ldid -S tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib
smagic=$(xxd -p -l4 tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null | tr -d '\n')
# cafebabe=FAT(arm64+arm64e，预期)；cffaedfe=单 arm64e（不满足微信 arm64 注入，这里仅放行但下面校验 fat）
if [ "$smagic" != "cafebabe" ] && [ "$smagic" != "cffaedfe" ]; then
  echo "ERROR: StepFaker Mach-O magic=$smagic (expected cafebabe FAT)"
  exit 1
fi
if [ "$smagic" != "cafebabe" ]; then
  echo "ERROR: StepFaker is single-slice $smagic, must be FAT arm64+arm64e to inject WeChat(arm64)"
  exit 1
fi
echo "  tweak signed OK (magic=$smagic FAT arm64+arm64e, $(wc -c < tweak_staging/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib) bytes)"

echo "[4/5] Merge tweak + control + postinst"
cp -R tweak_staging/Library staging/

# v2.0.0: copy StepCount.dylib (Alipay step sim)
cp tweak/StepCount.dylib staging/Library/MobileSubstrate/DynamicLibraries/
cp tweak/StepCount.plist staging/Library/MobileSubstrate/DynamicLibraries/
chmod 755 staging/Library/MobileSubstrate/DynamicLibraries/StepCount.dylib
chmod 644 staging/Library/MobileSubstrate/DynamicLibraries/StepCount.plist
# v2.0.0: do NOT ldid -S StepCount.dylib, it breaks injection (original deb works without signing)
echo "  StepCount.dylib: $(wc -c < staging/Library/MobileSubstrate/DynamicLibraries/StepCount.dylib) bytes"

cat > staging/DEBIAN/control << EOF
Package: ${PKG}
Name: UCS
Version: ${VER}
Architecture: iphoneos-arm64e
Installed-Size: 2048
Depends: firmware (>= 15.0)
Maintainer: sykeswzq
Author: sykeswzq
Description: 手动 / 定时自动生成健康、微信、支付宝步数，支持 roothide
Section: Utilities
Priority: optional
EOF

cat > staging/DEBIAN/postinst << 'POSTINST_EOF'
#!/bin/sh
LOG=/var/mobile/Documents/ucs_install.log
mkdir -p /var/mobile/Documents
chmod 777 /var/mobile/Documents
echo "=== postinst $(date) ===" > "$LOG"

# v1.0.11：StepFaker dylib/plist 权限对齐其他 tweak（root:wheel），确保 MobileSubstrate 加载
chown root:wheel /var/jb/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || true
chown root:wheel /var/jb/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist 2>/dev/null || true
chown root:wheel /var/jb/Library/MobileSubstrate/DynamicLibraries/StepCount.dylib 2>/dev/null || true
chown root:wheel /var/jb/Library/MobileSubstrate/DynamicLibraries/StepCount.plist 2>/dev/null || true
chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib 2>/dev/null || true
chmod 644 /var/jb/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist 2>/dev/null || true

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

# 定时脚本（v2.1.0: StartInterval=60 轮询，单次执行后退出）
SCRIPT=/var/mobile/Documents/ucs_schedule.sh
cat > "$SCRIPT" << 'SCREOF'
#!/bin/sh
# v2.1.0: StartInterval=60 轮询模式。脚本每次运行检查一次，然后 sleep 10s 再退出。
# 避免常驻循环在锁屏太久后被系统挂起。sleep 10s 绕开 launchd ThrottleInterval 惩罚。
LOG=/var/mobile/Documents/ucs_launchd.log
echo "=== ucs_schedule tick pid=$$ uid=$(id -u) $(date) ===" >> "$LOG"

# v2.0.0: check alipay steps file
ALIPAY_FILE=""
for f in /rootfs/private/var/mobile/Documents/ucs_alipay_steps.txt /var/mobile/Documents/ucs_alipay_steps.txt; do
  [ -f "$f" ] && ALIPAY_FILE="$f" && break
done
if [ -f "$ALIPAY_FILE" ]; then
  STEPS=$(cat "$ALIPAY_FILE")
  rm -f "$ALIPAY_FILE"
  for p in /var/mobile/Containers/Data/Application/*/Library/Preferences/com.alipay.iphoneclient.plist; do
    [ -f "$p" ] || continue
    plutil -key ssm_step_sim_max -value $STEPS -type int "$p" >> "$LOG" 2>&1
    plutil -key ssm_step_sim_min -value $STEPS -type int "$p" >> "$LOG" 2>&1
    plutil -key ssm_step_sim_enabled -value YES -type bool "$p" >> "$LOG" 2>&1
    plutil -key ssm_enabled -value YES -type bool "$p" >> "$LOG" 2>&1
    plutil -key ssm_enableStepSim -value YES -type bool "$p" >> "$LOG" 2>&1
    plutil -key ssm_step_sim_mode -value 0 -type int "$p" >> "$LOG" 2>&1
    echo "alipay written: $p steps=$STEPS" >> "$LOG"
  done
  killall -9 cfprefsd >> "$LOG" 2>&1
  killall -9 AlipayWallet >> "$LOG" 2>&1
fi

# 配置双路读取
CFG=""
for c in /rootfs/private/var/mobile/Documents/ucs_config.plist /var/mobile/Documents/ucs_config.plist; do
  if [ -f "$c" ]; then CFG="$c"; break; fi
done
if [ -n "$CFG" ]; then
  FLAT=$(tr -d '\n' < "$CFG")
  ENABLED=$(echo "$FLAT" | sed -n 's:.*<key>scheduleEnabled</key>[[:space:]]*<\(true\|false\)/>.*:\1:p' | head -1)
  if [ "$ENABLED" = "true" ]; then
    NT=$(echo "$FLAT" | sed -n 's:.*<key>scheduleTime</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p' | head -1)
    if [ -n "$NT" ]; then
      NOWH=$(date +%-H); NOWM=$(date +%-M); N=$((NOWH*60+NOWM))
      SH=$(echo "$NT" | cut -d: -f1 | sed 's/^0//'); SM=$(echo "$NT" | cut -d: -f2 | sed 's/^0//')
      S=$((SH*60+SM))
      if [ "$N" -ge "$S" ]; then
        echo "trigger $(date) now=$N sched=$S" >> "$LOG"
        /usr/bin/su mobile -c "/var/jb/Applications/UCS.app/UCS --cli" >> "$LOG" 2>&1 &
        CLI_PID=$!
        echo "spawned cli pid=$CLI_PID" >> "$LOG"
      fi
    fi
  fi
fi

# sleep 10s then exit, avoid ThrottleInterval penalty
sleep 10
SCREOF
chmod 755 "$SCRIPT"
chown mobile:mobile "$SCRIPT" 2>/dev/null || true
echo "script written: $(wc -l < "$SCRIPT") lines" >> "$LOG"

# v2.1.0: LaunchAgent (user domain), HealthKit works correctly in user context
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

# 注册（roothide 域：user/501）
launchctl bootout user/501/com.sykes.ucs.schedule >> "$LOG" 2>&1 || true
launchctl bootstrap user/501 /var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist >> "$LOG" 2>&1 || true
echo "launchd bootstrap (user/501) rc=$?" >> "$LOG"

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
