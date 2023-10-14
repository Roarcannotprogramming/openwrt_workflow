#!/bin/bash
set -e

export VOLUME_HOME=$(pwd)
export BUILD_DIR="/builder"
export BUILDER="buildbot"
cd $BUILD_DIR 
apt-get update
apt install sudo tree -y
sudo -u $BUILDER mkdir package/luci-app-openclash
pushd package/luci-app-openclash
sudo -u $BUILDER git init
sudo -u $BUILDER git remote add -f origin https://github.com/vernesong/OpenClash.git
sudo -u $BUILDER git config core.sparsecheckout true
sudo -u $BUILDER echo "luci-app-openclash" >> .git/info/sparse-checkout
sudo -u $BUILDER git pull origin master
sudo -u $BUILDER git branch --set-upstream-to=origin/master master
popd

pushd package/luci-app-openclash/luci-app-openclash/tools/po2lmo
sudo -u $BUILDER make && sudo make install
popd

sudo -u $BUILDER make defconfig
echo "================== DEBUG PRINT BEGIN =================="
cat .config
echo "================== DEBUG PRINT END =================="
sudo -u $BUILDER make package/luci-app-openclash/luci-app-openclash/compile V=99
tree bin/packages 