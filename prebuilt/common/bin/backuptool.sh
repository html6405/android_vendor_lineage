#!/sbin/sh
#
# Backup and restore addon /system files
#

export C=/tmp/backupdir
export SYSDEV="$(readlink -nf "$2")"
export SYSFS="$3"
export TMPDIR=/tmp
export V=23

export ADDOND_VERSION=3

# Partitions to mount for backup/restore in V3
export all_V3_partitions="vendor system_ext"

# Scripts in /system/addon.d expect to find backuptool.functions in /tmp
cp -f /tmp/install/bin/backuptool.functions /tmp

get_script_version() {
  version=$(grep "^# ADDOND_VERSION=" $1 | cut -d= -f2)
  [ -z "$version" ] && version=1
  echo $version
}

# Preserve /system/addon.d in /tmp/addon.d
preserve_addon_d() {
  if [ -d $S/addon.d/ ]; then
    mkdir -p /tmp/addon.d/
    cp -a $S/addon.d/* /tmp/addon.d/
    chmod 755 /tmp/addon.d/*.sh
  fi
}

# Restore /system/addon.d from /tmp/addon.d
restore_addon_d() {
  if [ -d /tmp/addon.d/ ]; then
    mkdir -p $S/addon.d/
    cp -a /tmp/addon.d/* $S/addon.d/
    rm -rf /tmp/addon.d/
  fi
}

# Proceed only if /product or /system is the expected major and minor version
check_prereq() {
  RECOVERY_PRODUCT=/product

  # A readable path is insufficient: a failed system mount must not make us
  # accept stale /product metadata or copy files to the recovery ramdisk.
  mounted_path_matches() {
    actual=$(awk -v path="$1" '
      $2 == "/" || $2 == path || index(path, $2 "/") == 1 {
        if (length($2) > longest) {
          longest = length($2); source = $1; target = $2; count = 1
        } else if (length($2) == longest) {
          count++
        }
      }
      END { if (longest && count == 1) print source "|" target }
    ' /proc/mounts)
    [ -n "$actual" ] || return 1
    actual_source=${actual%%|*}
    actual_target=${actual#*|}
    [ "$actual_target" = "$3" ] || return 1
    [ "$(readlink -nf "$actual_source")" = "$(readlink -nf "$2")" ]
  }

  [ -n "$SYSDEV" ] && [ -n "$SYSMOUNT" ] || return 3
  system_root=$(readlink -f "$SYSMOUNT") || return 3
  if ! mounted_path_matches "$system_root" "$SYSDEV" "$SYSMOUNT"; then
    echo "Backup/restore is not possible. Intended system device is not mounted"
    return 3
  fi
  product_dev=$(find_block product)

  # Legacy SAR embeds product below system; recovery /product may be empty.
  for prop in "$S/product/etc/build.prop" \
              "$SYSMOUNT/product/etc/build.prop" \
              "$RECOVERY_PRODUCT/etc/build.prop" \
              "$S/build.prop"; do
    [ -f "$prop" ] && [ -r "$prop" ] || continue
    resolved=$(readlink -f "$prop") || continue
    if mounted_path_matches "$resolved" "$SYSDEV" "$SYSMOUNT"; then
      :
    elif [ -n "$product_dev" ] && \
         mounted_path_matches "$resolved" "$product_dev" "$RECOVERY_PRODUCT"; then
      :
    else
      continue
    fi
    version=$(sed -n 's/^ro\.lineage\.version=//p' "$prop" | head -n 1)
    [ -n "$version" ] || continue
    case "$version" in
      "$V"|"$V".*|"$V"-*) return 0 ;;
      *)
        echo "Backup/restore is not possible. Incompatible ROM version: $V (found $version)"
        return 2
        ;;
    esac
  done
  echo "Backup/restore is not possible. No readable mounted LineageOS version property"
  return 1
}

# Execute /system/addon.d/*.sh scripts with each $@ parameter
run_stages() {
if [ -d /tmp/addon.d/ ]; then
  for script in $(find /tmp/addon.d/ -name '*.sh' |sort -n); do
    v=$(get_script_version $script)
    if [ $v -ge 3 ]; then
      mount_extra $all_V3_partitions
    else
      umount_extra $all_V3_partitions
    fi

    for stage in $@; do
      if [ $v -ge 3 ]; then
        $script $stage
      else
        ADDOND_VERSION= $script $stage
      fi
    done
  done
fi
}

#####################
### Mount helpers ###
#####################
determine_system_mount() {
  if grep -q -e"^$SYSDEV" /proc/mounts; then
    umount $(grep -e"^$SYSDEV" /proc/mounts | cut -d" " -f2)
  fi

  if [ -d /mnt/system ]; then
    SYSMOUNT="/mnt/system"
  elif [ -d /system_root ]; then
    SYSMOUNT="/system_root"
  else
    SYSMOUNT="/system"
  fi

  export S=$SYSMOUNT/system
}

mount_system() {
  mount -t $SYSFS $SYSDEV $SYSMOUNT -o rw,discard
}

unmount_system() {
  umount $SYSMOUNT
}

get_block_for_mount_point() {
  grep -v "^#" /etc/recovery.fstab | grep "[[:blank:]]$1[[:blank:]]" | tail -n1 | tr -s [:blank:] ' ' | cut -d' ' -f1
}

find_block() {
  local name="$1"
  local fstab_entry=$(get_block_for_mount_point "/$name")
  # P-SAR hacks
  [ -z "$fstab_entry" ] && [ "$name" = "system" ] && fstab_entry=$(get_block_for_mount_point "/")
  [ -z "$fstab_entry" ] && [ "$name" = "system" ] && fstab_entry=$(get_block_for_mount_point "/system_root")

  local dev
  if [ "$DYNAMIC_PARTITIONS" = "true" ]; then
    if [ -n "$fstab_entry" ]; then
      dev="${BLK_PATH}/${fstab_entry}"
    else
      dev="${BLK_PATH}/${name}"
    fi
  else
    if [ -n "$fstab_entry" ]; then
      dev="$fstab_entry"
    else
      dev="${BLK_PATH}/${name}"
    fi
  fi

  if [ -b "$dev" ]; then
    echo "$dev"
  fi
}

determine_system_mount

DYNAMIC_PARTITIONS=$(getprop ro.boot.dynamic_partitions)
if [ "$DYNAMIC_PARTITIONS" = "true" ]; then
    BLK_PATH="/dev/block/mapper"
else
    BLK_PATH=$(dirname "$SYSDEV")
fi

mount_extra() {
  for partition in $@; do
    mnt_point="/$partition"
    mountpoint "$mnt_point" >/dev/null 2>&1 && continue
    [ -L "$SYSMOUNT/$partition" ] && continue

    blk_dev=$(find_block "$partition")
    if [ -e "$blk_dev" ]; then
      [ "$DYNAMIC_PARTITIONS" = "true" ] && blockdev --setrw "$blk_dev"
      mkdir -p "$mnt_point"
      mount -o rw "$blk_dev" "$mnt_point"
    fi
  done
}

umount_extra() {
  for partition in $@; do
    umount -l "/$partition" 2>/dev/null
  done
}

case "$1" in
  backup)
    mount_system
    mount_extra product
    if check_prereq; then
      mkdir -p $C
      preserve_addon_d
      run_stages pre-backup backup post-backup
      umount_extra $all_V3_partitions
    fi
    umount_extra product
    unmount_system
  ;;
  restore)
    mount_system
    mount_extra product
    if check_prereq; then
      run_stages pre-restore restore post-restore
      umount_extra $all_V3_partitions
      restore_addon_d
      rm -rf $C
      sync
    fi
    umount_extra product
    unmount_system
  ;;
  *)
    echo "Usage: $0 {backup|restore}"
    exit 1
esac

exit 0
