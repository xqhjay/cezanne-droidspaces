#!/bin/sh
# 应用 cezanne (MTK 4.14) 在 clang 12 下构建所需的补丁。
# 用法: apply-fixes.sh <kernel-dir>
#
# 三项修复彼此独立，各自幂等，互不阻断：
#   1. 定点关闭 MTK vendor 代码过严诊断
#   2. 修复 mtk-vcu 重复链接（duplicate symbol）
#   3. 补 stpcpy（clang 将 strcpy 循环优化成 stpcpy，4.14 无此符号）

set -e
K="$1"
[ -d "$K" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }

# ===============================================================
# 修复 1：drivers/gpu/drm/mediatek/mtk_drm_crtc.c:2529
# 把 struct cmdq_pkt * 强转 unsigned int 打印，clang 12 在 -Werror 下报错。
# 用内核原生 CFLAGS_<obj> 定点抑制（不参与 cc-option 探测，
# 不能用 KCFLAGS：它会并入 KBUILD_CFLAGS，污染编译器能力探测）。
# ===============================================================
MK="$K/drivers/gpu/drm/mediatek/Makefile"
if [ -f "$MK" ]; then
  if grep -qF 'Wno-pointer-to-int-cast' "$MK"; then
    echo "[1/3] drm 诊断抑制已存在，跳过"
  else
    cat >> "$MK" <<'EOF'

# --- Droidspaces build fix: MTK vendor 代码在 clang 12 下的诊断兼容 ---
CFLAGS_mtk_drm_crtc.o += -Wno-pointer-to-int-cast -Wno-int-to-pointer-cast -Wno-format
EOF
    echo "[1/3] 已为 mtk_drm_crtc.o 添加诊断抑制"
  fi
else
  echo "[1/3] ::warning::未找到 $MK，跳过"
fi

# ===============================================================
# 修复 2：drivers/media/platform/mtk-vcu/Makefile 重复链接
#
# 原文件同时存在：
#   mtk-vcu-y += mtk_vcu.o mtk_vcodec_mem.o            (组合对象)
#   obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o mtk_vcodec_mem.o
# CONFIG_VIDEO_MEDIATEK_VCU=y 时两者均生效，mtk_vcodec_mem.o 链接两次，
# 导致 mtk_vcu_mem_init / mtk_vcu_set_buffer 等 duplicate symbol。
# ===============================================================
VK="$K/drivers/media/platform/mtk-vcu/Makefile"
if [ -f "$VK" ]; then
  if grep -qF 'mtk-vcu.o mtk_vcodec_mem.o' "$VK"; then
    sed -i 's|^obj-[$](CONFIG_VIDEO_MEDIATEK_VCU)[[:space:]]*+=[[:space:]]*mtk-vcu[.]o mtk_vcodec_mem[.]o$|obj-$(CONFIG_VIDEO_MEDIATEK_VCU) += mtk-vcu.o|' "$VK"
    echo "[2/3] 已修复 mtk-vcu 重复链接"
  else
    echo "[2/3] mtk-vcu/Makefile 无重复项，跳过"
  fi
else
  echo "[2/3] ::warning::未找到 $VK，跳过"
fi

# ===============================================================
# 修复 3：补 stpcpy
#
# clang 的循环优化会把 `while ((*d++ = *s++));` 改写成对 stpcpy 的调用，
# 而 4.14 的 lib/string.c 没有该函数，最终 vmlinux 链接时报
# `undefined symbol: stpcpy`。补一份标准实现并导出即可。
# ===============================================================
SC="$K/lib/string.c"
SH="$K/include/linux/string.h"
if [ -f "$SC" ] && [ -f "$SH" ]; then
  if grep -qF '__HAVE_ARCH_STPCPY' "$SC" || grep -qE '^char \*stpcpy' "$SC"; then
    echo "[3/3] stpcpy 已存在，跳过"
  else
    # 头文件声明：插在 strcpy 声明之后
    if ! grep -qE 'stpcpy' "$SH"; then
      sed -i 's|^extern char \* strcpy(char \*,const char \*);$|extern char * strcpy(char *,const char *);\nextern char * stpcpy(char *,const char *);|' "$SH"
    fi

    # 实现：插在文件开头 include 之后，作为独立顶层块，
    # 不依赖 __HAVE_ARCH_STRCPY 的嵌套条件，避免被条件编译吞掉。
    STP_ANCHOR=$(grep -n '^#include <linux/string.h>' "$SC" | head -1 | cut -d: -f1)
    if [ -z "$STP_ANCHOR" ]; then
      STP_ANCHOR=$(grep -n '^#include' "$SC" | tail -1 | cut -d: -f1)
    fi
    if [ -z "$STP_ANCHOR" ]; then
      echo "::error::stpcpy 注入失败（找不到 include 锚点）"
      exit 1
    fi

    awk -v anchor="$STP_ANCHOR" '
      { print }
      NR == anchor && !done {
        print ""
        print "#ifndef __HAVE_ARCH_STPCPY"
        print "/**"
        print " * stpcpy - Copy a NUL terminated string, returning pointer to its end"
        print " * @dest: Where to copy the string to"
        print " * @src: Where to copy the string from"
        print " */"
        print "char *stpcpy(char *dest, const char *src)"
        print "{"
        print "\twhile ((*dest = *src) != 0) {"
        print "\t\tdest++;"
        print "\t\tsrc++;"
        print "\t}"
        print "\treturn dest;"
        print "}"
        print "EXPORT_SYMBOL(stpcpy);"
        print "#endif"
        done = 1
      }
    ' "$SC" > "$SC.new" && mv "$SC.new" "$SC"

    if grep -qE '^char \*stpcpy' "$SC"; then
      echo "[3/3] 已补充 stpcpy 实现与声明"
    else
      echo "::error::stpcpy 注入失败（未找到 EXPORT_SYMBOL(strcpy) 锚点）"
      exit 1
    fi
  fi
else
  echo "[3/3] ::warning::未找到 lib/string.c 或 string.h，跳过"
fi

echo "补丁流程完成"
