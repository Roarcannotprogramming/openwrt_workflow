# openwrt_workflow
Custom OpenWrt firmware builds with additional packages.

Passwall's Sing-Box shunt dependencies (`sing-box`, `geoview`, `v2ray-geoip`,
and `v2ray-geosite`) are built and included in every supported firmware image.
The GeoIP and GeoSite databases live in `/usr/share/v2ray/` in the firmware,
so first flash and subsequent upgrades do not need an online installation step.
Existing Passwall configuration is retained when upgrading with "Keep settings";
new routers still need their own proxy nodes and routing configuration.

The build rejects missing package artifacts and checks every final firmware
manifest before publishing. To run the dependency regression checks locally:

```sh
python3 -m unittest discover -s tests -p test_passwall_artifacts.py -v
```

The [HTTPS CPE watchdog component](watchdog/README.md) builds Internet Detector,
its LuCI app, and model-specific recovery scripts through the same SDK/artifact/
ImageBuilder pipeline as the other components. Passwords are provisioned only
on the router, never included in this repository or firmware artifacts.
 
