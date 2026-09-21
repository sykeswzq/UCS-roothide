#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UCS deb 交付前校验脚本（本地 Windows，无需 dpkg）
校验项：control / postinst / App Mach-O(cffaedfe) / dylib Mach-O + install_name / StepFaker.plist filter / 文件齐全
"""
import io, os, sys, tarfile, plistlib, struct, gzip

DEB = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Administrator\Desktop\UCS-roothide\com.sykes.ucs_1.0.3_iphoneos-arm64e.deb"
ok = True
def check(name, cond, detail=""):
    global ok
    status = "OK " if cond else "FAIL"
    if not cond: ok = False
    print(f"[{status}] {name} {detail}")

# ---- 1. 解析 ar 归档，取出 control.tar.gz / data.tar.gz ----
with open(DEB, "rb") as f:
    raw = f.read()

assert raw[:8] == b"!<arch>\n", "not an ar archive"
members = {}
off = 8
while off + 60 <= len(raw):
    hdr = raw[off:off+60]
    name = hdr[0:16].decode("ascii").strip()
    size = int(hdr[48:58].decode("ascii").strip())
    data = raw[off+60:off+60+size]
    # GNU 扩展名格式 (ar 长名) 处理
    if name.startswith("#1/"):
        namelen = int(name[3:])
        name = data[:namelen].decode("utf-8", "replace").rstrip("\x00")
        data = data[namelen:]
    members[name] = data
    off += 60 + size + (1 if size % 2 else 0)  # ar 偶数对齐：奇数长度补 1 字节

print("ar members:", list(members.keys()))
check("ar contains control.tar.gz", "control.tar.gz" in members)
check("ar contains data.tar.gz", "data.tar.gz" in members)

# ---- 2. control.tar.gz ----
ctl = tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz")
ctl_files = {m.name: ctl.extractfile(m).read() if m.isfile() else b"" for m in ctl.getmembers()}
ctl.close()
print("control files:", list(ctl_files.keys()))
check("control has DEBIAN/control", any(k.rstrip("/").endswith("/control") or k == "./control" or k == "control" for k in ctl_files))
cname = next(k for k in ctl_files if k.endswith("/control") or k == "control")
control_text = ctl_files[cname].decode("utf-8")
print("----- control -----")
print(control_text)
check("control Package=com.sykes.ucs", "Package: com.sykes.ucs" in control_text)
check("control Version=1.0.3", "Version: 1.0.3" in control_text)
check("control Architecture=iphoneos-arm64e", "Architecture: iphoneos-arm64e" in control_text)
check("control Depends firmware>=15.0", "firmware (>= 15.0)" in control_text)
check("control has postinst", any("postinst" in k for k in ctl_files))
# postinst 权限
postinst_member = [m for m in ctl.getmembers() if m.name.endswith("postinst")] if False else None

# 从 tar 里再拿 postinst 权限
with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz") as t2:
    for m in t2.getmembers():
        if m.name.endswith("postinst"):
            mode = m.mode & 0o777
            check("postinst executable (mode=%o)" % mode, mode & 0o111 != 0)
            print("postinst mode:", oct(m.mode))

# ---- 3. data.tar.gz ----
data_tar = tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz")
data_files = {}
for m in data_tar.getmembers():
    if m.isfile():
        data_files[m.name] = data_tar.extractfile(m).read()
data_tar.close()
print("data files:", list(data_files.keys()))

check("App binary exists", any(k.endswith("/Applications/UCS.app/UCS") for k in data_files))
check("StepFaker.dylib exists", any(k.endswith("/Library/MobileSubstrate/DynamicLibraries/StepFaker.dylib") for k in data_files))
check("StepFaker.plist exists", any(k.endswith("/Library/MobileSubstrate/DynamicLibraries/StepFaker.plist") for k in data_files))

app_path = next(k for k in data_files if k.endswith("/Applications/UCS.app/UCS"))
dylib_path = next(k for k in data_files if k.endswith("StepFaker.dylib"))
plist_path = next(k for k in data_files if k.endswith("StepFaker.plist"))
app = data_files[app_path]
dylib = data_files[dylib_path]

# ---- 4. Mach-O magic ----
def macho_magic(b):
    if len(b) < 4: return "TOO_SHORT"
    # 文件头字节序：小端 MH_MAGIC_64 = cf fa ed fe（单 arm64e）；cafe babe = FAT
    if b[:4] == b"\xcf\xfa\xed\xfe": return "cffaedfe (single arm64e)"
    if b[:4] == b"\xfe\xed\xfa\xcf": return "feedfacf (MH_MAGIC_64 BE)"
    if b[:4] == b"\xca\xfe\xba\xbe" or b[:4] == b"\xbe\xba\xfe\xca": return "cafebabe (FAT)"
    return "unknown " + b[:4].hex()

am = macho_magic(app)
dm = macho_magic(dylib)
check(f"App Mach-O magic={am}", am == "cffaedfe (single arm64e)", "(must be single arm64e cffaedfe, NOT FAT)")
check(f"dylib Mach-O magic={dm}", dm == "cffaedfe (single arm64e)")

# ---- 5. arm64e 子类型检查 (cputype=0x0100000c arm64, cpusubtype=2 arm64e, 高位 capability 位需掩码) ----
def is_arm64e(b):
    if len(b) < 20: return False
    cputype, cpusubtype = struct.unpack("<II", b[4:12])
    return cputype == 0x0100000C and (cpusubtype & 0x00FFFFFF) == 2
check("App is arm64e", is_arm64e(app))
check("dylib is arm64e", is_arm64e(dylib))

# ---- 6. dylib install_name (LC_ID_DYLIB, cmd=0xD) ----
def read_install_name(b):
    if len(b) < 32: return None
    ncmds, = struct.unpack("<I", b[16:20])
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(b): break
        cmd, cmdsize = struct.unpack("<II", b[off:off+8])
        if cmd == 0xD and off + cmdsize <= len(b):
            name_off = struct.unpack("<I", b[off+8:off+12])[0]
            end = b.find(b"\x00", off + name_off)
            return b[off+name_off:end].decode("utf-8", "replace")
        off += cmdsize
    return None

iname = read_install_name(dylib)
check(f"dylib install_name={iname}", bool(iname), "(verified present)")

# ---- 7. StepFaker.plist filter ----
pl = plistlib.loads(data_files[plist_path])
bundles = pl.get("Filter", {}).get("Bundles", [])
check(f"Filter.Bundles={bundles}", "com.tencent.xin" in bundles, "(only WeChat)")
check("no wildcard in filter", "*" not in str(pl))

print("=" * 60)
print("RESULT:", "ALL CHECKS PASSED" if ok else "FAILED")
sys.exit(0 if ok else 1)
