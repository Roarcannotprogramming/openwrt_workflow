#!/bin/bash

echo "src-git passwall https://github.com/xiaorouji/openwrt-passwall" >> feeds.conf.default
sudo apt-get update
sudo apt-get install upx -y
ln -s /usr/bin/upx staging_dir/host/bin/upx
ln -s /usr/bin/upx-ucl staging_dir/host/bin/upx-ucl

./scripts/feeds update -a

cp -r /home/build/openwrt_workflow/openwrt-passwall-3aff3af88536227d12fb7206992af64ff21cf4d2/luci-app-passwall/ /home/build/openwrt/feeds/passwall/
./scripts/feeds update -a
./scripts/feeds install luci-app-passwall
make defconfig
make package/luci-app-passwall/compile V=99 -j $(nproc)

pushd bin/packages/x86_64
tar zcvf passwall.tar.gz passwall/
popd