#!/bin/bash
#
# grow-md-pixxiodata.sh - keep the md RAID layer and grow it (+ ext4) to fill
# the 8 TB disk. Partition START stays at 2048; no data is moved.
#
# Run on Debian as root. Step by step:
#
#   ./grow-md-pixxiodata.sh verify     /dev/sdX   # read-only report (shows if a superblock exists)
#   ./grow-md-pixxiodata.sh growpart   /dev/sdX   # extend partition END to fill disk (WRITES table)
#   ./grow-md-pixxiodata.sh assemble   /dev/sdX   # start the existing array  -> needs a valid superblock
#     # --- if 'assemble' fails because the superblock is missing (this clone): ---
#   ./grow-md-pixxiodata.sh recreate   /dev/sdX   # rebuild md metadata (DANGEROUS), verifies ext4 after
#   ./grow-md-pixxiodata.sh grow       /dev/sdX   # mdadm --grow --size=max
#   ./grow-md-pixxiodata.sh resize     /dev/sdX   # e2fsck + resize2fs on the md device
#   ./grow-md-pixxiodata.sh status     /dev/sdX   # /proc/mdstat + mdadm --detail
#   ./grow-md-pixxiodata.sh stop       /dev/sdX   # mdadm --stop (helper)
#
# md device name is /dev/md0 by default; override with:  MD=/dev/md5 ./grow-md...

set -euo pipefail

# ---- Verified constants (read off sd2, read-only, 2026-10-02) -----------------
EXPECT_DISK_SECTORS=15628053168          # whole 8 TB disk, 512-byte sectors
NEW_PART_END=15628053134                 # last usable LBA (disk total - 34)
OLD_PART_START=2048                       # partition 1 start - MUST stay here (Option A)
DATA_OFFSET=262144                        # md 1.2 data offset, in sectors
FS_SB_SECTOR_ABS=$((OLD_PART_START + DATA_OFFSET + 2))  # 264194: ext4 sb on the raw disk
EXPECT_MAGIC="53ef"                       # ext4 s_magic (0xEF53)
EXPECT_UUID="ffbabcedb9434916906796d77058d416"   # ext4 s_uuid, raw 16 bytes
EXPECT_LASTMOUNT="/pixxiodata"            # ext4 s_last_mounted
ORIG_FS_BLOCKS=819331072                  # ext4 block count before the grow

# data offset to request when REBUILDING metadata. NOTE: mdadm's unit for
# --data-offset varies by version; the 'recreate' step verifies the actual
# result and refuses to continue if it isn't 262144 sectors, so a wrong unit
# here is caught, not acted on.
CREATE_DATA_OFFSET="262144"

DEV="${2:-}"
MD="${MD:-/dev/md0}"
BACKUP_GPT="/root/$(basename "${DEV:-disk}").gpt.bak"

die()  { echo "ABORT: $*" >&2; exit 1; }
note() { echo "  $*"; }
part_node() { case "$DEV" in *[0-9]) echo "${DEV}p1";; *) echo "${DEV}1";; esac; }

# --- guards ---------------------------------------------------------------

guard_root()  { [ "$(id -u)" -eq 0 ] || die "run as root (sudo -i)"; }
guard_tools() { for t in mdadm sgdisk partprobe e2fsck resize2fs dumpe2fs blkid blockdev dd od; do
                  command -v "$t" >/dev/null || die "missing tool: $t"; done; }
guard_is_disk() { [ -b "$DEV" ] || die "not a block device: $DEV"
                  [ "$(lsblk -dno TYPE "$DEV")" = "disk" ] || die "$DEV is not a whole disk"; }
guard_disk_size() { [ "$(blockdev --getsz "$DEV")" = "$EXPECT_DISK_SECTORS" ] \
                      || die "disk size mismatch - wrong drive?"; }

sect_hex() { dd if="$1" bs=512 skip="$2" count=1 status=none | od -An -v -tx1 | tr -d ' \n'; }

# Anchor on the RAW disk: ext4 sb must sit at absolute sector 264194. Invariant
# for Option A because the partition start never moves and data never moves.
guard_right_disk() {
  local s; s=$(sect_hex "$DEV" "$FS_SB_SECTOR_ABS")
  [ "${s:112:4}" = "$EXPECT_MAGIC" ] || die "no ext4 magic at sector $FS_SB_SECTOR_ABS - wrong disk/offset"
  [ "${s:208:32}" = "$EXPECT_UUID" ] || die "ext4 UUID mismatch - NOT the pixxiodata disk"
}

# After the array is up: ext4 sb must appear at md-device offset 1024 (sector 2).
# Proves the array's data_offset lines up with the real filesystem.
guard_md_fs() {
  [ -b "$MD" ] || die "$MD is not active"
  local s; s=$(sect_hex "$MD" 2)
  [ "${s:112:4}" = "$EXPECT_MAGIC" ] || die "no ext4 at $MD offset 1024 - data_offset is WRONG, not safe"
  [ "${s:208:32}" = "$EXPECT_UUID" ] || die "ext4 UUID mismatch on $MD - abort"
}

part1_start() { sgdisk -i 1 "$DEV" | awk -F'[ :]+' '/^First sector/{print $3}'; }
guard_start_unchanged() { [ "$(part1_start)" = "$OLD_PART_START" ] || die "partition start moved off $OLD_PART_START"; }

guard_not_in_use() {
  local p; p=$(part_node); [ -b "$p" ] || return 0
  [ -z "$(lsblk -no MOUNTPOINT "$p")" ] || die "$p is mounted - umount first"
}

common_guards() { guard_root; guard_tools; guard_is_disk; guard_disk_size; guard_right_disk; }
confirm() { local w=$1 g; read -r -p "Type '$w' to proceed: " g; [ "$g" = "$w" ] || die "not confirmed"; }

# --- commands -------------------------------------------------------------

cmd_verify() {   # read-only: is there a superblock to grow, or not?
  common_guards
  echo "Disk:            $DEV ($EXPECT_DISK_SECTORS sectors, 8 TB)"
  echo "Partition 1:     start $(part1_start) (must stay $OLD_PART_START)"
  echo "ext4 anchor:     confirmed at absolute sector $FS_SB_SECTOR_ABS"
  echo "--- mdadm --examine $(part_node) ---"
  mdadm --examine "$(part_node)" 2>&1 || true
  echo
  echo "If --examine shows NO superblock / bad magic, 'assemble' will fail and"
  echo "you must use 'recreate' (dangerous) before 'grow'."
}

cmd_growpart() {   # extend partition 1 END only; start and all content untouched
  common_guards; guard_not_in_use; guard_start_unchanged
  [ -f "$BACKUP_GPT" ] || { sgdisk --backup="$BACKUP_GPT" "$DEV"; note "GPT backed up to $BACKUP_GPT"; }
  echo "Extend partition 1 on $DEV to end sector $NEW_PART_END (start stays $OLD_PART_START)."
  confirm "GROWPART"
  sgdisk --delete=1 "$DEV"                                           # remove old entry (content stays on disk)
  sgdisk --new=1:${OLD_PART_START}:${NEW_PART_END} \
         --typecode=1:8300 --change-name=1:"Linux RAID" "$DEV"       # same start, bigger end
  partprobe "$DEV"; sleep 1
  guard_start_unchanged                                              # start MUST still be 2048
  guard_right_disk                                                   # ext4 still intact on the raw disk
  note "partition 1 now ends at $NEW_PART_END"
}

cmd_assemble() {   # start the EXISTING array (needs a valid md superblock)
  common_guards
  mdadm --assemble --run "$MD" "$(part_node)" \
    || die "assemble failed - no usable superblock. Use 'recreate' if you accept the risk."
  guard_md_fs
  note "$MD assembled; ext4 verified at offset 0"
}

cmd_recreate() {   # DANGEROUS: rebuild md 1.2 metadata over the existing data
  common_guards; guard_not_in_use; guard_start_unchanged
  local p; p=$(part_node)
  echo "This WRITES a fresh md superblock onto $p (degraded raid1, one leg 'missing')."
  echo "It must land data_offset=$DATA_OFFSET sectors or your filesystem disappears."
  echo "You have backups. This is the risky path you asked for."
  confirm "RECREATE-MD-I-HAVE-BACKUPS"
  # --assume-clean: no resync.  --bitmap=none: write as little metadata as possible.
  yes | mdadm --create "$MD" --level=1 --raid-devices=2 --metadata=1.2 \
        --data-offset="$CREATE_DATA_OFFSET" --bitmap=none --assume-clean \
        "$p" missing
  # Verify the offset mdadm actually used, and that ext4 reappears through $MD.
  local off; off=$(mdadm --examine "$p" | awk -F: '/Data Offset/{gsub(/[^0-9]/,"",$2);print $2}')
  if [ "$off" != "$DATA_OFFSET" ] || ! guard_md_fs 2>/dev/null; then
     mdadm --stop "$MD" || true
     mdadm --zero-superblock "$p" || true           # undo: remove the sb we just wrote
     die "data_offset=$off (wanted $DATA_OFFSET) or ext4 not visible - UNDONE, data not touched. Adjust CREATE_DATA_OFFSET."
  fi
  note "$MD recreated with data_offset=$off; ext4 verified at offset 0"
}

cmd_grow() {   # expand the array to use the enlarged partition
  common_guards
  [ -b "$MD" ] || die "$MD not active - run 'assemble' or 'recreate' first"
  guard_md_fs
  mdadm --grow "$MD" --size=max                       # array now spans the bigger member
  note "array grown; mdstat:"; grep -A2 "$(basename "$MD")" /proc/mdstat || true
}

cmd_resize() {   # grow ext4 into the enlarged array
  common_guards
  guard_md_fs
  e2fsck -f "$MD"                                      # resize2fs wants a clean fs
  echo "Growing ext4 on $MD. Not easily reversible."
  confirm "GROW-FS"
  resize2fs "$MD"
  dumpe2fs -h "$MD" | grep -E 'Block count|Free blocks'
  echo "fs UUID for /etc/fstab (mount $MD or this UUID):"; blkid "$MD"
}

cmd_status() { common_guards; cat /proc/mdstat; echo; [ -b "$MD" ] && mdadm --detail "$MD" || true; }
cmd_stop()   { guard_root; mdadm --stop "$MD"; note "$MD stopped"; }

# --- dispatch -------------------------------------------------------------
[ -n "$DEV" ] || die "usage: $0 {verify|growpart|assemble|recreate|grow|resize|status|stop} /dev/sdX"
case "${1:-}" in
  verify)   cmd_verify ;;
  growpart) cmd_growpart ;;
  assemble) cmd_assemble ;;
  recreate) cmd_recreate ;;
  grow)     cmd_grow ;;
  resize)   cmd_resize ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  *) die "unknown command '${1:-}'" ;;
esac
