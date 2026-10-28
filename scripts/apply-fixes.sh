#!/bin/sh
# 为 MTK vendor 代码定点关闭 clang 过于严格的诊断。
#
# 背景：这棵 4.14 树的 vendor 代码用旧工具链写成，
#   drivers/gpu/drm/mediatek/mtk_drm_crtc.c:2529 把 struct cmdq_pkt * 强转成
#   unsigned int 打印（DDPPR_ERR），clang 12 在 -Werror 下直接报错。
#
# 为什么不用 KCFLAGS：KCFLAGS 会并入 KBUILD_CFLAGS，而 cc-option 的能力探测
#   用的就是 KBUILD_CFLAGS（CC_OPTION_CFLAGS = filter-out(KBUILD_CFLAGS)）。
#   传 -Wno-error 会让 -Werror 探测恒成功，进而误判
#   "-fstack-protector-strong not supported by compiler"。
#
# 正确做法：用内核原生的 CFLAGS_<basename>.o 做定点抑制，它不参与能力探测。

set -e
K="$1"
[ -d "$K" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }

MK="$K/drivers/gpu/drm/mediatek/Makefile"
[ -f "$MK" ] || { echo "::error::找不到 $MK"; exit 1; }

# 幂等：已打过就跳过
if grep -q "Wno-pointer-to-int-cast" "$MK"; then
  echo "补丁已存在，跳过"
  exit 0
fi

cat >> "$MK" <<'EOF'

# --- Droidspaces build fix: MTK vendor 代码在 clang 12 下的诊断兼容 ---
CFLAGS_mtk_drm_crtc.o += -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Wno-format
EOF

echo "已为 mtk_drm_crtc.o 添加诊断抑制"
grep -n "Wno-pointer-to-int-cast" "$MK"
