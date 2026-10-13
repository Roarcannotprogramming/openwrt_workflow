#!/usr/bin/env python3
"""Fail a build if Passwall's required packages are missing."""
import argparse
from pathlib import Path
import sys


REQUIRED_PACKAGES = (
    "luci-app-passwall", "sing-box", "geoview", "v2ray-geoip", "v2ray-geosite",
)


def verify_packages(root, extension):
    separator = "_" if extension == "ipk" else "-"
    missing = []
    for package in REQUIRED_PACKAGES:
        pattern = f"{package}{separator}[0-9]*.{extension}"
        if not any(path.is_file() and path.stat().st_size for path in root.glob(pattern)):
            missing.append(package)
    if missing:
        raise ValueError(f"Missing {extension} packages in {root}: {', '.join(missing)}")
    print(f"Verified {len(REQUIRED_PACKAGES)} required Passwall packages in {root}")


def verify_manifests(root):
    manifests = sorted(root.rglob("*.manifest"))
    if not manifests:
        raise ValueError(f"No firmware manifests found in {root}")
    for manifest in manifests:
        installed = {line.split()[0] for line in manifest.read_text().splitlines() if line.strip()}
        missing = [package for package in REQUIRED_PACKAGES if package not in installed]
        if missing:
            raise ValueError(f"Missing packages in {manifest}: {', '.join(missing)}")
        print(f"Verified Passwall dependencies in {manifest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("packages", "manifests"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--format", choices=("ipk", "apk"))
    args = parser.parse_args()
    if args.mode == "packages" and not args.format:
        parser.error("packages mode requires --format ipk or apk")
    try:
        if args.mode == "packages":
            verify_packages(args.directory, args.format)
        else:
            verify_manifests(args.directory)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
