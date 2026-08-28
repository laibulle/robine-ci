#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$script_dir/build/RobineFixture.app"}
contents="$output/Contents"

rm -rf -- "$output"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$script_dir/Info.plist" "$contents/Info.plist"

xcrun --sdk macosx clang \
  -fobjc-arc \
  -framework Cocoa \
  "$script_dir/main.m" \
  -o "$contents/MacOS/RobineFixture"

/usr/bin/codesign --force --sign - --timestamp=none "$output"
/usr/bin/codesign --verify --strict "$output"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$contents/Info.plist")" = "APPL"

echo "Built $output"
