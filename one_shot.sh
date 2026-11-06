#!/bin/bash
# =============================================================================
# odin 一步到位内核重建脚本 v1.1  (2026-10-03 沉淀版)
# 输入: 原厂 boot_a 镜像 (如 boot_a_ORIGINAL.img)
# 输出: /root/pack/boot_a_ONE_SHOT.img
#   内容: FTS空FIFO退避 + EROFS-PSI泄漏修复 + original.config基线 + KSU root
# 用法: /root/one_shot.sh /path/to/boot_a_ORIGINAL.img
#   可选: DRY=1 跳过配置/构建直接用树内现有 Image 测打包
#         RAMDISK_SRC=<含ksud的boot>  OUT_IMG=<输出路径>
# 依赖: /root/kernel3 (已应用 FTS-v2/EROFS-PSI/KSU), /root/toolchain/clang-r383902b1,
#       /root/kernel3/original.config (手机 /proc/config.gz 导出)
# =============================================================================
set -o pipefail

TREE=/root/kernel3
TOOLCHAIN=/root/toolchain/clang-r383902b1
PACK=/root/pack
RAMDISK_SRC=${RAMDISK_SRC:-$PACK/newboot_k3suki7.img}   # root 环境 (ksud 4.2.0) 来源
OUT_IMG=${OUT_IMG:-$PACK/boot_a_ONE_SHOT.img}

die(){ echo "[FATAL] $*" >&2; exit 1; }
log(){ echo "[ONE-SHOT] $*"; }

SRC_BOOT="$1"
[ -z "$SRC_BOOT" ] && die "用法: $0 <原厂boot镜像>  (DRY=1 RAMDISK_SRC=xx OUT_IMG=xx 可选)"
[ -f "$SRC_BOOT" ] || die "找不到 $SRC_BOOT"

# ---------- [1] 环境自检 ----------
log "[1/6] 环境自检"
[ -d "$TREE" ] || die "源码树 $TREE 不存在"
[ -x "$TOOLCHAIN/bin/clang" ] || die "工具链 $TOOLCHAIN 不存在"
[ -f "$TREE/original.config" ] || die "original.config 缺失 (需手机 /proc/config.gz 导出)"
[ -f "$RAMDISK_SRC" ] || die "ramdisk 来源 $RAMDISK_SRC 缺失 (需含 ksud 4.2.0 的 boot)"
"$TOOLCHAIN/bin/clang" --version | grep -q "clang version 11" || die "clang 版本非 11.x"

grep -q memstall_accounted "$TREE/fs/erofs/zdata.c" \
  || die "EROFS PSI 泄漏修复不在树内 (见 erofs_psi_leak_fix.patch)"
grep -q FTS_EMPTY_IRQ_STREAK_START "$TREE/drivers/input/touchscreen/fts_spi/fts.c" \
  || die "FTS 退避补丁不在树内 (见 fts_empty_irq_backoff_v2.patch)"
[ -f "$TREE/drivers/kernelsu/Kconfig" ] || die "KSU 未集成"
log "  树/工具链/三大补丁 全部就绪"

# ---------- [2] 解析原厂 boot (v3 header) ----------
log "[2/6] 解析原厂 boot"
BOOT_INFO=$(python3 - "$SRC_BOOT" <<'PYEOF'
import struct, sys, os
f = sys.argv[1]
d = open(f, "rb").read(2112)
assert d[0:8] == b"ANDROID!", "not an ANDROID boot image"
ks, rs, osv, hs = struct.unpack_from("<IIII", d, 8)
hv = struct.unpack_from("<I", d, 40)[0]
assert hv == 3, "header_version=%d not v3" % hv
print(ks, rs, hv, os.path.getsize(f))
PYEOF
) || die "boot 解析失败"
ORIG_KS=$(echo "$BOOT_INFO" | awk '{print $1}')
ORIG_RS=$(echo "$BOOT_INFO" | awk '{print $2}')
PART_SIZE=$(echo "$BOOT_INFO" | awk '{print $4}')
[ -n "$ORIG_KS" ] || die "boot 解析失败"
log "  原厂 kernel=$ORIG_KS ramdisk=$ORIG_RS 分区=$PART_SIZE"

# ---------- [3] 配置 ----------
if [ "${DRY:-0}" = "1" ]; then
  log "[3/6] DRY 模式: 跳过配置, 使用树内现有 out/.config"
else
  log "[3/6] 配置 (original.config -> olddefconfig -> 对齐)"
  cp "$TREE/out/.config" "$TREE/config_prev_backup.config" 2>/dev/null
  cp "$TREE/original.config" "$TREE/out/.config"
  build_make(){ PATH="$TOOLCHAIN/bin:$PATH" make O="$TREE/out" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- "$@"; }
  build_make olddefconfig > /dev/null 2>&1 || die "olddefconfig 失败"

  # 对齐: KSU_SUSFS 全关(与现役 root 链路一致) + zRAM 默认 lz4kd(树无 lz4p 的最近替代)
  sed -i -e 's/^CONFIG_KSU_SUSFS=y/# CONFIG_KSU_SUSFS is not set/' \
         -e 's/^\(CONFIG_KSU_SUSFS_[A-Z_]*\)=y/# \1 is not set/' \
         -e 's/^CONFIG_ZRAM_DEF_COMP_LZORLE=y/# CONFIG_ZRAM_DEF_COMP_LZORLE is not set/' \
         -e 's/^CONFIG_ZRAM_DEF_COMP="lzo-rle"/CONFIG_ZRAM_DEF_COMP="lz4kd"/' "$TREE/out/.config"
  sed -i 's/^# CONFIG_ZRAM_DEF_COMP_LZ4KD is not set/CONFIG_ZRAM_DEF_COMP_LZ4KD=y/' "$TREE/out/.config"
  build_make olddefconfig > /dev/null 2>&1

  # 12 类关键项核对 (任一失败即停)
  for k in CONFIG_LTO=y CONFIG_THINLTO=y CONFIG_CFI_CLANG=y CONFIG_SHADOW_CALL_STACK=y \
           CONFIG_MEMCG=y CONFIG_PSI=y CONFIG_MIHW=y CONFIG_FEAS=y CONFIG_MILLET=y \
           CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y CONFIG_KSU=y CONFIG_ZRAM=y; do
    grep -q "^$k\$" "$TREE/out/.config" || die "关键项缺失: $k"
  done
  grep -q '^CONFIG_LTO_NONE' "$TREE/out/.config" && die "LTO_NONE 仍开启"
  grep -q '^# CONFIG_KSU_SUSFS is not set' "$TREE/out/.config" || die "KSU_SUSFS 未对齐关闭"
  log "  12 类关键项核对通过"
fi

# ---------- [4] 构建 ----------
if [ "${DRY:-0}" = "1" ]; then
  log "[4/6] DRY 模式: 跳过构建, 使用树内现有 Image"
else
  log "[4/6] 构建 Image (增量约 20min, 全量约 50min)"
  build_make(){ PATH="$TOOLCHAIN/bin:$PATH" make O="$TREE/out" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- "$@"; }
  build_make -j14 Image > /root/one_shot_build.log 2>&1 \
    || { tail -20 /root/one_shot_build.log; die "构建失败, 详见 /root/one_shot_build.log"; }
fi
KERNEL_IMG="$TREE/out/arch/arm64/boot/Image"
[ -s "$KERNEL_IMG" ] || die "Image 未生成"
log "  Image $(stat -c %s "$KERNEL_IMG") 字节"

# ---------- [5] 打包 ----------
log "[5/6] 打包 (原boot header + 新kernel + ksud ramdisk + 补零)"
python3 - "$SRC_BOOT" "$RAMDISK_SRC" "$KERNEL_IMG" "$OUT_IMG" "$PART_SIZE" <<'PYEOF' || die "打包失败"
import struct, sys
def align(x, pg=4096):
    return (x + pg - 1) // pg * pg
src_boot, ram_src, kimg, out, part_s = sys.argv[1:6]
PG = 4096
PART = int(part_s)
d0 = open(src_boot, "rb").read(2112)
ks0 = struct.unpack_from("<I", d0, 8)[0]
hdr = bytearray(open(src_boot, "rb").read(PG))
img = open(kimg, "rb").read()
rs = open(ram_src, "rb").read(2112)
ksr, rsr = struct.unpack_from("<II", rs, 8)
fh = open(ram_src, "rb")
fh.seek(align(PG + ksr))
ramdisk = fh.read(rsr)
fh.close()
assert ramdisk[0:2] == b"\x1f\x8b", "ramdisk gzip magic 异常"
assert len(img) <= ks0 + 16 * 1024 * 1024, "kernel 超原厂槽位 16MB 以上, 人工确认分区容量"
struct.pack_into("<I", hdr, 8, len(img))
struct.pack_into("<I", hdr, 12, rsr)   # 坑: 换 ramdisk 必须同步 ramdisk_size@12, 否则 boot 解析错位
o = bytearray(hdr)
o += img
o += b"\x00" * (align(PG + len(img)) - PG - len(img))
o += ramdisk
o += b"\x00" * (PART - len(o))
assert len(o) == PART
open(out, "wb").write(o)
v = open(out, "rb").read()
kh = v[:PG]
ks, rs2 = struct.unpack_from("<II", kh, 8)
vk = v[PG:PG + ks]
vr = v[align(PG + ks):align(PG + ks) + rs2]
assert vk == img, "kernel 逐字节验证失败"
assert vr == ramdisk, "ramdisk 逐字节验证失败"
assert rs2 == rsr, "header ramdisk_size 未同步"
assert struct.unpack_from("<I", kh, 40)[0] == 3
print("  kernel=%d ramdisk=%d 总大小=%d 逐字节验证 OK" % (ks, rs2, len(o)))
PYEOF

# ---------- [6] 报告 ----------
SHA=$(sha256sum "$OUT_IMG" | cut -d' ' -f1)
log "[6/6] 完成"
log "产物:   $OUT_IMG"
log "SHA256: $SHA"
log "刷入:   adb reboot bootloader && fastboot flash boot_a <镜像>"
log "回滚:   fastboot flash boot_a $SRC_BOOT"
log "刷后验证: su -c id | cat /proc/pressure/memory (some/full<5%) | comp_algorithm=[lz4kd]"
