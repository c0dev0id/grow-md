#!/bin/bash
#
# grow-pixxiodata.sh - convert the degraded md-RAID member into a plain ext4
# partition and grow it to fill an 8 TB disk, WITHOUT moving any data.
#
# Run on the Debian box, as root (sudo -i). Step by step:
#
#   ./grow-pixxiodata.sh verify      /dev/sdX   # read-only sanity report
#   ./grow-pixxiodata.sh backup      /dev/sdX   # save GPT to a file
#   ./grow-pixxiodata.sh repartition /dev/sdX   # rewrite partition 1 (WRITES)
#   ./grow-pixxiodata.sh fsck        /dev/sdX   # check ext4 at its new home
#   ./grow-pixxiodata.sh mountcheck  /dev/sdX   # read-only mount, eyeball it
#   ./grow-pixxiodata.sh resize      /dev/sdX   # grow ext4 (point of no return)
#   ./grow-pixxiodata.sh rollback    /dev/sdX   # undo, only valid before resize
#
# Every writing step re-runs the full guard set first, so you physically
# cannot operate on the wrong disk even if you mistype the device.

set -euo pipefail

# ---- Verified constants (read off sd2 / /dev/rsd2c, read-only, 2026-10-02) ----
EXPECT_DISK_SECTORS=15628053168          # whole 8 TB disk, 512-byte sectors
EXPECT_USABLE_MAX_LBA=15628053134        # last usable LBA (disk total - 34)
OLD_PART_START=2048                      # current partition 1 start
OLD_PART_END=7814037134                  # current partition 1 end (~4 TB)
DATA_OFFSET=262144                       # md 1.2 data offset, in sectors
NEW_PART_START=$((OLD_PART_START + DATA_OFFSET))   # 264192 -> where ext4 block 0 is
NEW_PART_END=$EXPECT_USABLE_MAX_LBA      # fill the disk (sgdisk ':0' would auto-pick this)
FS_SB_SECTOR=$((NEW_PART_START + 2))     # ext4 primary superblock is 1 KiB into the fs
EXPECT_MAGIC="53ef"                      # ext4 s_magic (0xEF53, little-endian)
EXPECT_UUID="ffbabcedb9434916906796d77058d416"    # ext4 s_uuid, raw 16 bytes
EXPECT_LASTMOUNT="/pixxiodata"           # ext4 s_last_mounted
EXPECT_LOGBS=2                           # s_log_block_size -> 1024<<2 = 4096
ORIG_FS_BLOCKS=819331072                 # ext4 block count BEFORE the grow

DEV="${2:-}"
BACKUP_GPT="/root/$(basename "${DEV:-disk}").gpt.bak"

die() { echo "ABORT: $*" >&2; exit 1; }
note() { echo "  $*"; }

# Translate /dev/sdX -> /dev/sdX1, and /dev/nvme0n1 -> /dev/nvme0n1p1
part_node() { case "$DEV" in *[0-9]) echo "${DEV}p1";; *) echo "${DEV}1";; esac; }

# --- guards ---------------------------------------------------------------

guard_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo -i)"; }

guard_tools() {   # fail early if any required binary is missing
  for t in sgdisk partprobe e2fsck resize2fs dumpe2fs blkid blockdev dd od; do
    command -v "$t" >/dev/null || die "missing tool: $t (apt install gdisk parted e2fsprogs util-linux)"
  done
}

guard_is_disk() { # refuse a partition node; we need the whole disk
  [ -b "$DEV" ] || die "not a block device: $DEV"
  [ "$(lsblk -dno TYPE "$DEV")" = "disk" ] || die "$DEV is not a whole disk"
}

guard_disk_size() { # make sure it's the 8 TB disk we measured, not some other drive
  local sz; sz=$(blockdev --getsz "$DEV")
  [ "$sz" = "$EXPECT_DISK_SECTORS" ] || die "disk size $sz != expected $EXPECT_DISK_SECTORS"
}

# Read a 512-byte sector and return it as one lowercase hex string (1024 chars).
sect_hex() { dd if="$DEV" bs=512 skip="$1" count=1 status=none | od -An -v -tx1 | tr -d ' \n'; }
# Little-endian 32-bit hex (8 chars) -> decimal
le32() { local h=$1; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

guard_right_disk() {   # THE anchor check: ext4 superblock must sit at absolute
  local s magic uuid logbs lastmount    # sector 264194 with the expected identity.
  s=$(sect_hex "$FS_SB_SECTOR")         # This never changes: we never move data.
  magic="${s:112:4}"                    # byte 0x38 : s_magic
  uuid="${s:208:32}"                    # byte 0x68 : s_uuid (16 bytes)
  logbs=$(le32 "${s:48:8}")             # byte 0x18 : s_log_block_size
  lastmount=$(dd if="$DEV" bs=1 skip=$((FS_SB_SECTOR*512 + 0x88)) count=64 status=none | tr -d '\0')
  [ "$magic" = "$EXPECT_MAGIC" ]       || die "no ext4 magic at sector $FS_SB_SECTOR (got $magic) - wrong disk or wrong offset"
  [ "$uuid" = "$EXPECT_UUID" ]         || die "ext4 UUID mismatch (got $uuid) - this is NOT the pixxiodata disk"
  [ "$logbs" = "$EXPECT_LOGBS" ]       || die "unexpected block size code $logbs"
  [ "$lastmount" = "$EXPECT_LASTMOUNT" ] || die "last-mounted '$lastmount' != $EXPECT_LASTMOUNT"
}

guard_not_in_use() {   # partition must be free: not mounted, no md/lvm holder
  local p; p=$(part_node)
  [ -b "$p" ] || return 0
  [ -z "$(lsblk -no MOUNTPOINT "$p")" ] || die "$p is mounted - umount it first"
  [ -z "$(ls -A "/sys/class/block/$(basename "$p")/holders" 2>/dev/null)" ] \
     || die "$p is held by md/lvm - stop that first (mdadm --stop ...)"
  grep -q "$(basename "$p")" /proc/mdstat 2>/dev/null && die "$(basename "$p") appears in /proc/mdstat"
  return 0
}

# Current partition 1 start sector, via the GPT (works before and after repartition)
part1_start() { sgdisk -i 1 "$DEV" | awk -F'[ :]+' '/^First sector/{print $3}'; }

guard_gpt_pre()  { [ "$(part1_start)" = "$OLD_PART_START" ] || die "part1 start != $OLD_PART_START (already changed?)"; }
guard_gpt_post() { [ "$(part1_start)" = "$NEW_PART_START" ] || die "part1 start != $NEW_PART_START (repartition did not take)"; }

common_guards() { guard_root; guard_tools; guard_is_disk; guard_disk_size; guard_right_disk; }

confirm() {   # require typing an exact word, no silent y/N default
  local want=$1 got
  read -r -p "Type '$want' to proceed: " got
  [ "$got" = "$want" ] || die "not confirmed"
}

# --- commands -------------------------------------------------------------

cmd_verify() {   # read-only: prove identity and print the plan
  common_guards
  echo "Disk:            $DEV ($EXPECT_DISK_SECTORS sectors, 8 TB)"
  echo "GPT usable max:  $(sgdisk -p "$DEV" | awk '/usable sector is/{print $(NF)}') (expect $EXPECT_USABLE_MAX_LBA)"
  echo "Partition 1 now: start $(part1_start) (expect $OLD_PART_START)"
  echo "ext4 anchor:     magic+UUID+/pixxiodata confirmed at abs sector $FS_SB_SECTOR"
  echo
  echo "PLAN: delete part 1, recreate as start=$NEW_PART_START end=$NEW_PART_END (type 8300),"
  echo "      then e2fsck + resize2fs. ext4 data at sector $NEW_PART_START is never touched."
  echo "OK to proceed to 'backup'."
}

cmd_backup() {   # dump the current GPT so we can restore it later
  common_guards
  sgdisk --backup="$BACKUP_GPT" "$DEV"
  sfdisk -d "$DEV" > "${BACKUP_GPT}.sfdisk"
  note "GPT saved to $BACKUP_GPT (+ .sfdisk)"
}

cmd_repartition() {   # the only step that rewrites the partition table
  common_guards
  guard_not_in_use
  guard_gpt_pre
  [ "$(part1_start)" = "$OLD_PART_START" ] || die "unexpected start"
  [ -f "$BACKUP_GPT" ] || cmd_backup     # never repartition without a GPT backup
  echo "About to DELETE partition 1 and recreate it at sector $NEW_PART_START on $DEV."
  echo "Data (ext4 at sector $NEW_PART_START) is NOT moved. GPT backup: $BACKUP_GPT"
  confirm "REPARTITION"
  sgdisk --delete=1 "$DEV"                                           # drop the old md-member entry
  sgdisk --new=1:${NEW_PART_START}:${NEW_PART_END} \
         --typecode=1:8300 --change-name=1:pixxiodata "$DEV"         # new plain Linux-fs partition
  partprobe "$DEV"; sleep 1                                          # make the kernel re-read the table
  guard_gpt_post                                                     # start must now be 264192
  guard_right_disk                                                   # ext4 must still be intact & now at partition offset 0
  note "partition 1 recreated: $(part_node) starts at $NEW_PART_START"
}

cmd_fsck() {   # verify the ext4 now that it lives at partition offset 0
  common_guards; guard_gpt_post
  e2fsck -f "$(part_node)"
}

cmd_mountcheck() {   # read-only peek before the irreversible grow
  common_guards; guard_gpt_post
  local p mp; p=$(part_node); mp=$(mktemp -d)
  mount -o ro "$p" "$mp"                 # read-only: cannot change anything
  echo "--- df ---"; df -h "$mp"
  echo "--- top level ---"; ls -la "$mp"
  umount "$mp"; rmdir "$mp"
  note "read-only mount OK. If this looks right, proceed to 'resize'."
}

cmd_resize() {   # grow ext4 into the full partition - after this, rollback is unsafe
  common_guards; guard_gpt_post
  local p; p=$(part_node)
  e2fsck -f "$p"                         # resize2fs insists on a clean fs
  echo "This grows ext4 on $p to ~$(( (NEW_PART_END - NEW_PART_START + 1) / 8 / 1024 / 1024 )) Mi blocks and is NOT easily reversible."
  confirm "GROW"
  resize2fs "$p"                         # extend the filesystem to the partition end
  dumpe2fs -h "$p" | grep -E 'Block count|Free blocks'
  echo "New fs UUID for /etc/fstab:"; blkid "$p"
}

cmd_rollback() {   # restore the original GPT - refuses once the fs has grown
  common_guards
  local p blocks; p=$(part_node)
  if [ -b "$p" ]; then
    blocks=$(dumpe2fs -h "$p" 2>/dev/null | awk -F: '/Block count/{print $2+0}')
    [ -n "$blocks" ] && [ "$blocks" -gt "$ORIG_FS_BLOCKS" ] \
      && die "fs already grown ($blocks > $ORIG_FS_BLOCKS) - restoring old GPT would corrupt it"
  fi
  [ -f "$BACKUP_GPT" ] || die "no backup at $BACKUP_GPT"
  confirm "ROLLBACK"
  sgdisk --load-backup="$BACKUP_GPT" "$DEV"   # put the original partition table back
  partprobe "$DEV"
  note "original GPT restored from $BACKUP_GPT"
}

# --- dispatch -------------------------------------------------------------
[ -n "$DEV" ] || die "usage: $0 {verify|backup|repartition|fsck|mountcheck|resize|rollback} /dev/sdX"
case "${1:-}" in
  verify)      cmd_verify ;;
  backup)      cmd_backup ;;
  repartition) cmd_repartition ;;
  fsck)        cmd_fsck ;;
  mountcheck)  cmd_mountcheck ;;
  resize)      cmd_resize ;;
  rollback)    cmd_rollback ;;
  *) die "unknown command '${1:-}'" ;;
esac
