#!/bin/bash
set -euo pipefail

if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 1
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
case "$version" in
  ''|*[!A-Za-z0-9._-]*) echo "Invalid app version for release filename: $version" >&2; exit 1 ;;
esac

# build.sh strips release symbols before applying the final ad hoc signature.
"$project_dir/scripts/build.sh" release --universal

dist_dir="$project_dir/dist"
app_dir="$dist_dir/Codex Pace.app"
archive_name="Codex-Pace-$version-macos-universal.zip"
codesign --verify --strict "$app_dir"
for arch in arm64 x86_64; do
  xcrun lipo "$app_dir/Contents/MacOS/CodexPace" -verify_arch "$arch"
done
if LC_ALL=C grep -aEq '/(Users|home)/[^/[:space:]]+/' "$app_dir/Contents/MacOS/CodexPace"; then
  echo "Release binary contains a developer home path; refusing to package it." >&2
  exit 1
fi
rm -f "$dist_dir/$archive_name"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$dist_dir/$archive_name"
(
  cd "$dist_dir"
  shasum -a 256 "$archive_name" > SHA256SUMS
)
printf '\nRelease archive: %s\nChecksums: %s\n' "$dist_dir/$archive_name" "$dist_dir/SHA256SUMS"
