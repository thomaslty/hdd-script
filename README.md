# hdd-burnin

End-to-end burn-in for new/large HDDs (tested for 28 TB drives).
Bundles install + parallel launch + live status + pass/fail summary in a single script.

Inspired by [Spearfoot/disk-burnin-and-testing](https://github.com/Spearfoot/disk-burnin-and-testing)
and [ezonakiusagi/bht](https://github.com/ezonakiusagi/bht), but designed to be a
one-shot: you run one command, walk away for a week, and come back to a summary.

## What it does (per drive, in parallel)

1. Baseline full SMART dump (`smartctl -x`)
2. SMART **short** self-test (~2 min)
3. SMART **long** self-test (~1–2 days on 28 TB)
4. `badblocks -wsv` destructive 4-pattern write+verify (~4–7 days on 28 TB)
5. SMART **long** self-test again (to compare post-stress)
6. Final SMART dump + diff

A PASS/FAIL table is printed at the end. Any drive with non-zero
`Reallocated_Sector_Ct`, `Current_Pending_Sector`, `Offline_Uncorrectable`, or
badblocks errors is marked FAIL and should go back for RMA.

## Total time for 4× 28 TB in parallel

~**8–10 days**. SMART tests run on the drive firmware itself, so they don't slow each other down. badblocks is bandwidth-bound per drive; running 4 in parallel on one SATA controller is fine as long as the HBA and PSU can handle it.

## Proxmox VM setup

1. **Passthrough the SATA controller**: add the PCI device in the VM hardware
   tab, tick "All Functions" and "PCI-Express", leave "Primary GPU" unchecked.
2. **Install a minimal Debian/Ubuntu VM** (2 vCPU, 4–8 GB RAM is plenty —
   badblocks is not CPU-bound).
3. **Pass the drives through the controller, not one-by-one** — direct
   controller passthrough gives real SMART access, whereas `qm set ... -scsiX
   /dev/disk/by-id/...` does not.
4. Inside the VM, `lsblk` should show your 4 new drives as `sda`..`sdd` (or
   similar) and **nothing else** should be on that controller.

## Usage

```bash
# Copy the script to the VM, then:
chmod +x hdd-burnin.sh
sudo ./hdd-burnin.sh --help

# 1. DRY-RUN first to see what it will do (prints commands, runs nothing destructive):
sudo ./hdd-burnin.sh /dev/sdb /dev/sdc /dev/sdd /dev/sde

# 2. Actual destructive run in tmux/screen (so SSH disconnects don't kill it):
tmux new -s burnin
sudo ./hdd-burnin.sh -f /dev/sdb /dev/sdc /dev/sdd /dev/sde
#   → type ERASE to confirm
#   ^B d to detach from tmux

# 3. From any terminal, check progress:
sudo ./hdd-burnin.sh status

# 4. When it's done, get the result:
sudo ./hdd-burnin.sh result
```

## Output

Everything goes to `/var/log/hdd-burnin/` (configurable with `-o`):

```
/var/log/hdd-burnin/
├── burnin_SEAGATE_EXOS_ZT8000ABC.log        # full per-drive log (all 6 stages)
├── badblocks_SEAGATE_EXOS_ZT8000ABC.log     # any bad block LBAs found (empty = good)
├── state_SEAGATE_EXOS_ZT8000ABC             # current stage (for `status` command)
└── .pids                                    # worker PIDs
```

## What to look for in the summary

A clean drive shows:

```
DRIVE                               RESULT     REALLOC      PENDING      UNCORREC     BB_ERRORS
SEAGATE_EXOS_ZT8000ABC              PASS       0            0            0            0
```

**Any** non-zero value → investigate. On a brand-new drive, the correct answer is
almost always RMA — you want zeros across the board before trusting 28 TB of
storage to it.

## Notes on large drives (16 TB+)

`badblocks` uses 32-bit block counters. With the default 1024-byte blocks, you
run out of addressable blocks around 4 TB. With 4096 bytes, around 16 TB. The
script defaults to `-b 8192`, good up to 32 TB. For future 36 TB+ drives use
`-b 16384`.

## Why also `fio`?

The script uses `badblocks -wsv` which is the community-standard burn-in (4 write
patterns: 0xaa, 0x55, 0xff, 0x00, each followed by verify read). If you also want
performance characterization, run `fio` separately afterward — but badblocks is
enough to catch the failure modes burn-in is meant to catch (infant mortality,
bad sectors, firmware issues under sustained write load).

## Safety features

- Dry-run by default. You must pass `-f` to do anything destructive.
- Refuses to touch any drive with an active mount or the root filesystem.
- Requires you to type `ERASE` to confirm before starting.
- Skips NVMe devices in `--auto` mode (this script is for SATA/SAS HDDs).
