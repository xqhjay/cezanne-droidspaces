# Redmi K30 Ultra (cezanne) 内核修复：让 Droidspaces 能跑容器

## 一、结论先行

Droidspaces 报「内核不支持」**不是配置错误、也不是 root 权限问题**，而是你这台机器的内核在**编译时就没有开启 System V IPC**，导致 IPC namespace 在内核里根本不存在。**没有开关能跳过这项检查。**

| 环节 | 证据（本次实测） |
|---|---|
| 探针逻辑 | `src/check.c:49` `check_ns()` 仅检测 `/proc/self/ns/ipc` 是否存在 |
| 运行时实测 | `ls /proc/self/ns/` → `cgroup mnt net pid pid_for_children uts`，**无 ipc** |
| SysV IPC 实测 | `/proc/sys/kernel/{shmmax,shmall,msgmax,msgmnb,sem}` **全部不存在** → `CONFIG_SYSVIPC` 关闭 |
| Kconfig 依赖 | `init/Kconfig:1089` `config IPC_NS` → `depends on (SYSVIPC \|\| POSIX_MQUEUE)` → 两者皆关时 IPC_NS 无法为 y |
| 硬阻断 | `src/monitor.c:136` 无条件执行 `unshare(CLONE_NEWUTS \| CLONE_NEWIPC)`，失败即 `ds_die()` |
| 问题源头 | 官方 `cezanne_user_defconfig`（MiCode `cezanne-r-oss`，内核 **4.14.186**，与本机完全同版本）中 `SYSVIPC` / `POSIX_MQUEUE` / `DEVTMPFS` **一个都没有** |

设备信息：Redmi K30 Ultra（cezanne），MediaTek MT6889 天玑1000+，Android 12 (31)，内核 `4.14.186-perf-00241-g172a9693e072`，SELinux Enforcing，Root 管理器为 Magisk (vvb2060 Alpha)。

## 二、为什么必须改内核

`/proc/self/ns/ipc` 这个文件由内核代码 `ipc/namespace.c` 在 `CONFIG_IPC_NS=y` 时才创建。它是**编译期决定**的，不是运行期 sysctl 能改的。同理 `CONFIG_SYSVIPC` 关掉后，`shmget/semget/msgget` 系统调用直接返回 `ENOSYS`，用户态任何手段都无法补出来。

而 `monitor.c` 在容器启动路径上**无条件** `unshare(CLONE_NEWIPC)`，这不是可选参数，没有 `--no-ipc` 之类开关。所以：

> 要么让内核有 IPC namespace，要么容器就起不来。

## 三、三条路径对比

| 路径 | 可行性 | 代价 / 风险 | 建议 |
|---|---|---|---|
| **A. 重编内核并开启 SYSVIPC + IPC_NS** | ✅ 唯一「正确」方案 | 需解锁 BL、编译、打包 AnyKernel3 刷入；MTK 机型刷错会卡 logo / 变砖 | **推荐** |
| **B. 改后端二进制跳过 CLONE_NEWIPC** | ⚠️ 勉强可起容器 | 无 IPC 隔离；systemd 发行版大概率仍失败；App 更新会覆盖二进制 | 仅作临时验证 |
| **C. 换社区现成内核** | ❌ 目前社区清单无 cezanne | 需自行寻找维护者 | 可去 Telegram 问 |

### 关于路径 A 的两个有利条件

1. **这是 non-GKI 内核（4.14），不需要 kABI 补丁。**
   官方文档写明 GKI（5.4+）才需要 `001.GKI-below-6.12-fix_sysvipc_kabi...patch` 来保护 ABI，否则启用 SYSVIPC 会因结构体偏移变化导致 vendor 模块拒绝加载 → **bootloop**。4.14 没有这个约束，可以直接开配置项。这是本机型最大的优势。
2. **内核源码公开且版本吻合。**
   `MiCode/Xiaomi_Kernel_OpenSource` 的 `cezanne-r-oss` 分支 `Makefile` 中 `VERSION=4 / PATCHLEVEL=14 / SUBLEVEL=186`，与本机 `4.14.186` 完全一致；defconfig 为 `arch/arm64/configs/cezanne_user_defconfig`。

> 注意：本机版本串是 `-perf-00241-g172a9693e072`，该 git 短号在 OSS 分支中不存在（属厂商内部构建）。用 OSS 分支编译出的内核功能等价，但并非逐字节同源。若要绝对稳妥，可先从社区找本机型 MIUI 对应内核源码。

## 四、路径 A 操作步骤

### 步骤 0：备份 boot 分区（**必做**，一步都不能省）

```bash
# 在手机 root shell（如 Termux su / adb root）执行
ls -l /dev/block/by-name/ | grep -Ei "boot|dtbo"
dd if=/dev/block/by-name/boot  of=/sdcard/boot-backup.img
dd if=/dev/block/by-name/dtbo  of=/sdcard/dtbo-backup.img
```
再额外用 Magisk App 的「备份」或 TWRP 做一次完整 boot 备份。**没有备份不要刷。**

### 步骤 1：合并内核配置片段

片段见 `droidspaces.fragment`。核心只有四项（其余为可选增强）：

```
CONFIG_SYSVIPC=y          # SysV IPC 本体（根因）
CONFIG_POSIX_MQUEUE=y     # POSIX 消息队列（与上一项共同解锁 IPC_NS）
CONFIG_IPC_NS=y           # Droidspaces 检查的就是它
CONFIG_DEVTMPFS=y         # 硬件访问模式（当前也是 ✗）
```

> **关于 `CONFIG_DEVTMPFS_MOUNT`：本片段故意不开启。**
> 它会让内核在 `prepare_namespace` 阶段自行把 devtmpfs 挂到 `/dev`，而 Android/MTK 的 `/dev` 由 ramdisk + init 建立，重复挂载可能干扰早期启动。Droidspaces 只需要内核**具备** devtmpfs 能力，不需要内核代挂。
> 同理 `CONFIG_USER_NS` 在片段里默认注释掉：它是可选功能（`--allow-sandboxing`），不开也能正常跑容器。

> **已校验**：上述符号均在本机型 4.14.186 源码树中存在
> （`SYSVIPC` / `POSIX_MQUEUE` / `IPC_NS` / `NAMESPACES` 在 `init/Kconfig`，`DEVTMPFS` / `DEVTMPFS_MOUNT` 在 `drivers/base/Kconfig`，`OVERLAY_FS` 在 `fs/overlayfs/Kconfig`，`MACVLAN` 在 `drivers/net/Kconfig`，`TMPFS_POSIX_ACL` / `TMPFS_XATTR` 在 `fs/Kconfig`）。
> 另确认 `menuconfig NAMESPACES` 依赖 `MULTIUSER`，而 `MULTIUSER` 为 `default y` 且设备已具备 pid/mnt/uts/net 命名空间，说明 `NAMESPACES` 本就是 y，无额外依赖风险。

合并方式（在 kernel 源码根目录）：

```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-android-

# 生成基础配置
make O=out cezanne_user_defconfig

# 用 merge_config.sh 合并片段（4.14 树自带该脚本）
./scripts/kconfig/merge_config.sh -O out out/.config droidspaces.fragment

# 逐项确认，四项必须都是 =y
grep -E "CONFIG_(SYSVIPC|POSIX_MQUEUE|IPC_NS|NAMESPACES|DEVTMPFS)=" out/.config
```

⚠️ 若 `CONFIG_IPC_NS` 合并后仍不是 `y`，说明 `SYSVIPC`/`POSIX_MQUEUE` 有一项没落进 `.config`，回到上一步查依赖，不要硬改。

### 步骤 2：编译

```bash
make -j$(nproc) O=out ARCH=arm64 \
     CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
     Image.gz dtbo.img
```
- MTK 机型产物通常是 `out/arch/arm64/boot/Image.gz` 与 `out/arch/arm64/boot/dtbo.img`
- 工具链建议 AOSP clang（如 r416183b），**不要**用 GCC 混编
- **本机内存与磁盘不足以在手机上编译**：`/data` 仅剩约 8.3 GB，而 4.14 内核 out 目录需要 15–25 GB。请用 PC 或 GitHub Actions

### 步骤 3：打包刷机

用 AnyKernel3 打包成 Magisk 可直接刷的 zip：

```bash
git clone https://github.com/osm0sis/AnyKernel3 -b master ak3
cp out/arch/arm64/boot/Image.gz ak3/
cp out/arch/arm64/boot/dtbo.img ak3/         # 视机型是否需一并打包
# 编辑 ak3/anykernel.sh 里的 device.name / block 路径指向 boot 分区
cd ak3 && zip -r9 ../droidspaces-cezanne.zip * -x .git README.md *placeholder
```

刷入：Magisk App → 模块 → 从本地安装 → 选 zip → 重启。
**不要**用「直接安装」方式刷 boot.img 的旧副本，避免覆盖 Magisk 补丁。

### 步骤 4：验证

重启后执行：

```bash
su -c 'ls /proc/self/ns/'
# 期望输出中出现 ipc
su -c 'ls /proc/sys/kernel/ | grep -E "shm|sem|msg"'
# 期望出现 shmmax shmall msgmax msgmnb sem
```

然后 Droidspaces App → 设置 → 需求检查，`[✗] IPC namespace` 应变 `[✓]`，同时 `devtmpfs` 也会转 ✓。

## 五、路径 B：临时验证（不推荐长期用）

若只想先确认「除去 IPC 之外其它都正常」，可让后端跳过 IPC unshare：

```bash
# 在源码树中把 monitor.c:136 改为仅 UTS
sed -i 's/int ns_flags = CLONE_NEWUTS | CLONE_NEWIPC;/int ns_flags = CLONE_NEWUTS;/' src/monitor.c
# 同时让 check.c 不再把 ipc 计为缺失，否则 App 仍显示不支持
```
然后交叉编译出 aarch64 musl 静态二进制，替换 `/data/local/Droidspaces` 下的后端。

**已知代价**：容器没有 IPC 隔离（共享宿主 IPC，安全风险）；`shmget` 等调用返回 `ENOSYS`，X11 (MIT-SHM)、PostgreSQL 等依赖 SysV shm 的程序会崩；systemd 发行版很可能仍启动失败，建议先试 Alpine + OpenRC。App 更新后二进制会被覆盖，需重打。

## 六、文件清单

| 文件 | 用途 |
|---|---|
| `droidspaces.fragment` | 内核配置片段，直接 merge 进 `.config` |
| `.github/workflows/build-kernel.yml` | GitHub Actions 云端编译 + AnyKernel3 打包（免本地环境） |
| `README.md` | 本文件：根因分析与操作手册 |

## 七、参考

- 官方内核配置指南：`Droidspaces-OSS/Documentation/Kernel-Configuration.md`（本地副本：`../kernel-config-guide.md`）
- 社区支持设备清单：`Documentation/community-supported-devices.md`（**目前不含 cezanne**）
- 内核源码：`https://github.com/MiCode/Xiaomi_Kernel_OpenSource` 分支 `cezanne-r-oss`
- 提问渠道：Telegram `https://t.me/Droidspaces`
