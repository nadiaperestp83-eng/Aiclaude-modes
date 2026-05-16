# macOS Recovery Patterns

Load this when responding to "my drive is dying", filesystem corruption, boot configuration damage, or any destructive operation. These procedures have to be right the first time — getting them wrong destroys data.

## Contents

1. [Cardinal rules](#cardinal-rules) — never bend
2. [Failing-drive data recovery](#failing-drive-data-recovery)
3. [APFS verification + repair](#apfs-verification--repair)
4. [Snapshot rollback](#snapshot-rollback)
5. [Target disk mode / share disk mode](#target-disk-mode--share-disk-mode)
6. [Boot recovery (recoveryOS, safe mode, single-user)](#boot-recovery)
7. [Drive removal procedures](#drive-removal-procedures)
8. [Reinstalling macOS without losing data](#reinstalling-macos-without-losing-data)

## Cardinal rules

These never bend:

1. **Image first, repair second.** Priority is getting data OFF a failing drive before doing anything that writes TO it.
2. **Never `fsck_apfs -y`.** The `-y` flag answers Yes to repairs, which writes back. Read-only verify (`fsck_apfs -n` or `diskutil verifyVolume`) is fine; anything that writes is not.
3. **Never `diskutil eraseDisk` or `format`** on a drive you want data from.
4. **Don't trust `diskutil info` SMART "Verified"** when `log show` is full of IO errors. The log is the truth.
5. **Don't pound a failing drive with retries.** Default rsync retries each error; we use `--partial --inplace --no-whole-file --append-verify --ignore-errors` to skip past unreadable sectors fast.
6. **APFS Snapshots are read-only and free** — use them aggressively before destructive operations. `tmutil localsnapshot /` makes one in under a second.

## Failing-drive data recovery

### Strategy 1: rsync (default — handles most failing drives)

```bash
# Resumable, skips errors, preserves metadata
rsync -avh --partial --inplace --no-whole-file --append-verify --ignore-errors \
    --info=progress2 \
    /Volumes/Failing/important/ /Volumes/Rescue/important/
```

- `--partial` — keep partially-transferred files (allows resume)
- `--inplace` — write directly to destination (don't double-buffer)
- `--no-whole-file` — block-level transfer (skip already-copied portions)
- `--append-verify` — when resuming, verify the existing portion first
- `--ignore-errors` — keep going on individual file failures

Exit codes 23-24 indicate "some files failed" — expected on a failing drive. Run again later to retry just the failures.

### Strategy 2: ditto (when metadata matters)

```bash
ditto --rsrc --extattr /Volumes/Failing /Volumes/Rescue
```

macOS-native, preserves resource forks, xattrs, ACLs, and Finder metadata. Use for:
- Final Cut Pro libraries (`.fcpbundle`)
- Logic Pro projects
- Photos libraries
- Apps that depend on resource forks

`ditto` does NOT have a resume mode like rsync, but it's a single-pass syscall-level copy that's fast on healthy data.

### Strategy 3: ddrescue (last resort, bit-level)

For drives with many bad sectors or filesystem corruption so severe rsync can't traverse the tree:

```bash
brew install gddrescue
ddrescue -n --idirect /dev/disk2 /Volumes/Rescue/disk2.img /Volumes/Rescue/disk2.map
```

`-n` = no scraping (skip retries for now)
`--idirect` = bypass OS cache, talk directly to device

The `.map` file records what's been recovered, allowing resume. After the first pass:

```bash
# Second pass: scrape bad areas more aggressively
ddrescue -r3 /dev/disk2 /Volumes/Rescue/disk2.img /Volumes/Rescue/disk2.map
```

Once you have the image, mount it (`hdiutil attach /Volumes/Rescue/disk2.img`) and extract files from the read-only mount.

## APFS verification + repair

### Verify (always safe)

```bash
diskutil verifyVolume /                # Verify boot volume (read-only)
diskutil verifyDisk disk2              # Verify whole disk
fsck_apfs -n /dev/disk2s1              # Lowest-level verify (no writes)
```

### Repair (destructive — image first!)

```bash
diskutil repairVolume /Volumes/Foo     # Writes to disk — only on healthy storage
fsck_apfs -y /dev/disk2s1              # Forbidden on failing drives
```

`fsck_apfs -y` requires the volume to be **unmounted**. The system volume can be unmounted from recoveryOS only.

### When `repairVolume` is appropriate

Run it when:
- Volume verifies as faulty AND
- The underlying disk has zero SMART errors AND
- The unified log has zero IO errors AND
- You have a backup OR you've imaged the drive first

If any of those preconditions fails, **image first**.

## Snapshot rollback

APFS snapshots are read-only filesystem states. Two flavors:

### Local Time Machine snapshots

Created automatically when TM is enabled. Roll the boot volume back to a specific snapshot:

```bash
# List snapshots
tmutil listlocalsnapshots /

# Roll back (Apple Silicon: requires recoveryOS for boot volume)
# Intel + non-boot volumes:
diskutil apfs revert disk2s1 -toSnapshot com.apple.TimeMachine.2026-05-16-120000.local
```

### Manual snapshots

Take a snapshot before any risky operation:

```bash
tmutil localsnapshot /
# Confirms with "Created local snapshot with date: <name>"
```

If the risky operation goes wrong, revert as above.

### Removing old snapshots

Time Machine local snapshots can consume substantial purgeable space. macOS auto-deletes them under disk pressure, but you can force:

```bash
tmutil deletelocalsnapshots <name>     # specific snapshot
tmutil thinlocalsnapshots /            # all eligible
```

## Target disk mode / share disk mode

Mount one Mac's drives onto another Mac to recover data:

### Apple Silicon (macOS 11+): Share Disk

1. Boot the patient Mac into recoveryOS (hold power button)
2. Utilities → Share Disk
3. Connect via USB-C / Thunderbolt to the helper Mac
4. The patient drive appears on the helper

### Intel: Target Disk Mode

1. Boot the patient Mac while holding `T`
2. Connect via Thunderbolt or FireWire
3. Patient drive appears on the helper

Either method gives you read-write access to the patient's drives without booting macOS on the patient.

## Boot recovery

### recoveryOS

Where most repair work happens:

- **Apple Silicon**: hold power button until "Loading startup options" appears, then "Options"
- **Intel**: hold `Cmd-R` at boot

From recoveryOS you get:
- Disk Utility (verify / repair / partition)
- Reinstall macOS
- Restore from Time Machine
- Terminal (with limited commands — `fsck_apfs`, `diskutil`, `nvram`)

### Safe boot

Boots with minimal kexts, no third-party LaunchAgents, runs filesystem check.

- **Apple Silicon**: hold power, choose volume while holding Shift
- **Intel**: hold Shift at boot

### Single-user mode (Intel only; not on Apple Silicon)

```
Boot with Cmd-S
```

Drops to a root shell before launchd starts. Almost never needed these days; Apple Silicon doesn't support it.

### Verbose boot

Shows kernel/launchd messages instead of the Apple logo:

```bash
sudo nvram boot-args="-v"             # persistent until cleared
sudo nvram -d boot-args                # clear
```

## Drive removal procedures

In order of safety / reversibility:

1. **Software unmount**
   ```bash
   diskutil unmount /Volumes/Foo            # one volume
   diskutil eject /dev/disk2                # whole device (all volumes)
   ```

2. **Set offline** (won't remount until enabled)
   ```bash
   diskutil disableMount /dev/disk2s1
   ```

3. **Physical disconnect** (external) — only after step 1 succeeds

4. **BIOS / firmware disable** (internal) — boot recoveryOS, then physically disconnect

5. **Destruction** — for data on a failed drive you're disposing of: see "Cryptographic erase" below

### Cryptographic erase (FileVault)

If FileVault was on, erasing the volume effectively destroys data:

```bash
diskutil apfs eraseVolume APFS Untitled /Volumes/Foo
```

The previous encryption key is gone, making prior data unrecoverable without it.

## Reinstalling macOS without losing data

Reinstalling macOS over an existing install does NOT delete user data, but **always have a backup**.

1. Boot to recoveryOS
2. Reinstall macOS → choose existing volume
3. Wait (45-90 min)

This restores the OS files only. `/Users/` is untouched. Applications need re-checking — some app helper plists may need re-registration.

## Cross-references

- For storage event interpretation, see `storage-events.md`
- For volume dependency checks before eject, see `scripts/drive-dependencies.sh`
- For safe clone execution, see `scripts/recover-clone.sh`
- For Windows equivalents (BCD repair, bootrec), see `windows-ops/references/recovery-patterns.md`
