#!/bin/sh
# 为 MTK vendor 代码打两个必要的构建补丁。
# 用法: apply-fixes.sh <kernel-dir>
#
# 两项修复彼此独立，各自做幂等判断，互不阻断。

set -e
K="$1"
[ -d "$K" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }

# ===============================================================
# 修复 1：drivers/gpu/drm/mediatek 诊断抑制
#
# 背景：这棵 4.14 树的 vendor 代码用旧工具链写成，
#   mtk_drm_crtc.c:2529 把 struct cmdq_pkt * 强转成 unsigned int 打印
#   （DDPPR_ERR），clang 12 在 -Werror 下直接报错。
#
# 为什么不用 KCFLAGS：KCFLAGS 会并入 KBUILD_CFLAGS，而 cc-option 的能力探测
#   用的正是 KBUILD_CFLAGS（CC_OPTION_CFLAGS = filter-out(KBUILD_CFLAGS)）。
#   传 -Wno-error 会让 -Werror 探测恒成功，进而误判
#   "-fstack-protector-strong not supported by compiler"。
#
# 正确做法：用内核原生的 CFLAGS_<basename>.o 定点抑制，它不参与能力探测。
# ===============================================================
MK="$K/drivers/gpu/drm/mediatek/Makefile"
if [ -f "$MK" ]; then
  if grep -qF -e "Wno-pointer-to-int-cast" "$MK"; then
    echo "[1/2] drm 诊断抑制已存在，跳过"
  else
    cat >> "$MK" <<'EOF'

# --- Droidspaces build fix: MTK vendor 代码在 clang 12 下的诊断兼容 ---
CFLAGS_mtk_drm_crtc.o += -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Wno-format
EOF
    echo "[1/2] 已为 mtk_drm_crtc.o 添加诊断抑制"
  fi
else
  echo "::error::找不到 $MK"
  exit 1
fi

# ===============================================================
# 修复 2：mtk-vcu/Makefile 重复把 mtk_vcodec_mem.o 加入链接
#
# 原文件：
#   mtk-vcu-y += mtk_vcu.o \
#       mtk_vcodec_mem.o \          <-- 编进 mtk-vcu 组合对象
#
#   obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o
#                                       ^ mtk_vcodec_mem.o 又单独加一次
#
# CONFIG_VIDEO_MEDIATEK_VCU=y 时两处都生效，mtk_vcodec_mem.o 被链接两次，
# 于是 mtk_vcu_mem_init / mtk_vcu_set_buffer 等全部 duplicate symbol。
# 修法：组合对象已包含该 .o，单独那行去掉重复项。
# ===============================================================
VK="$K/drivers/media/platform/mtk-vcu/Makefile"
if [ -f "$VK" ]; then
  if grep -qF 'mtk-vcu.o mtk_vcodec_mem.o' "$VK"; then
    sed -i 's|^obj-[$](CONFIG_VIDEO_MEDIATEK_VCU)[[:space:]]*+=[[:space:]]*mtk-vcu[.]o mtk_vcodec_mem[.]o$|obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o|' "$VK"
    echo "[2/2] 已修复 mtk-vcu/Makefile 重复链接"
  else
    echo "[2/2] mtk-vcu/Makefile 无重复项，跳过"
  fi
  echo "      当前内容：$(grep -F 'obj-$(CONFIG_VIDEO_MEDIATEK_VCU)' "$VK" | head -1)"
else
  echo "::warning::未找到 $VK，跳过修复 2"
fi

echo "补丁流程完成"
