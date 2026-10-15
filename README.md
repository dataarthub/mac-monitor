# Mac Monitor

A native macOS menu bar app for monitoring **CPU and GPU activity, memory pressure and usage, internal SSD capacity, and external SSD capacity and SMART health**. Choose a primary value for each section in the menu bar, then click to see the breakdown and recent history in a four-card dashboard.

The app supports Japanese and English, configurable refresh intervals, and per-section menu-bar visibility. It is built with Swift, SwiftUI, AppKit, and a small C metrics reader for Apple Silicon Macs running macOS 14 or later. Choose a connected external SSD in settings, regardless of its model. Capacity monitoring works without SMART; temperature and health details depend on the drive, enclosure, and diagnostic tool. CPU, GPU, memory, and internal storage monitoring work independently of external drives.

[日本語の説明](README.ja.md)

## Start using the app

### Download and installation

1. Download `MacMonitor.zip` from [Releases](https://github.com/dataarthub/mac-monitor/releases).
2. Unzip and drag `MacMonitor.app` into your `/Applications` folder.

> [!NOTE]
> **Bypassing macOS Gatekeeper (ad-hoc signing)**
> Because this open-source build uses ad-hoc signing (`codesign --sign -`) rather than an Apple Developer ID certificate, macOS may block launch with a message such as *"MacMonitor cannot be opened because the developer cannot be verified"* or *"Apple could not verify it is free of malware"*.
> - **Method 1 (Finder)**: Right-click (or Control-click) `MacMonitor.app`, select **Open**, and click **Open** in the dialog.
> - **Method 2 (System Settings)**: Open **System Settings** > **Privacy & Security**, scroll down to the Security section, and click **Open Anyway**.
> - **Method 3 (Terminal)**: Remove the quarantine attribute by running:
>   ```sh
>   xattr -cr /Applications/MacMonitor.app
>   ```

### Launch and navigation

Double-click `MacMonitor.app`. Click its menu bar item to open or close the dashboard. The gear at the top right opens settings; **Close** dismisses settings, and **Quit** in the dashboard footer exits the app.

| Section | Dashboard information |
|---|---|
| CPU & GPU | CPU utilization and user/system/idle breakdown, CPU model and core configuration, 1/5/15-minute load averages, GPU overall/renderer/tiler utilization, and separate CPU/GPU history charts |
| Memory | macOS memory pressure, used/total memory and utilization, app/wired/compressed memory, estimated cache, swap usage, and utilization history |
| Internal SSD | Total/estimated used capacity, utilization, actual free space, available capacity including reclaimable storage, estimated purgeable capacity, filesystem/volume name, and free-space change/history |
| External SSD | Used/free/total capacity and utilization, included volumes, current/session-peak temperature, cumulative host reads/writes, endurance consumption, spare capacity, power-on hours, unsafe shutdowns, media errors, critical warnings, SMART health, and update time |

Menu bar icons and values use green, orange, or red to indicate the corresponding monitoring state; unavailable readings appear gray. Blue contextual values in the dashboard are informational. Hover over menu bar values for their names and warnings, or dashboard rows for explanations.

## Settings

Changes apply immediately and are saved in the app's `UserDefaults` for the next launch.

### Language and primary values

Choose **Automatic (follow macOS)**, **日本語**, or **English**. Automatic uses Japanese when the first preferred macOS language is Japanese, otherwise English. The language setting affects this app's labels, help, alerts, and errors.

Each section can show one primary value. The same value appears in the menu bar and at the top of its dashboard card.

| Section | Available primary values | Default |
|---|---|---|
| CPU & GPU | CPU utilization, 1-minute CPU load average, GPU overall/renderer/tiler utilization | CPU utilization |
| Memory | Utilization, used memory, memory pressure, compressed memory, swap used | Utilization |
| Internal SSD | Actual free space, available capacity including reclaimable space, estimated purgeable capacity, estimated used capacity | Actual free space |
| External SSD | Temperature, cumulative host writes/reads, endurance consumed, power-on hours, storage utilization/free/used capacity | Temperature |

**Hide from menu bar** hides a section while retaining its dashboard value and monitoring. Hiding all sections leaves an app icon for opening the dashboard. Monitoring and alerts remain enabled for every section. Missing primary values show `—`.

Menu bar values are left-aligned immediately after their own icons, with reserved space trailing the value. The menu bar keeps each selected metric compact: percentages reserve up to three digits, temperature two digits, and pressure its translated states. Other values use the space actually needed. If a longer value appears, its slot expands only as much as necessary and keeps that width for the rest of the launch, avoiding repeated expansion/contraction. A warning icon takes space only while a warning is active. Changing the metric, language, or visible sections can also change the width.

Selecting a primary value does not change alert criteria or history series. Charts continue to show overall CPU/GPU utilization, memory utilization, actual internal free space, and external SSD temperature.

### External SSD selection

**External SSD to monitor** lists connected external physical drives that macOS reports as SSDs. USB bridges that omit the SSD/HDD classification are included as **SSD type unknown**; explicitly reported HDDs, internal drives, and disk images are excluded. Each choice shows its device name, physical capacity, and current disk identifier. **Rescan** refreshes the list immediately; normal external refreshes also update it.

On first use, the first listed candidate is selected and remembered. Later selections are saved using partition/volume UUIDs, so changing a volume name or receiving a new `diskN` number does not switch the target. An unplugged selection remains listed as disconnected: the app clears its current values and does not take over another drive. Reconnect it or explicitly choose another. Reformatting changes UUIDs and can require reselecting. Media without UUIDs use an IOKit identity limited to the current boot session and may need reselecting after restart. Duplicated identities are treated as ambiguous and are not read automatically.

Changing drives immediately clears the previous drive's readings, session peak, and temperature chart. Results from a read started before the change are discarded. The original primary-value preference stays saved. If that value is unavailable but filesystem capacity is readable, the menu bar and card temporarily show **free space**, with an explanation in the card; the requested value returns when it becomes readable again.

### Refresh intervals and dashboard layout

| Data | Choices | Default |
|---|---|---|
| CPU, GPU, memory, internal capacity | 1 / 2 / 5 / 10 / 30 seconds | 2 seconds |
| External capacity and SMART health | 5 / 15 / 30 / 60 seconds | 15 seconds |

Changing an interval reschedules its timer immediately and clears the affected chart histories. Each chart keeps up to 60 samples in memory, so the default ranges are about two minutes for system metrics and fifteen minutes for external temperature. History is cleared on exit; the app does not write a growing history log. The internal free-space baseline remains the value at app launch. **Refresh now** requests readings independently of the timer. Longer intervals also delay warning detection and recovery updates.

The dashboard is 680 points wide, with cards filling the width inside its margins. The window grows vertically to fit the cards without shrinking their text, within the screen area excluding the menu bar and Dock. The header, status strip, and footer stay fixed; the cards do not scroll. The status strip keeps the same height for normal (green), warning (orange/red), and unavailable (gray) states.

## Colors and warnings

| Metric | Green | Orange | Red |
|---|---|---|---|
| CPU utilization | Below 70% | 70% to below 90% | 90% or higher |
| Memory pressure | macOS normal | macOS warning | macOS critical |
| Actual internal free space | At least 20 GB | 10 GB to below 20 GB | Below 10 GB |
| External SSD temperature | Below 65°C | 65°C to below 70°C | 70°C or higher |

CPU colors indicate workload; its warning icon appears only after utilization stays at or above 90% for 30 seconds. Memory pressure, low internal free space, high external temperature, and SMART issues also produce a warning icon and dashboard message. Warnings clear when their conditions clear. GPU usage, load averages, and external filesystem utilization have no separate alert thresholds.

Memory colors use **macOS pressure regardless of the selected primary value**, rather than a fixed utilization or swap threshold. For example, 90% utilization with a normal OS state produces no memory warning, while 50% with an OS warning state does. The app reads `kern.memorystatus_vm_pressure_level`; its three states differ from Activity Monitor's continuous pressure graph. macOS considers free memory, swap rate, wired memory, and cached memory. [Apple's memory-pressure explanation](https://support.apple.com/guide/activity-monitor/actmntr1004/mac).

SMART critical warnings, nonzero media errors, or a failed SMART health check are highlighted in red independently of temperature. Temperature/free-space thresholds are attention guides, not manufacturer-specific failure limits; CPU load and historical unsafe-shutdown counts alone do not establish a fault.

## Understanding the details

### CPU, GPU, and memory

CPU utilization uses differences in Mach CPU-time counters between samples, normalized to 0–100% across all logical cores. User time includes nice time; user plus system equals overall utilization. One busy core can coexist with low overall usage. Core configuration comes from `sysctl`, and load averages from `getloadavg`. Load averages count running/runnable work rather than percentages and should be read alongside the core count. Per-core meters are omitted from the dashboard; diagnostic output retains per-core data.

GPU statistics come from IOKit's `IOAccelerator` `PerformanceStatistics`. Overall, renderer, and tiler usage describe different processing stages and should not be added together. Availability depends on the Mac and driver; unsupported readings show `—`. If multiple GPUs provide statistics, the app selects the busiest and shows that GPU's breakdown. Overall/renderer/tiler readings were verified on this Mac's Apple M4.

App memory is an estimate of anonymous pages minus purgeable pages. Wired memory must remain in RAM; compressed memory is the RAM occupied by compressed data. Estimated cache is file-backed plus purgeable memory and is shown separately from used memory. Swap usage measures occupied startup-disk storage. These values provide context, can differ from Activity Monitor, and do not identify a warning's specific cause. Memory figures use 1024³-byte units, displayed as GB.

### Internal SSD capacity

The app reads the filesystem at `/System/Volumes/Data`. Total minus actual free space gives estimated used capacity, and used/total gives utilization. APFS volumes share container capacity, so used space includes snapshots and other volumes, rather than only the sum of files on Data. The filesystem format and volume name come from the same volume. Storage capacity uses decimal GB (10⁹ bytes).

**Available capacity** uses macOS `volumeAvailableCapacityForImportantUsage`, including storage the OS expects to reclaim when necessary. **Estimated purgeable capacity** is available capacity minus actual free space, floored at zero. It may include Time Machine local snapshots and caches; it is not a measurement of Time Machine alone or all snapshots, and can differ from Finder. These values follow the configured system refresh interval. Alerts and the history chart use **actual free space**, and the app never triggers deletion.

References: [Apple's capacity API](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage), [Time Machine local snapshots](https://support.apple.com/en-us/102154).

### External SSD capacity and SMART health

Capacity is discovered through `diskutil` and filesystem APIs independently of SMART. Mounted areas are matched to the selected physical disk, shared APFS containers are counted once, and unmounted areas are excluded. APFS containers spanning multiple physical disks are excluded because their capacity cannot be attributed to one selected drive. The card shows included volume names, utilization, actual free space, and used/total capacity. Used capacity is total minus free, including snapshots. A connected but unmounted drive can provide SMART while filesystem capacity remains `—`.

For SMART, the reader uses `smartctl --scan -j`, resolves scan entries to the selected physical disk through IOKit/device paths, and uses the reported device type rather than forcing NVMe. If the drive is absent from the scan, the reader tries automatic detection on that physical device. It reads only the selected drive and does not filter model names. NVMe logs provide the detailed counters below. SATA and other devices can provide standardized JSON temperature, SMART status, power-on time, spare, and endurance fields when supported. [Standardized ATA JSON fields](https://www.smartmontools.org/static/doxygen/ataprint_8cpp_source.html) are used as published by smartctl. Vendor-specific ATA raw counters are not guessed or converted with NVMe units; unsupported fields remain `—`.

SMART tool absence, unsupported USB passthrough, access restrictions, and read failures leave mounted filesystem capacity available. The card explains the limitation; missing temperature/health values remain unknown, rather than showing zero, healthy, or failed. An explicit failed SMART status or nonzero critical/media-error value still triggers an alert even if temperature is unavailable. Temperature history clears across missing readings and when changing drives. Repeated external updates retry SMART, allowing the preferred display to recover. Both filesystem and SMART information share the configurable external refresh cycle.

| SMART detail | Meaning |
|---|---|
| Current / session-peak temperature | Current NVMe temperature and highest reading since app launch |
| Cumulative host reads / writes | `data_units_read` / `data_units_written`, converted at 512,000 bytes per unit to decimal TB (10¹² bytes); these are host transfers, not physical NAND traffic or rated TBW |
| Endurance consumed | `percentage_used`, a manufacturer estimate; 0% includes consumption below 1%, and values above 100% are retained. This is separate from storage utilization and is not a remaining-life guarantee |
| Available spare / threshold | Spare capacity for operations such as replacing bad blocks and its device-reported threshold; separate from file-storage free space |
| Power-on hours | Device lifetime `power_on_hours`, rather than app uptime |
| Unsafe shutdowns | Cumulative power losses without a proper shutdown notification; the count alone does not indicate a current fault |
| Media errors / critical warning | Cumulative media/data-integrity errors and hexadecimal Critical Warning bits |

Missing or invalid additional values show `—`. Counters are maintained by the SSD; the app does not need a persistent transfer log or additional polling. Field reference: [smartmontools NVMe output implementation](https://www.smartmontools.org/static/doxygen/nvmeprint_8cpp_source.html).

## External SSD requirements and compatibility

SMART temperature and health monitoring optionally use [`smartmontools`](https://formulae.brew.sh/formula/smartmontools), installed separately:

```sh
brew install smartmontools
```

`smartctl` is not bundled. The app searches common Homebrew `bin` and `sbin` locations under `/opt/homebrew` and `/usr/local`. It is optional for filesystem capacity. To check diagnostic support on a particular connection:

1. Run `smartctl --scan -j` and locate the selected physical drive.
2. Run `smartctl -a -j -d <type-from-scan> "<device-name-from-scan>"`. If the device is absent from the scan, try `smartctl -a -j /dev/diskN` with its current physical identifier.
3. Check which standardized temperature/SMART fields the JSON actually returns. Model-name source changes are unnecessary.

Ordinary file access does not establish diagnostic compatibility. A USB enclosure may permit file transfers but block SMART; USB-C, USB4, or NVMe product labels alone are insufficient. Diagnostic access depends on the enclosure, driver, macOS backend, and smartctl device type. Changing a parser cannot guarantee passthrough support. In that case the app uses capacity monitoring, and unknown values stay unknown. [smartctl macOS backend](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/os_darwin.cpp), [smartctl manual](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/smartctl.8.in).

The recorded hardware verification on October 3, 2026 used an Apple Silicon Mac mini, macOS 26.3, Crucial T500 2TB (`CT2000T500SSD8`), Logitec LGB-PNVU4C enclosure, USB4 exposing an NVMe device, and smartmontools 7.5. Other combinations have not been verified.

Other NVMe/SATA parsing, missing-tool/unsupported-SMART fallback, multiple-drive selection, removal/reconnection, and stale-read rejection have regression fixtures. On this Mac, real T500 capacity and SMART readings and real capacity-only operation with smartctl unavailable were also checked. Other physical drive/enclosure combinations have not been verified. Temperature thresholds remain the app's general attention guides; consult the selected drive's operating guidance. Moving the app or project to another storage drive does not change the saved monitoring selection.

## Build and diagnostics

Build requirements: an Apple Silicon Mac with macOS 14 or later, plus Xcode or Xcode Command Line Tools. The current target is `arm64`; Intel builds are untested.

```sh
bash build.sh
```

This creates `MacMonitor.app`, signs it ad hoc, and runs the built-in checks. Compiler intermediates and module caches stay in `.build` in the project directory.

```sh
# Read one set of metrics
'MacMonitor.app/Contents/MacOS/MacMonitor' --check
# Run regression checks
'MacMonitor.app/Contents/MacOS/MacMonitor' --self-test
# Use another smartctl executable
'MacMonitor.app/Contents/MacOS/MacMonitor' --smartctl /absolute/path/to/smartctl
```

The 109 checks cover metrics/alerts, pressure versus utilization, GPU missing/invalid readings, capacity estimates, SMART conversions, language/preferences/intervals, external-disk matching, screen bounds, and compact menu-bar widths, retained space after digit changes, and warning-only icon space. They also cover drive identity/persistence, NVMe and standardized SATA parsing, SMART-unavailable capacity fallback, ambiguity/removal/reconnection, and stale-result rejection. `--check` prints available CPU/core/load, GPU, memory, internal-capacity, external-capacity/volume, and SMART data.

`--smartctl` selects an executable, not a drive. `--check` follows the saved drive selection (or the first candidate before a selection exists), lists available candidates, and reports capacity-only notes without inventing missing health fields. Restricted environments can block SMART, swap, and memory-pressure reads; verify availability in a normal app launch or Terminal session. The app does not request administrator privileges.

| Source | Purpose |
|---|---|
| `main.swift` | Sampling coordination, menu bar, dashboard, alerts, regression checks |
| `Metrics.c` / `Metrics.h` | Native CPU, memory, swap, and pressure readings |
| `ComputeReader.swift` | CPU hardware information and GPU readings |
| `SSDReader.swift` | smartctl discovery and NVMe SMART readings |
| `ExternalStorageReader.swift` | Physical-disk matching and filesystem capacity aggregation |
| `AppSettings.swift` / `Resources/` | Preferences, settings UI, Japanese/English strings |
| `Info.plist` / `build.sh` | Bundle metadata, build, signing, and checks |

The app makes no network requests, changes no fan settings, deletes no files or caches, and registers no notification-center alerts or login items. The project uses the [MIT License](LICENSE). `smartmontools` is an independent dependency with its own [license information](https://formulae.brew.sh/formula/smartmontools).
