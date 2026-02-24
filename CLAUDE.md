# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains GitHub Actions workflows for building custom OpenWRT firmware images with additional packages (Passwall, Argon theme). It supports multiple OpenWRT versions and architectures.

## Key Architecture

### Version Compatibility
- **OpenWRT 24.x**: Uses `opkg` package manager with `.ipk` files
- **OpenWRT 25.x**: Uses `apk` package manager with `.apk` files
- Version detection pattern: `[[ "$VERSION" == 24.* ]]` or `[[ "$VERSION" == 25.* ]]`

### Build Pipeline (build_image_all.yml)
1. **build_passwall** - Builds Passwall (requires Go installation)
3. **build_theme_argon** - Builds Argon theme
4. **build_image** - Combines artifacts and creates final firmware image

Jobs run in parallel where possible; `build_image` depends on all package builds.

### Docker Images Used
- `openwrt/sdk:{arch}-{version}` - For compiling packages
- `openwrt/imagebuilder:{arch}-{version}` - For creating firmware images

### Supported Targets
- **Architectures**: `x86-64`, `rockchip-armv8`
- **Profiles**: `generic` (x86-64), `friendlyarm_nanopi-r2s` (rockchip-armv8)

## Build Scripts

### build_image.sh
Creates final firmware image. Key environment variables:
- `PROFILE` - Device profile name
- `PACKAGES` - Space-separated package list
- `ROOTFS_SIZE` / `KERNEL_SIZE` - Partition sizes
- `ARCH` / `VERSION` - Target architecture and OpenWRT version

For OpenWRT 25.x, uses `ADD_LOCAL_KEY=1` to allow unsigned custom packages.

## Important Patterns

### Package Extension Handling
```yaml
if [[ "${{ matrix.version }}" == 24.* ]]; then
  echo "PKG_EXT=ipk" >> $GITHUB_ENV
else
  echo "PKG_EXT=apk" >> $GITHUB_ENV
fi
```

### Artifact Retention
- Intermediate packages: 7 days
- Final firmware images: 30 days

## Workflow Triggers
- Push to `master` branch
- Manual dispatch (`workflow_dispatch`)
- Daily schedule at 21:00 UTC
