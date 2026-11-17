#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./build.sh
release_dir="${BREEZE_RELEASE_DIR:-dist}"
mkdir -p "$release_dir"
# Cloud-backed folders may reintroduce Finder metadata after signing.
xattr -d com.apple.FinderInfo Breeze.app 2>/dev/null || true
codesign --verify --deep --strict Breeze.app
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k --keepParent Breeze.app "$release_dir/Breeze-macOS-arm64.zip"
(cd "$release_dir" && shasum -a 256 Breeze-macOS-arm64.zip > SHA256SUMS.txt)
print "Готово: $release_dir/Breeze-macOS-arm64.zip"
