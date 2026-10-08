# openwrt_workflow
Custom OpenWrt firmware builds with additional packages.

The [HTTPS CPE watchdog component](watchdog/README.md) builds Internet Detector,
its LuCI app, and model-specific recovery scripts through the same SDK/artifact/
ImageBuilder pipeline as the other components. Passwords are provisioned only
on the router, never included in this repository or firmware artifacts.
 
