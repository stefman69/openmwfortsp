OpenMW 0.51 ARM64 runtime export
================================

Copy this folder to the SD card:

    runtime-0.51/

Expected destination:

    /mnt/SDCARD/data/ports/openmw/runtime-0.51/

The executable has been renamed to:

    runtime-0.51/bin/openmw

Application libraries are in:

    runtime-0.51/lib/

Core OS and graphics-stack libraries are intentionally NOT active. They are
stored in review-system-libs/ because Ubuntu's glibc, EGL/GLES, DRM, X11,
Wayland, ALSA, and PulseAudio libraries should not override CrossMix.

Review reports/unresolved-libs.txt before copying the runtime.
