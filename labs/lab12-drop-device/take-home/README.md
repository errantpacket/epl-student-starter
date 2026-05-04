# Take-home: Lab 12 — MT3000 Drop Device (WiFi-6 Active Drop)

This is a pointer to a future lab in `labs/take-home/lab12-mt3000-drop/` that extends
the in-class Mango drop-device exercise to the GL.iNet Beryl AX (GL-MT3000).

The MT3000 (mediatek/filogic, 256 MB NOR + 512 MB RAM, WiFi-6) enables a class of active
drop scenarios not possible on the Mango: the device can stand up its own AP, beacon as a
legitimate-looking SSID, capture 802.11 management frames and associate-request metadata
in real time, and exfiltrate via the same EPL Worker / R2 pipeline built in Labs 09-14.
The `bake-secrets.sh` pattern from this lab carries over unchanged; only the ImageBuilder
profile (`glinet_gl-sft1200` or `glinet_gl-mt3000`) and the package list change.
The take-home lab will include a WiFi-scanning variant of `run-capture.sh` (Lab 14) and
a discussion of dual-uplink resilience (WiFi client + Ethernet WAN failover).
