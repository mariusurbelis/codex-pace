#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
architecture="${2:-native}"
if (( $# > 2 )); then
  echo "Usage: $0 [release|debug] [--universal]" >&2
  exit 1
fi
case "$configuration" in
  release|debug) ;;
  *) echo "Usage: $0 [release|debug] [--universal]" >&2; exit 1 ;;
esac
case "$architecture" in
  native|--universal) ;;
  *) echo "Usage: $0 [release|debug] [--universal]" >&2; exit 1 ;;
esac

swift_path="$(xcrun --find swift)"
build_options=(--package-path "$project_dir" --configuration "$configuration" --product CodexPace)
if [[ "$architecture" == --universal ]]; then
  build_options+=(--arch arm64 --arch x86_64)
fi
"$swift_path" build "${build_options[@]}"
bin_dir="$("$swift_path" build "${build_options[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Codex Pace.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexPace" "$app_dir/Contents/MacOS/CodexPace"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$app_dir/Contents/Info.plist"
if [[ "$architecture" == --universal ]]; then
  for arch in arm64 x86_64; do
    xcrun lipo "$app_dir/Contents/MacOS/CodexPace" -verify_arch "$arch"
  done
fi
if [[ "$configuration" == release ]]; then
  # Remove debug/local symbols, including developer paths, before signing.
  xcrun strip -S -x "$app_dir/Contents/MacOS/CodexPace"
fi
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist")"
codesign --force --sign - --identifier "$bundle_identifier" "$app_dir"
printf '\nBuilt %s\n' "$app_dir"
