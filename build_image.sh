#!/bin/bash
set -e

export VOLUME_HOME=$(pwd)
export BUILD_DIR="/builder"
export BUILDER="buildbot"

cd $BUILD_DIR

# 容器是 debian:13（trixie）裸镜像，/builder 是宿主挂载进来的官方
# imagebuilder 解包目录。官方 openwrt/imagebuilder 镜像是 bullseye 底，
# bullseye 2026-08-31 LTS 到期后 security 源下架，这一步 apt 必挂——
# 所以迁到 trixie，buildbot 用户也在这里自建（官方镜像里预置的那个没了）
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    sudo tree make rsync file zstd wget curl ca-certificates python3 perl
useradd -M -d /builder -s /bin/bash $BUILDER
chown -R $BUILDER:$BUILDER $BUILD_DIR

tree packages/mypackages
sudo -u $BUILDER sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=[0-9]\+/CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE/g;s/CONFIG_TARGET_KERNEL_PARTSIZE=[0-9]\+/CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_SIZE/g" .config
echo $PROFILE

# For OpenWRT 25.x (apk), need to allow untrusted packages
if [[ "$VERSION" == 25.* ]]; then
    echo "OpenWRT 25.x detected, disabling signature check for custom packages..."
    sed -i 's/CONFIG_SIGNATURE_CHECK=y/# CONFIG_SIGNATURE_CHECK is not set/' .config
fi

sudo -u $BUILDER make image PROFILE=$PROFILE PACKAGES="$PACKAGES packages/mypackages/*"
tree bin/targets
if [ "$ARCH" == "x86-64" ]; then
    cp bin/targets/x86/64/* /openwrt_output/ 
elif [ "$ARCH" == "rockchip-armv8" ]; then
    cp bin/targets/rockchip/armv8/* /openwrt_output/
elif [ "$ARCH" == "mediatek-filogic" ]; then
    cp bin/targets/mediatek/filogic/* /openwrt_output/
fi