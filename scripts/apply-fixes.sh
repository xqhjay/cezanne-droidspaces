#!/bin/sh
# 应用 cezanne (MTK 4.14 MGF) 构建所需的补丁。
# 用法: apply-fixes.sh <kernel-dir>
#
# 每项修复独立幂等，互不阻断。

set -e
K="$1"
[ -d "$K" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }

# ===============================================================
# 修复 1：drivers/media/platform/Makefile —— mtk-vcu 目录被注释掉
#
# 上游（OSS 公开源码）状态：
#   # obj-$(CONFIG_VIDEO_MEDIATEK_VCU)    += mtk-vcu/
#   obj-$(CONFIG_VIDEO_MEDIATEK_VCODEC)    += mtk-vcodec/
#
# 但 mtk-vcodec/Makefile 在 CONFIG_VIDEO_MEDIATEK_VCU 下会编译
# venc_vcu_if.o / vdec_vcu_if.o，它们引用 vcu_ipi_send、
# vcu_get_task、vcu_mapping_dm_addr 等符号——这些全部定义在
# mtk-vcu/mtk_vcu.c 中。
# mtk-vcu/ 未被引入 => 符号缺失 => vmlinux 链接失败：
#   undefined reference to `vcu_mapping_dm_addr' ...
#
# 已核实原厂 boot.img 内核中存在 vcu_ipi_send 符号（出现 3 次），
# 说明量产内核确实把 mtk-vcu 编进去了，是公开源码把这行注释掉了。
# 修复：取消注释。
PM="$K/drivers/media/platform/Makefile"
if [ -f "$PM" ]; then
  if grep -q '^# *obj-\$(CONFIG_VIDEO_MEDIATEK_VCU)[[:space:]]*+= *mtk-vcu/' "$PM"; then
    sed -i 's|^# *obj-\$(CONFIG_VIDEO_MEDIATEK_VCU)[[:space:]]*+= *mtk-vcu/|obj-$(CONFIG_VIDEO_MEDIATEK_VCU)\t+= mtk-vcu/|' "$PM"
    echo "[1/3] 已恢复 drivers/media/platform/Makefile 中的 mtk-vcu/ 引入"
  else
    echo "[1/3] 无需恢复（已启用或格式不同）"
  fi
  grep -nE "mtk-vcu/|mtk-vcodec/" "$PM" | head -4
else
  echo "[1/3] ::warning::未找到 $PM，跳过"
fi

# ===============================================================
# 修复 2：mtk-vcu/Makefile —— mtk-vcu 组合对象的符号没进入 vmlinux
#
# 原文件：
#   mtk-vcu-y += mtk_vcu.o \
#       mtk_vcodec_mem.o
#   obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o
#
# 问题有两处：
#  a) obj-y += mtk-vcu.o 引用的是由 mtk-vcu-y 合成的组合目标，
#     但同一行又并列写了 mtk_vcodec_mem.o，导致它既在组合对象内、
#     又被单独链接一次 -> duplicate symbol。
#  b) 更关键：mtk-vcodec/venc_vcu_if.o 在 CONFIG_VIDEO_MEDIATEK_VCU 下
#     引用 vcu_ipi_send / vcu_get_task / vcu_mapping_dm_addr 等符号，
#     这些定义在 mtk_vcu.c 里。若组合对象没被正确链接进 vmlinux，
#     就出现 undefined reference。
#
# 正确写法：只保留组合对象，并确保 built-in 时用 obj-y 引入组合目标。
# CONFIG_VIDEO_MEDIATEK_VCU=y 时 obj-y 会展开 mtk-vcu.o（组合对象），
# 其内部已含 mtk_vcodec_mem.o，不应再单独列一次。
VK="$K/drivers/media/platform/mtk-vcu/Makefile"
if [ -f "$VK" ]; then
  if grep -q '^obj-\$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o$' "$VK"; then
    sed -i 's|^obj-\$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o$|obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o|' "$VK"
    echo "[2/3] 已修正 mtk-vcu/Makefile 重复列出 mtk_vcodec_mem.o"
  else
    echo "[2/3] mtk-vcu/Makefile 无需修正或已修正"
  fi
  grep -nF 'obj-$(CONFIG_VIDEO_MEDIATEK_VCU)' "$VK"
else
  echo "[2/3] ::warning::未找到 $VK，跳过"
fi

# ===============================================================
# 修复 3：drivers/gpu/drm/mediatek —— clang 诊断兼容
# mtk_drm_crtc.c 把 struct cmdq_pkt * 强转成 unsigned int 打印，
# clang 12 在 -Werror 下报错。用内核原生 CFLAGS_<obj> 定点抑制，
# 不参与 cc-option 能力探测。
MK="$K/drivers/gpu/drm/mediatek/Makefile"
if [ -f "$MK" ]; then
  if ! grep -q 'CFLAGS_mtk_drm_crtc.o' "$MK"; then
    cat >> "$MK" <<'EOF'

# --- build fix: MTK vendor 代码在 clang 12 下的诊断兼容 ---
CFLAGS_mtk_drm_crtc.o += -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Wno-format
EOF
    echo "[3/3] 已为 mtk_drm_crtc.o 添加诊断抑制"
  else
    echo "[3/3] drm 诊断抑制已存在，跳过"
  fi
else
  echo "[3/3] ::warning::未找到 $MK，跳过"
fi

echo "补丁流程完成"
