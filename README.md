# Sys Cleaner

Native macOS 14+ file cleanup app, built with SwiftUI. English and 简体中文 are included.

## Features

- Space analysis with folder drill-down, large-file filters, and content-verified duplicates.
- User cache and log review; Xcode DerivedData, SwiftPM, and Homebrew cache review.
- App bundle removal plus files in exact bundle-ID paths under the user's Library.
- Item-by-item selection, Trash by default, separate permanent deletion, and per-item results.
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

Every deletion starts from a visible, manually selected result. The app checks file identity, size, modification time, path boundaries, symlink parents, cloud placeholders, and protected locations again just before removal. Caches modified within 15 minutes and files reported open by `lsof` are skipped. An app bundle is skipped if its app is running or its scanned contents changed. Failed items never trigger an automatic permanent-delete fallback.

Sizes are logical file-size estimates. APFS clones, sparse files, and shared storage can make actual reclaimed space differ. Space Analysis is read-only: files smaller than 1 MB are grouped into “Other files” while still contributing to folder totals. Duplicate scanning excludes symlinks, hard links, and cloud placeholders; one copy per content hash group remains nonselectable. Cache results show the 2,000 largest files, and duplicate comparison is limited to 100,000 files with a warning when a scan exceeds that bound. In App Uninstall, choose “Review app” to calculate its size and inspect matched files before selection. Cleanup never targets system roots, snapshots, iCloud data, app archives, or simulator data.

## Direct distribution

Release builds use Hardened Runtime and no App Sandbox. Before packaging, install a Developer ID Application certificate and configure a `notarytool` keychain profile. Set `TEAM_ID`, `DEVELOPER_ID_APPLICATION`, and `NOTARY_PROFILE`, then run `zsh scripts/release.sh`. The script archives, signs, notarizes, staples, verifies, and creates `build/release/Sys-Cleaner.zip`. No release artifact is considered ready until these checks complete on a real signing identity.

## License and references

MIT. This is an independent implementation informed by the public product workflows of CleanMyMac, DaisyDisk, AppCleaner, Pearcleaner, and Mole; no code from those projects is included.
