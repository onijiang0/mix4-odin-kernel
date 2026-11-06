# Xiaomi MIX 4 (odin) 内核 — onijiang0 机型适配版 B11

> 仅针对本人设备（Xiaomi MIX 4 / odin / SM8350-888+ / HyperOS 1.0.4 / Linux 5.4.281）适配的定制内核源码与构建方案。
> 基线：[MrNya907/xiaomi_kernel_odin](https://github.com/MrNya907/xiaomi_kernel_odin) @ `ada168693`（LA.UM.9.14.r1-26000-LAHAINA.QSSI15.0）

## 内核特性（B11）

| # | 特性 | 说明 |
|---|------|------|
| 1 | **SukiSU-Ultra builtin v4.3.0** | 内置（manual hook）方式集成，IOCTL 新架构，配套官方 SukiSU 管理器 v4.3.0；无 kprobe 开销 |
| 2 | **WALT 调度器开启** | `CONFIG_SCHED_WALT=y`（原厂 defconfig 禁用），窗口负载跟踪 + 触屏加速，UI 提频更快 |
| 3 | **odin_mode 双档电源** | `/sys/kernel/odin_mode/mode`：均衡（GPU 840MHz 解锁 + CPU 满速）/ 省电（1.2/1.6/1.8G + GPU 540），8 个可调参数 |
| 4 | **CPU 温控压频解除** | `thermal_cpu_override`：无视 MIUI thermal-engine 的策略性压频（非热触发，纯省电策略） |
| 5 | **cpu-boost 内核化** | `kernel/sched/walt/cpu-boost.c`：input boost 300ms 三簇默认烧进内核 + 写入钳制（powerkeeper 写 120 自动抬回 300），零脚本依赖 |
| 6 | **seccomp 真过滤移植** | `allow_native` 位图 + `__seccomp_filter` 入口短路 + `/proc/odin_sectest` 自检节点 |
| 7 | **FTS / EROFS / lz4kd** | FTS 触屏空 FIFO 退避、EROFS PSI 修复、zram lz4kd 压缩算法 |
| 8 | DEBUG 后门已移除 | 无 dmesg 提权后门，root 全部走 KSU 正规链路 |

## 实测数据

| 场景 | 结果 |
|------|------|
| 拼多多（压测后） | 13434 帧，Janky 1.27%，p50=5ms / p90=7ms / p95=10ms |
| 抖音刷视频 | 17471 帧，Janky 0.41%，p50=12ms / p90=24ms / p95=31ms |
| 20min 三阶段重压 | 无 panic / 无 OOM / 无子系统崩溃 / 温度 54.5°C 无降频 |

## 仓库结构

```
odin_b11_full.patch   本机内核 vs 基线 ada168693 的完整差异（239 文件，+85488/-7140）
config/original.config   最终内核配置
build_now.sh           内核编译脚本（clang r383902b1, LLVM=1）
one_shot.sh            boot.img 打包脚本（新 Image + 原厂 ramdisk，逐字节验证）
userspace/             配套用户态守护脚本（见下）
```

## 用户态守护（userspace/，放 /data/adb/service.d/）

| 脚本 | 功能（30s 循环维持） |
|------|---------------------|
| `96-odin-override.sh` | 开机解除 MIUI thermal-engine CPU 压频 + 清存量 freq_qos cap |
| `97-priority-guard.sh` | ① GMS 全家钉小核 ② 支付宝 helper 子进程钉小核（主进程豁免）③ SystemUI renice -10 ④ **小米推送风暴压制**：xmsf 三件套从 foreground CPU 组（shares 5120）挪 background（1024）+ nice +10，推送突发上限约前台 1/5 算力，推送本身（网络等待）不受影响 |

> 风暴压制基于内核 CFS 调度机制（cpu.shares 权重 + cpuset + nice），无进程删除、无黑名单，温和可逆。

## 已知良性问题

- `/proc/pressure/*` 正常，但 dmesg 可见 `fs/fuse/file.c:1750 tree_insert WARN_ON`（/sdcard 大量写入时触发）——upstream 已知噪音，5.4.302 同样存在，5.11 重构才消除，无功能影响，**未修**（backport 重构风险 > 收益）。

## 构建（WSL / Linux）

```bash
# 1. 取基线源码
git clone https://github.com/MrNya907/xiaomi_kernel_odin.git kernel
cd kernel && git checkout ada168693

# 2. 应用本机补丁
git apply odin_b11_full.patch

# 3. 编译（工具链：AOSP clang r383902b1，LLVM=1 LLVM_IAS=1）
bash build_now.sh            # 产物 out/arch/arm64/boot/Image
# 或完整流程（编译+打包 boot.img）:
DRY=1 RAMDISK_SRC=<原厂boot.img> OUT_IMG=out.img bash one_shot.sh <原厂boot.img>
```

或直接下载 Release 的完整源树快照（`odin-base-src.tar.zst`，含全部补丁已应用）。

## 刷入

- **dd 直刷**（系统内有 root 时）：
  ```bash
  adb push boot.img /data/local/tmp/X.img
  adb shell sha256sum /data/local/tmp/X.img        # 与电脑端哈希核对
  adb shell dd if=/data/local/tmp/X.img of=/dev/block/bootdevice/by-name/boot_a bs=4M
  adb shell sync && adb reboot
  ```
- **fastboot**：`adb reboot bootloader && fastboot flash boot_a boot.img`
- 回滚保底：原厂 boot.img 或任一稳定旧内核。

## 适配范围声明

仅适配本人设备（Xiaomi MIX 4， Snapdragon 888+，MIUI/HyperOS 基线 5.4.281 内核）。其他同机型设备理论上可用，但未验证。仅供个人学习与自用，不提供任何担保。
