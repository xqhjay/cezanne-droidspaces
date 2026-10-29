### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
##
## 本文件为 Redmi K30 Ultra (cezanne / k6889v1_64) 定制。
## 关键：已删除上游模板中 Galaxy Nexus (tuna) 的示范补丁段。
## 那些 patch 会改写 boot.img 里的 init.rc / init.tuna.rc / fstab.tuna，
## 对 Android 12 设备属于破坏性修改，会导致开机卡第一屏。

### AnyKernel setup
# global properties
properties() { '
kernel.string=Cezanne kernel for Droidspaces (SYSVIPC + IPC_NS)
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
# boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
#
# 只做一件事：把新内核替换进原厂 boot.img，ramdisk 原样保留。
# 刻意不调用任何 patch_fstab / replace_string / insert_line，
# 避免改动 init.rc / fstab 等启动关键文件。
dump_boot;

write_boot;
## end boot install
