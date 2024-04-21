#!/bin/bash
set -e

export VOLUME_HOME=$(pwd)
export BUILD_DIR="/builder"
export BUILDER="buildbot"

cd $BUILD_DIR 
apt-get update
apt install sudo tree -y

tree packages/mypackages 

chown -R $BUILDER:$BUILDER packages
sudo -u $BUILDER sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=[0-9]\+/CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE/g;s/CONFIG_TARGET_KERNEL_PARTSIZE=[0-9]\+/CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_SIZE/g" .config
echo $PROFILE
sudo -u $BUILDER make image PROFILE=$PROFILE PACKAGES="$PACKAGES packages/mypackages/*"
tree bin/targets
if [ "$ARCH" == "x86-64" ]; then
    cp bin/targets/x86/64/* /openwrt_output/ 
elif [ "$ARCH" == "rockchip-armv8" ]; then
    cp bin/targets/rockchip/armv8/* /openwrt_output/
elif [ "$ARCH" == "mediatek-filogic" ]; then
    cp bin/targets/mediatek/filogic/* /openwrt_output/
fi