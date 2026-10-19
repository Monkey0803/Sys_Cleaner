# Sys Cleaner

Native macOS 14+ file cleanup app, built with SwiftUI. English and 简体中文 are included.

## Features

- Space analysis with an animated pie chart and a read-only mounted-volume overview: click slices or legend entries to drill down or preview files; large-file filters and content-verified duplicates.
- User cache and log review. The Xcode overview scans DerivedData, archives, simulator devices, simulator runtimes, and iOS Device Support independently, displaying each category's estimated size, status, and elapsed time. The Review List presents larger items by cleanup method: build directories are grouped by metadata-backed project with totals, recent activity, and individual directory selection for Trash; shutdown simulator devices require separate confirmation and cannot be restored through Trash, and archives, runtimes, and Device Support remain read-only. Items show their available real paths with Finder actions and explain when a path is unavailable. DerivedData supports custom locations, search, attribution filters, and sorting. Runtime rows show device counts for the same identifier and warn when multiple images share it, since the device list cannot identify the exact build. Review runtime removal in Xcode Settings > Components. Other Xcode caches and test clones are explicitly marked as uncovered.
- App bundle removal plus files in exact bundle-ID paths under the user's Library; choose or drop a `.app` to review it.
- Read-only candidates from selected user Library data folders, excluding identifiers of installed apps and their extensions, services, and login items. Verify candidates manually in Finder; Preferences and logs are excluded.
- Scan stage, processed counts, and current path. Completed scans show their source, result and actionable counts, omissions and warnings, plus a size-estimate explanation. Scan state remains independent when switching categories.
- Search, sorting, type/status filters, and Quick Look for scanned results; per-group selection and persistent ignore controls for duplicate files. Exclude selected paths from future scans in Settings.
- Per-item cleanup reasons, Trash by default, separate permanent deletion, per-item results, and local cleanup history. History can restore items that this app moved to Trash when their identity is still verifiable, without overwriting an occupied original path.
- Finder Services entry for a selected `.app`: use **Review App in Sys Cleaner** to open its App Uninstall review.
- Persistent menu bar icon to reopen the main window after closing it, or quit the app.
- Settings for live English/简体中文 switching, system/dark/light appearance, six selectable Dock and menu bar icons, and About information. Choices persist across launches.
- Local scanning only. No account, telemetry, scheduled cleanup, privileged helper, or background monitor.

## Build and test

Open `SysCleaner.xcodeproj` in Xcode 15 or newer and run the **Sys Cleaner** scheme on macOS 14 or newer. From Terminal:

```sh
swift test
xcodebuild -project SysCleaner.xcodeproj -scheme 'Sys Cleaner' -configuration Debug \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

The Xcode project is checked in. If Swift source files are added, regenerate it with `ruby scripts/generate-project.rb` (requires the `xcodeproj` Ruby gem).

## Permissions and safety

Choose a folder to scan in Space Analysis, Large Files, and Duplicates. Cache and app scans use known local locations. Some folders require Full Disk Access, which only the user can grant in **System Settings → Privacy & Security → Full Disk Access**. Denial leaves accessible results available and shows scan warnings. macOS permissions and System Integrity Protection still apply.

Every deletion starts from a visible, manually selected result. The app checks file identity, size, modification time, path boundaries, symlink parents, cloud placeholders, and protected locations again just before removal. Caches modified within 15 minutes and files reported open by `lsof` are skipped. Xcode DerivedData is selected by whole project directory, sent only to Trash, and rechecked for changed contents and open files; its origin is shown only when Xcode metadata identifies it. Archives are read-only. Simulator devices are deleted only when shutdown, with a fresh status check and a separate irreversible-action confirmation through `simctl`. An app bundle is skipped if its app is running or its scanned contents changed. Failed items never trigger an automatic permanent-delete fallback.

Logical and allocated-block sizes are shown separately. APFS clones, sparse files, and shared storage can make actual reclaimed space differ; the cleanup result also shows the observed change in available volume capacity, which may include unrelated activity. Scan results show whether unreadable locations or item limits made them partial. Space Analysis is read-only: positive-size files smaller than 1 MB are grouped into “Other files” while still contributing to folder totals; the pie chart shows the six largest positive-size items and combines remaining items with “Other files” into an “Other” slice. Zero-size items remain in the list up to its limit. Duplicate scanning excludes symlinks, hard links, and cloud placeholders; one copy per content hash group remains nonselectable. Cache results show the 2,000 largest files, and duplicate comparison is limited to 100,000 files with a warning when a scan exceeds that bound. App Uninstall lists apps quickly and measures bundle sizes in the background; open an app to inspect matched files before selection. Running apps must be quit and rescanned before review. Old history entries, permanently deleted items, and Trash items that have changed cannot be restored through history. Cleanup never targets system roots, snapshots, iCloud data, or app archives; simulator device deletion requires separate confirmation.

## Source availability and optional direct distribution

This repository publishes source code on GitHub; it does not currently provide a downloadable app binary. Build locally using the commands above.

If a direct-download binary is offered later, release builds use Hardened Runtime and no App Sandbox. Install a Developer ID Application certificate and configure a `notarytool` keychain profile. Set `TEAM_ID`, `DEVELOPER_ID_APPLICATION`, and `NOTARY_PROFILE`, then run `zsh scripts/release.sh`. The script archives, signs, notarizes, staples, verifies, and creates `build/release/Sys-Cleaner.zip`. No binary is ready for distribution until these checks complete on a real signing identity.

## License and references

MIT. This is an independent implementation informed by the public product workflows of CleanMyMac, DaisyDisk, AppCleaner, Pearcleaner, and Mole; no code from those projects is included.
