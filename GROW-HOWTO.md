# HOWTO: Grow the pixxiodata disk to 8 TB

This document describes how to expand the `pixxiodata` filesystem to fill an
8 TB disk, using one of two scripts. Read the Background and Choosing a Script
sections before running anything.

## Background

The disk is an 8 TB drive (Seagate ST8000VN, 15,628,053,168 sectors of 512
bytes) that was cloned from a smaller 4 TB disk. Its layout:

```
GPT disk (8 TB, usable LBA 34 .. 15,628,053,134)
└── Partition 1  "Linux RAID"   start LBA 2048, end LBA 7,814,037,134 (~4 TB)
    └── Linux md RAID member (metadata 1.2, data offset 262144 sectors)
        └── ext4 filesystem (4 KiB blocks, ~3.3 TB used)
```

Because the member uses md metadata version 1.2, the filesystem does not start
at the beginning of the partition. It starts `data_offset` sectors later:

```
partition start (2048) + data_offset (262144) = 264192   <- ext4 block 0
264192 + 2 = 264194                                       <- ext4 primary superblock
```

The GPT already describes the full 8 TB (usable max LBA 15,628,053,134); only
the partition entry is still 4 TB. The goal is to use the remaining ~4 TB.

### Important findings about this disk

- The md **bitmap** superblock exists (disk sector 2064), but the **main** md
  array superblock (expected at disk sector 2056, 4 KiB into the partition) is
  zeroed. The md magic `0xA92B4EFC` is not present near the start of the disk.
- Consequence: this clone has **no assemblable md array**. The approach that
  keeps the RAID (Script B) can only proceed by *recreating* the md metadata,
  which is the most dangerous operation of the two.

### Filesystem identity (used by both scripts as a safety anchor)

| Property            | Value                                    |
|---------------------|------------------------------------------|
| ext4 magic          | `0x53EF`                                 |
| ext4 UUID           | `ffbabced-b943-4916-9067-96d77058d416`   |
| Last mount point    | `/pixxiodata`                            |
| Block size          | 4096 bytes                               |
| Block count (before)| 819,331,072                              |

Both scripts read the ext4 superblock directly off the disk and refuse to run
unless this identity matches. This prevents operating on the wrong drive even
if the device name differs on the target machine.

## Choosing a script

| | Script A: `grow-pixxiodata.sh` | Script B: `grow-md-pixxiodata.sh` |
|---|---|---|
| Result | Plain ext4 partition, no md | ext4 inside a (degraded) md array |
| Partition start | Moves to 264192 | Stays at 2048 |
| Touches md metadata | No (left inert in a 128 MiB gap) | Yes (must recreate it) |
| Works on this clone | Yes, directly | Only via the `recreate` step |
| Data moved | None | None |
| Recommended | **Yes** | Only if an md device is required |

**Recommendation: use Script A.** On this clone the md array cannot be
assembled, so Script B achieves the same filesystem growth but requires
rebuilding RAID metadata — more risk for no benefit, unless something external
specifically needs a `/dev/md*` device.

Neither script moves file data. Both change only the partition table and, at the
end, grow the filesystem.

## Prerequisites

- Target machine running Debian Linux.
- Run as **root** (`sudo -i`).
- Required packages: `gdisk`, `parted`, `e2fsprogs`, `util-linux`, `mdadm`
  (Script B only). Install with:
  ```
  apt install gdisk parted e2fsprogs util-linux mdadm
  ```
- The disk attached and **not in use**: the partition must not be mounted, and
  any auto-assembled md array on it must be stopped (`mdadm --stop /dev/mdN`).
- A current backup of the data. The operations are designed to be safe and
  reversible up to the final resize, but a backup is mandatory.

In the examples below, `/dev/sdX` is the whole-disk device (for example
`/dev/sdb`, or `/dev/nvme0n1`). Always pass the whole disk, never a partition.

Confirm the device first:
```
lsblk -o NAME,SIZE,TYPE,MODEL
```
Then make the chosen script executable:
```
chmod +x grow-pixxiodata.sh grow-md-pixxiodata.sh
```

---

## Script A — grow-pixxiodata.sh (recommended)

Converts the partition into a plain ext4 partition by redefining partition 1 to
start where the filesystem physically begins (sector 264192), then grows ext4 to
fill the disk. The md metadata is never written to; it remains in the unused
1 MiB..129 MiB region.

### Steps

Run one command at a time and review the output before continuing.

1. **verify** (read-only): prints the plan and confirms the disk identity.
   ```
   ./grow-pixxiodata.sh verify /dev/sdX
   ```

2. **backup**: saves the current GPT to `/root/<disk>.gpt.bak` (and an `sfdisk`
   dump). Required before any table change.
   ```
   ./grow-pixxiodata.sh backup /dev/sdX
   ```

3. **repartition** (writes the table): deletes partition 1 and recreates it at
   start 264192, end 15,628,053,134, type `8300`. Requires typing
   `REPARTITION`. Auto-creates a GPT backup if one is missing.
   ```
   ./grow-pixxiodata.sh repartition /dev/sdX
   ```

4. **fsck**: checks the ext4 filesystem, now located at offset 0 of the new
   partition.
   ```
   ./grow-pixxiodata.sh fsck /dev/sdX
   ```

5. **mountcheck** (read-only): mounts the partition read-only, prints `df` and
   the top-level directory, then unmounts. Use this to confirm the data is
   intact before the irreversible step.
   ```
   ./grow-pixxiodata.sh mountcheck /dev/sdX
   ```

6. **resize**: grows ext4 to fill the partition (~1.95 billion 4 KiB blocks,
   below the 16 TiB non-64bit limit). Requires typing `GROW`. After this,
   rollback is no longer safe.
   ```
   ./grow-pixxiodata.sh resize /dev/sdX
   ```

### Rollback (Script A)

Valid only **before** the `resize` step. Restores the original GPT from the
backup; the old partition and the on-disk md metadata are untouched, so the
original state returns.
```
./grow-pixxiodata.sh rollback /dev/sdX
```
The command refuses to run if it detects the filesystem has already been grown
(block count above 819,331,072), because restoring the old 4 TB partition over a
larger filesystem would corrupt it.

### After Script A

The old `/dev/md*` device no longer applies. Mount the partition directly.

1. Get the filesystem UUID (printed by `resize`, or):
   ```
   blkid /dev/sdX1
   ```
2. Update `/etc/fstab` to mount by UUID, and remove any `/dev/md*` line:
   ```
   UUID=ffbabced-b943-4916-9067-96d77058d416  /pixxiodata  ext4  defaults  0 2
   ```
3. Remove any `ARRAY` line for this disk from `/etc/mdadm/mdadm.conf`, then
   `update-initramfs -u` so nothing tries to assemble the old array at boot.

### Optional cleanup

The stale md superblock and bitmap remain in the unallocated 1 MiB..129 MiB gap.
They are harmless (an unpartitioned gap is not scanned for arrays). If you want
them gone, after everything is verified:
```
dd if=/dev/zero of=/dev/sdX bs=1M seek=1 count=128 conv=notrunc
```
This wipes only the gap and stops before sector 264192. Run it only after you are
satisfied, as it removes the ability to reconstruct the old array.

---

## Script B — grow-md-pixxiodata.sh (keeps the RAID)

Keeps the md layer. The partition start stays at 2048; the partition end is
extended, then the array and filesystem are grown. On this clone the array has
no superblock, so the `recreate` step is required to rebuild md metadata before
the array can be grown.

The md device name defaults to `/dev/md0`. Override with the `MD` environment
variable, for example `MD=/dev/md5 ./grow-md-pixxiodata.sh ...`.

### Steps

1. **verify** (read-only): prints the layout and runs `mdadm --examine` so you
   can see whether a superblock exists.
   ```
   ./grow-md-pixxiodata.sh verify /dev/sdX
   ```
   If `--examine` reports no superblock or bad magic, `assemble` will fail and
   you must use `recreate`.

2. **growpart** (writes the table): extends partition 1 to end sector
   15,628,053,134 while keeping the start at 2048. Backs up the GPT first.
   Requires typing `GROWPART`.
   ```
   ./grow-md-pixxiodata.sh growpart /dev/sdX
   ```

3. **assemble**: starts the existing array as `/dev/md0`.
   ```
   ./grow-md-pixxiodata.sh assemble /dev/sdX
   ```
   On this clone this step **fails** (missing superblock). Proceed to `recreate`.

4. **recreate** (dangerous; only if `assemble` failed): rebuilds a degraded
   raid1 superblock on the member with `data_offset=262144`. Requires typing
   `RECREATE-MD-I-HAVE-BACKUPS`. After creating, it reads back the actual data
   offset and confirms ext4 reappears at `/dev/md0` offset 1024. If either check
   fails, it stops the array, zeroes the superblock it just wrote, and aborts
   without touching the data region.
   ```
   ./grow-md-pixxiodata.sh recreate /dev/sdX
   ```

5. **grow**: expands the array to use the enlarged partition.
   ```
   ./grow-md-pixxiodata.sh grow /dev/sdX
   ```

6. **resize**: checks and grows ext4 on the md device. Requires typing
   `GROW-FS`.
   ```
   ./grow-md-pixxiodata.sh resize /dev/sdX
   ```

Helpers:
```
./grow-md-pixxiodata.sh status /dev/sdX    # /proc/mdstat and mdadm --detail
./grow-md-pixxiodata.sh stop   /dev/sdX    # mdadm --stop /dev/md0
```

### data_offset unit caveat (recreate)

mdadm's unit for `--data-offset` has differed between versions. The script
requests `CREATE_DATA_OFFSET=262144` and then verifies the result. If `recreate`
aborts reporting an unexpected data offset (for example a very large number), the
unit was interpreted differently; edit `CREATE_DATA_OFFSET` near the top of the
script (try `128M`) and run `recreate` again. A mismatch is caught before any
data is affected — `mdadm --create` with `--assume-clean --bitmap=none` writes
only front-of-device metadata, which the script then removes on failure.

### After Script B

The filesystem is on the md device. Mount by the array device or the ext4 UUID,
and ensure `/etc/mdadm/mdadm.conf` has a correct `ARRAY` line so the array
assembles at boot, then `update-initramfs -u`.

---

## Verified constants (reference)

These values were read from the disk (read-only) and are hard-coded in both
scripts as safety checks. Do not change them unless the disk changes.

| Constant                | Value           | Meaning                                  |
|-------------------------|-----------------|------------------------------------------|
| Disk size               | 15,628,053,168  | total sectors (8 TB)                     |
| GPT usable max LBA      | 15,628,053,134  | last usable sector (new partition end)   |
| Partition 1 start       | 2048            | unchanged in B; replaced in A            |
| Partition 1 end (old)   | 7,814,037,134   | current ~4 TB end                        |
| data_offset             | 262144          | md 1.2 offset, in sectors                |
| New partition start (A) | 264192          | 2048 + 262144                            |
| ext4 superblock sector  | 264194          | absolute, on the raw disk                |
| ext4 UUID               | `ffbabced-b943-4916-9067-96d77058d416` | identity anchor    |
| ext4 block count (old)  | 819,331,072     | used by rollback guard                   |

## Troubleshooting

- **"not a whole disk" / "disk size mismatch"**: you passed a partition, or the
  wrong drive. Pass the whole-disk device; confirm with `lsblk`.
- **"NOT the pixxiodata disk" / UUID mismatch**: the ext4 identity at sector
  264194 did not match. Wrong disk, or the disk changed. Do not override; stop
  and investigate.
- **"is mounted" / "held by md/lvm"**: unmount the partition and stop any md
  array using it, then retry.
- **repartition/growpart: start assertion fails**: the partition table is not in
  the expected pre-state. Run `verify` and compare against the constants table.
- **Script B assemble fails**: expected on this clone. Use `recreate`.
- **resize2fs refuses**: run the script's `fsck`/`resize` step, which runs
  `e2fsck -f` first; resize2fs requires a clean filesystem.
