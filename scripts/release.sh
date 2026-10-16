#!/bin/zsh
set -euo pipefail

# Required: TEAM_ID, DEVELOPER_ID_APPLICATION, NOTARY_PROFILE.
: "${TEAM_ID:?Set your Apple Developer team ID}"
: "${DEVELOPER_ID_APPLICATION:?Set Developer ID Application certificate name}"
: "${NOTARY_PROFILE:?Set a notarytool keychain profile}"

repo_dir="${0:A:h:h}"
release_dir="${repo_dir}/build/release"
archive_path="${release_dir}/Sys Cleaner.xcarchive"
app_path="${archive_path}/Products/Applications/Sys Cleaner.app"
submission_zip="${release_dir}/Sys-Cleaner-notary.zip"
distribution_zip="${release_dir}/Sys-Cleaner.zip"

mkdir -p "${release_dir}"
xcodebuild archive \
  -project "${repo_dir}/SysCleaner.xcodeproj" \
  -scheme 'Sys Cleaner' -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "${archive_path}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}"

codesign --verify --deep --strict --verbose=2 "${app_path}"
ditto -c -k --keepParent "${app_path}" "${submission_zip}"
xcrun notarytool submit "${submission_zip}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${app_path}"
spctl --assess --type execute --verbose=2 "${app_path}"
ditto -c -k --keepParent "${app_path}" "${distribution_zip}"
echo "Release package: ${distribution_zip}"
