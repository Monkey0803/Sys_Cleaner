# Sys Cleaner

Native macOS 14+ file cleanup app, built with SwiftUI. English and 简体中文 are included.

## Features

- Space analysis with an animated pie chart and a read-only mounted-volume overview: click slices or legend entries to drill down or preview files; large-file filters and content-verified duplicates.
- Downloads review scans ordinary files under the current user's Downloads folder. Search, sort, preview, and move selected files to Trash; unfinished downloads cannot be selected, and permanent deletion is unavailable.
- Cleanup Overview combines actionable candidates scanned during the current app session. It shows separate local and iCloud local-copy estimates, category scan locations, and reasons for incomplete results. Overlapping paths and contents of listed folders count once. Its unified review list supports search, category/action/risk filters, and pages through all candidates. Select items across filters, review the combined plan, and confirm execution; items are moved to Trash, have their local iCloud copy removed, or have a shutdown simulator deleted as appropriate. Each outcome is reported separately. You can also open the original category for individual review.
- The overview can scan chosen categories in sequence with per-category progress and cancellation; completed results remain available after cancellation. Downloads, System Cache, and orphan candidates are selected by default; other categories are optional. The Xcode quick check covers DerivedData only; open Xcode Storage for its full inventory.
- Space Analysis offers an explicit Scan Entire Volume action. The disk-space difference card compares volume usage with allocated file blocks only after a complete scan of that volume's root. Folder scans and incomplete scans show why comparison is unavailable. The difference is diagnostic and cannot precisely attribute APFS snapshots, other volumes, or filesystem overhead to removable data.
- Space scans with complete directory totals save up to 20 snapshots locally and compare growth only for the same scan root and excluded paths. Every direct child of the root is recorded, along with the 2,000 largest deeper directories; unrecorded deeper directories are not assessed for growth. The individual-file display limit does not affect directory totals; scans with unreadable directories do not enter this history.
- User cache and log review. The Xcode overview scans DerivedData, archives, simulator devices, simulator runtimes, and iOS Device Support independently, displaying each category's estimated size, status, and elapsed time. The Review List presents larger items by cleanup method: build directories are grouped by metadata-backed project with totals, recent activity, and individual directory selection for Trash; shutdown simulator devices require separate confirmation and cannot be restored through Trash, and archives, runtimes, and Device Support remain read-only. Items show their available real paths with Finder actions and explain when a path is unavailable. DerivedData supports custom locations, search, attribution filters, and sorting. Runtime rows show device counts for the same identifier and warn when multiple images share it, since the device list cannot identify the exact build. Review runtime removal in Xcode Settings > Components. Shared DerivedData caches, DeviceLogs, documentation data, Products records, DVTDownloads, and XCTestDevices show logical and allocated size estimates, scan status, and Finder access; four verified cache types can be selected individually for Trash.

The Xcode overview lists each scanned source, including confirmed shared DerivedData caches and additional read-only Developer locations. A complete status describes only the listed source. Add custom DerivedData and Archives locations from their respective tabs. Archive locations remain read-only; overlapping or symbolic-link roots are rejected to avoid duplicate counts. Multiple Xcode versions may share one location, so the app does not infer version ownership or combine category estimates into a total.

Complete DerivedData scans save up to 30 project-size snapshots locally in `~/Library/Application Support/Sys Cleaner/xcode-project-history.json`. The Projects tab compares metadata-identified projects with the preceding complete scan only when locations and exclusions match. Incomplete scans save no snapshot; changed sources or project metadata are labeled as not comparable. Unknown projects are not attributed in the history, and an absent project does not prove its data was deleted.
The additional Developer locations are detected by exact directory name. Their labels describe likely purpose from the path and observed contents, not a guarantee of rebuildability; they remain read-only. Four shared-cache types recreated in isolated builds across installed Xcode versions can be selected for Trash. SymbolCache remains read-only because those builds did not produce it. Cache removal rechecks path identity, contents, recent changes, and active use; see [validation evidence](docs/XcodeCacheValidation.md). Scan cancellation and unreadable or symbolic-link paths are reported as incomplete results.
- App bundle removal plus files in exact bundle-ID paths under the user's Library; choose or drop a `.app` to review it.
- Read-only candidates from user Library app data, caches, containers, Preferences, logs, and login-item locations, excluding identifiers of installed apps and their extensions, services, and login items. Candidates are grouped by inferred app identifier with source locations and known or unknown size; identifiers can be ignored and restored. Verify ownership manually in Finder because matching names alone are not proof.
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

Logical and allocated-block sizes are shown separately. APFS clones, sparse files, and shared storage can make actual reclaimed space differ; the cleanup result also shows the observed change in available volume capacity, which may include unrelated activity. Scan results show whether unreadable locations or item limits made them partial. Space Analysis is read-only: positive-size files smaller than 1 MB are grouped into “Other files” while still contributing to folder totals; the pie chart shows the six largest positive-size items and combines remaining items with “Other files” into an “Other” slice. Zero-size items remain in the list up to its limit. Duplicate scanning excludes symlinks, hard links, and cloud placeholders; one copy per content hash group remains nonselectable. Cache results show the 2,000 largest files, and duplicate comparison is limited to 100,000 files with a warning when a scan exceeds that bound. App Uninstall lists apps quickly and measures bundle sizes in the background; open an app to inspect matched files before selection. Running apps must be quit and rescanned before review. Old history entries, permanently deleted items, and Trash items that have changed cannot be restored through history. Cleanup never targets system roots, snapshots, cloud originals, or app archives. The iCloud Drive page can only evict safely synced local copies; simulator device deletion requires separate confirmation.

The Xcode Review List compares per-category counts and estimated logical sizes before cleanup and after a fresh scan. Incomplete scans are labeled instead of presented as reliable changes; a manual rescan or leaving the page clears the comparison. Results distinguish successful items, safety skips, and operation failures with individual reasons. A batch spanning volumes has no single meaningful capacity delta.

## Source availability and optional direct distribution

This repository publishes source code on GitHub; it does not currently provide a downloadable app binary. Build locally using the commands above.

If a direct-download binary is offered later, release builds use Hardened Runtime and no App Sandbox. Install a Developer ID Application certificate and configure a `notarytool` keychain profile. Set `TEAM_ID`, `DEVELOPER_ID_APPLICATION`, and `NOTARY_PROFILE`, then run `zsh scripts/release.sh`. The script archives, signs, notarizes, staples, verifies, and creates `build/release/Sys-Cleaner.zip`. No binary is ready for distribution until these checks complete on a real signing identity.

## License and references

MIT. This is an independent implementation informed by the public product workflows of CleanMyMac, DaisyDisk, AppCleaner, Pearcleaner, and Mole; no code from those projects is included.
