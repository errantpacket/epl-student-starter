# Lab 01 Take-home — GL.iNet MT3000 Physical Tour

The in-class Lab 01 uses the GL.iNet Mango (GL-MT300N-V2) as the drop device and a VS
Code devcontainer as the engagement platform. The MT3000 (Beryl AX) hardware was
originally planned for the engagement platform role; content specific to that device
moves here as a post-workshop depth track.

The `take-home/lab01-mt3000-tour/` directory will cover:

- Physical walkthrough of the GL-MT3000: dual-band WiFi-6 radios, USB-C power, USB-A
  port, eMMC flash (no NOR flash constraint), and the recessed reset button location.
- The `mediatek/filogic` target vs. `ramips/mt76x8`: what changes in device tree,
  package availability, and ImageBuilder invocation.
- GPIO header pinout and serial console access for the MT3000 (different testpoint
  locations and voltage levels than the Mango — verify before connecting).
- LED behavior differences and how the MT3000's blue/white multi-function LED maps to
  boot stages.
- eMMC vs. NOR flash sectoring: why ExtRoot is unnecessary on the MT3000, and how to
  think about 128 GB of always-available overlay vs. the Mango's 16 MB NOR ceiling.

This content is scheduled for Wave 4 drafting, after the core in-class labs are
validated on real hardware. It is not required for the two-day workshop.
