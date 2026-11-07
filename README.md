# WriteWatch

A small native macOS app that shows what is writing to your SSD: which apps, which files, and how fast. It also reads the drive's health directly, with no third-party tools.

Captures stay in memory until you choose to save them.

## Features

- **Live write rate:** current speed, a 2-minute chart, the peak, and totals for the capture and since boot, from the drive's IOKit counters.
- **Top writers:** apps and files ranked by bytes written.
- **Large-writes log:** every write at or above a threshold you set, from 4 KB to 16 MB. It keeps the newest 200,000 entries.
- **SSD health:** wear, spare capacity, media errors, temperature and lifetime totals, read from the drive's NVMe SMART log without `smartctl`.
- **CSV export:** save the log or the app and file totals to a file you choose.

## Why launchd isn't at the top

macOS tools often show `launchd` as a major disk writer. On the Mac this was built on, launchd issued a burst of writes exactly every 30 seconds, and nearly all of them went to other programs' files. That looks like a periodic flush of pending data, with launchd charged for the I/O.

WriteWatch credits those writes to the program that was seen writing the same file, or failing that, to whatever the file's path suggests. This is a best guess. Anything unclear is listed as "Unattributed (flushed by launchd)", and the log shows both the credited app and the process that issued the write.

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools, to build
- An administrator password, for per-file tracing
- An NVMe SSD, for the drive-specific stats

It has only been tested on one Apple Silicon Mac.

## Build and run

```bash
./build.sh
```

```bash
open WriteWatch.app
```

The build is signed ad hoc, so it's meant to run on the Mac that built it.

To run the tests:

```bash
swift test
```

## Permissions

At launch, the app asks for an administrator password through the standard macOS prompt.

| | With administrator access | Without it |
|---|---|---|
| Live rate and disk totals | Yes | Yes |
| SSD health | Yes | Yes |
| Apps ranked by writes | All processes | Your own processes only |
| Files ranked and large-writes log | Yes | No |

Per-file data comes from `fs_usage`, which requires root. A minimal helper, `WriteWatchHelper`, runs as root only while the app is open. It can start and stop one fixed `fs_usage` command and sends the output to the app over a loopback connection. It creates no files, and it exits when the connection closes. Nothing is installed permanently, so the app asks for the password on each launch.

The helper runs from inside the app bundle. A program running under your account could replace it before you approve the prompt, so for regular use, keep the app somewhere only administrators can write, such as `/Applications`.

## What gets written to disk

WriteWatch's own code writes only when you press Save. Window restoration, saved preferences and toolbar autosave are all turned off.

macOS frameworks still write a little on the app's behalf:

- **Metal shader cache:** small index files on launch, and roughly 50 to 140 KB of shader data after a new build, in the app's cache folder.
- **Preferences file:** a 762-byte file that appears to come from opening the Save panel.

A tile in the app shows its own disk writes, including flushes of its own files seen while tracing.

## Limitations

- **Memory:** `fs_usage` starts at about 500 MB and grows. The helper restarts it past 1.5 GB, at most once a minute, and the app shows how many restarts happened. Each restart misses a moment of writes.
- **Process names:** `fs_usage` cuts them to 16 characters, so you may see names like `searchpartyusera`.
- **Other tracing tools:** the capture can fail if another tool is using the kernel trace facility.
- **Drive-reported figures:** wear and power-on time are reported by the drive, and how they're counted varies by manufacturer. Time asleep may not count as powered on, which can inflate the per-day figure.
- **Non-NVMe drives:** the live rate and SSD health only read the first SMART-capable NVMe drive.

## Project layout

| Path | Contents |
|---|---|
| `Sources/WriteWatch` | AppKit app: window, charts, monitors, helper connection |
| `Sources/WriteWatchHelper` | The root helper |
| `Sources/WriteWatchCore` | `fs_usage` parser, write attribution, in-memory store, health verdicts |
| `Sources/CNVMeSMART` | C wrapper around IOKit's NVMe SMART interface |
| `Tests/WriteWatchCoreTests` | Unit tests |
