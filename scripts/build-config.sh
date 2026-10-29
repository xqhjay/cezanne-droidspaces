#!/bin/sh
# 以原厂内核配置为基底，仅添加 Droidspaces 所需的 IPC 支持。
# 其余所有选项保持与原厂完全一致（GPU/TEE/MD/LTO/DEBUG_INFO 等）。
#
# 用法: build-config.sh <stock.config> <output.config>

set -e
SRC="$1"
OUT="$2"

[ -f "$SRC" ] || { echo "usage: $0 <stock.config> <output.config>"; exit 1; }

cp "$SRC" "$OUT"

# 移除可能存在的"未设置"行，再追加我们要开启的项
set_opt() {
  key="$1"; val="$2"
  # 删除已有的该键（含 "is not set" 形式）
  sed -i "/^${key}=/d; /^# ${key} is not set/d" "$OUT"
  printf '%s=%s\n' "$key" "$val" >> "$OUT"
}

# --- 根因：原厂完全没有 System V IPC，导致 IPC_NS 被 Kconfig 依赖链强制关闭 ---
set_opt CONFIG_SYSVIPC y
set_opt CONFIG_POSIX_MQUEUE y

# --- Droidspaces 检查项 ---
set_opt CONFIG_IPC_NS y

# NAMESPACES 原厂已是 y，显式确认一次
set_opt CONFIG_NAMESPACES y

echo "已生成 $OUT"
echo "=== 本次新增/变更的关键项 ==="
grep -E "^CONFIG_(SYSVIPC|POSIX_MQUEUE|IPC_NS|NAMESPACES)=" "$OUT"
