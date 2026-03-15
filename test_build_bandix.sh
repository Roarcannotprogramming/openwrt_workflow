#!/bin/bash
# Test script for building bandix packages locally
# Usage: ./test_build_bandix.sh <version> <arch>
# Example: ./test_build_bandix.sh 24.10.0 x86-64

set -e

VERSION=${1:-"24.10.0"}
ARCH=${2:-"x86-64"}

echo "Building bandix packages for OpenWRT ${VERSION} on ${ARCH}"

# Determine package extension
if [[ "$VERSION" == 24.* ]]; then
    PKG_EXT="ipk"
else
    PKG_EXT="apk"
fi

echo "Package extension: ${PKG_EXT}"

# Run build in SDK container
docker run --rm -i \
    --name openwrt-sdk-bandix-test \
    --user root \
    -v $(pwd)/bandix_output:/output \
    -e VERSION=${VERSION} \
    -e ARCH=${ARCH} \
    -e PKG_EXT=${PKG_EXT} \
    openwrt/sdk:${ARCH}-${VERSION} /bin/bash << 'EOF'
set -e

export BUILD_DIR="/builder"
export BUILDER="buildbot"

cd $BUILD_DIR

# Update and install dependencies
apt-get update
apt install sudo git -y

# Clone both repositories
echo "Cloning openwrt-bandix repository..."
sudo -u $BUILDER git clone https://github.com/timsaya/openwrt-bandix.git package/openwrt-bandix

echo "Cloning luci-app-bandix repository..."
sudo -u $BUILDER git clone https://github.com/timsaya/luci-app-bandix.git package/luci-app-bandix

# Update feeds
echo "Updating feeds..."
while ! sudo -u $BUILDER ./scripts/feeds update -a; do echo "Try again"; done

# Generate config
echo "Generating defconfig..."
sudo -u $BUILDER make defconfig

# Compile backend first (dependency for frontend)
echo "Compiling openwrt-bandix..."
sudo -u $BUILDER make package/openwrt-bandix/openwrt-bandix/compile V=s -j1

# Compile frontend
echo "Compiling luci-app-bandix..."
sudo -u $BUILDER make package/luci-app-bandix/luci-app-bandix/compile V=s -j1

# Copy output files
echo "Copying output files..."
mkdir -p /output
find bin/packages -name "openwrt-bandix*.${PKG_EXT}" -exec cp {} /output/ \; 2>/dev/null || true
find bin/packages -name "luci-app-bandix*.${PKG_EXT}" -exec cp {} /output/ \; 2>/dev/null || true

echo "Build complete! Output files:"
ls -la /output/
EOF

echo "Local build test complete. Check bandix_output/ directory for packages."
