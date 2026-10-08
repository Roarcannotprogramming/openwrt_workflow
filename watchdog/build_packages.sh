#!/bin/bash
set -euo pipefail

COMPONENT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$COMPONENT_DIR/source.env"
BUILD_DIR=${BUILD_DIR:-/builder}
BUILDER=${BUILDER:-buildbot}
OUTPUT_DIR=${OUTPUT_DIR:-"$(pwd)/watchdog-packages"}
export TMPDIR="${TMPDIR:-$HOME/.paseo/.tmp}"
mkdir -p "$TMPDIR"

builder_home=$(getent passwd "$BUILDER" | cut -d: -f6)
export TMPDIR="$builder_home/.paseo/.tmp"
install -d -m 700 -o "$BUILDER" -g "$BUILDER" "$TMPDIR"

archive="$TMPDIR/internet-detector-source.tar.gz"
if [ ! -f "$archive" ] || ! echo "$INTERNET_DETECTOR_SHA256  $archive" | sha256sum --check --status; then
    curl --fail --location --retry 3 --retry-all-errors --connect-timeout 15 --max-time 120 \
        "https://codeload.github.com/gSpotx2f/luci-app-internet-detector/tar.gz/$INTERNET_DETECTOR_REVISION" \
        --output "$archive"
fi
echo "$INTERNET_DETECTOR_SHA256  $archive" | sha256sum --check --status

source_dir="$BUILD_DIR/package/cpe-connectivity"
mkdir -p "$source_dir"
tar -xzf "$archive" -C "$source_dir" --strip-components=1
patch --batch --forward -d "$source_dir" -p1 < "$COMPONENT_DIR/patches/001-https-connectivity.patch"
mkdir -p "$source_dir/luci-app-internet-detector/po/zh_Hans"
cp "$COMPONENT_DIR/luci/po/zh_Hans/internet-detector.po" \
    "$source_dir/luci-app-internet-detector/po/zh_Hans/"
mkdir -p "$BUILD_DIR/package/cpe-watchdog"
cp "$COMPONENT_DIR/Makefile" "$BUILD_DIR/package/cpe-watchdog/Makefile"
rm -rf -- "$BUILD_DIR/package/cpe-watchdog/overlay"
mkdir -p "$BUILD_DIR/package/cpe-watchdog/overlay"
cp -R "$COMPONENT_DIR/overlay/." "$BUILD_DIR/package/cpe-watchdog/overlay/"
chown -R "$BUILDER:$BUILDER" "$source_dir" "$BUILD_DIR/package/cpe-watchdog"

cd "$BUILD_DIR"
chown -R "$BUILDER:$BUILDER" "$BUILD_DIR"
for feed in base packages luci; do
    if ! awk -v feed="$feed" '{ for (i=2; i<=NF; i++) if ($i == feed) found=1 } END { exit !found }' feeds.conf.default; then
        continue
    fi
    for attempt in 1 2 3; do
        if timeout 600 runuser -u "$BUILDER" -- env TMPDIR="$TMPDIR" \
            GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 ./scripts/feeds update "$feed"; then
            break
        fi
        if [ "$attempt" = 3 ]; then
            exit 1
        fi
    done
done
runuser -u "$BUILDER" -- env TMPDIR="$TMPDIR" ./scripts/feeds install -a
# This job owns its SDK configuration; avoid optional dependencies enabled by ALL.
cat > .config <<'EOF'
# CONFIG_ALL is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
CONFIG_PACKAGE_internet-detector=m
CONFIG_PACKAGE_luci-app-internet-detector=m
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-i18n-internet-detector-zh-cn=m
CONFIG_PACKAGE_cpe-watchdog=m
EOF
chown "$BUILDER:$BUILDER" .config
runuser -u "$BUILDER" -- env TMPDIR="$TMPDIR" make defconfig
runuser -u "$BUILDER" -- env TMPDIR="$TMPDIR" make package/luci-base/host/compile V=s -j1
for package in cpe-connectivity/internet-detector cpe-connectivity/luci-app-internet-detector cpe-watchdog; do
    make_flags=()
    # The glue package only copies scripts: runtime dependencies come from ImageBuilder.
    if [ "$package" = cpe-watchdog ]; then make_flags=(NO_DEPS=1); fi
    runuser -u "$BUILDER" -- env TMPDIR="$TMPDIR" make "package/$package/compile" V=s -j"${BUILD_JOBS:-2}" "${make_flags[@]}"
done

mkdir -p "$OUTPUT_DIR"
# Detect output format from the actual SDK rather than guessing from "master".
for package in internet-detector luci-app-internet-detector luci-i18n-internet-detector-zh-cn cpe-watchdog; do
    mapfile -t artifacts < <(find bin/packages -type f \
        \( -name "${package}_*.ipk" -o -name "${package}-[0-9]*.apk" \))
    if [ "${#artifacts[@]}" = 0 ]; then
        echo "Missing built package: $package" >&2
        exit 1
    fi
    cp "${artifacts[@]}" "$OUTPUT_DIR/"
done
