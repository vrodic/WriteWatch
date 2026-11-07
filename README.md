# WriteWatch

**See exactly what's writing to your Mac's SSD: which apps, which files, and how fast.**

Your Mac writes to its SSD all day, and Activity Monitor can't tell you what's going into which file. WriteWatch shows you live, in a fast native app with no dependencies, and it checks your drive's health too.

![WriteWatch showing the apps and files writing the most to disk](docs/screenshot.png)

*Replay of a real 16-minute capture's large writes, with 963 MB of RAM disk writes kept out of the disk rankings.*

## Find out what's really writing

- **Live write rate:** current speed, a rolling 2-minute chart, the peak, and totals for the capture and since boot.
- **Top apps and files:** ranked by bytes written, updated every second, so a noisy app or a file being rewritten over and over stands out right away.
- **Large-writes log:** every write above a size you choose, from 4 KB to 16 MB, with the time, size, app and full path.
- **SSD health:** wear, spare capacity, media errors, temperature and lifetime totals, read directly from the drive with no `smartctl` required.
- **CSV export:** save the log or the totals whenever you want.

## It gets the blame right

Most tools tell you which process issued a write. That can point you at the wrong culprit, and WriteWatch was built to look past it.

**launchd gets blamed for everyone's writes.** On the Mac this was built on, `launchd` had been charged with 23.9 GB of writes since boot, the most of any process. Nearly all of what it wrote during a trace went to other programs' files, in a burst exactly every 30 seconds. WriteWatch credits those writes to the program that owns the file, working from who else wrote it and where it lives. It's a best guess, so the log always shows the process that issued the write too, and anything unclear is labeled as unattributed.

**RAM disks aren't your SSD.** In one real capture, StarCraft II looked like the biggest writer by far, with 965 MB logged. But 963 MB of that went to a RAM disk, and only 1.6 MB went anywhere else. WriteWatch asks macOS how each device is backed, so it spots RAM disks whatever they're named, gives them their own tab, and keeps them out of your disk rankings.

## Your capture stays in memory

Captures are held in RAM and go to disk only when you press Save. A disk-write monitor shouldn't add to the problem.

## Get started

You'll need macOS 13 or later and Xcode or its Command Line Tools. Build and open it:

```bash
./build.sh
```

```bash
open WriteWatch.app
```

The build is signed for your own Mac, and so far it's only been tested on one Apple Silicon machine.

## Permissions

WriteWatch asks for your administrator password when it opens, because per-file tracing uses `fs_usage`, which requires root. You can decline and still use part of the app:

| | With password | Without |
|---|---|---|
| Live write rate and disk totals | Yes | Yes |
| SSD health | Yes | Yes |
| Top apps | All processes | Your own processes |
| Top files and large-writes log | Yes | No |
| RAM disk separation | Yes | No |

A small helper runs as root only while the app is open. It does just one thing, relaying `fs_usage` output to the app over a local connection, and it exits when the app quits. Nothing stays installed, so the app asks each time you open it. For regular use, keep the app somewhere only administrators can write, such as `/Applications`, because the helper runs from inside the app bundle.

## Good to know

- **Memory:** `fs_usage` is memory-hungry, starting around 500 MB. WriteWatch restarts it past 1.5 GB, which misses a moment of writes, and tells you when that happens.
- **Process names:** `fs_usage` cuts them to 16 characters.
- **One trace at a time:** a capture can fail if another tool is using the kernel trace facility.
- **Wear figures:** the drive reports these itself, and how they're counted varies by manufacturer.
- **Drives:** the live rate and health stats cover the first SMART-capable NVMe drive.

## Under the hood

| Path | Contents |
|---|---|
| `Sources/WriteWatch` | AppKit app: window, charts, monitors, helper connection |
| `Sources/WriteWatchHelper` | The root helper |
| `Sources/WriteWatchCore` | `fs_usage` parser, write attribution, in-memory store, health verdicts |
| `Sources/CNVMeSMART` | C wrapper around IOKit's NVMe SMART interface |
| `Tests/WriteWatchCoreTests` | Unit tests, run with `swift test` |
