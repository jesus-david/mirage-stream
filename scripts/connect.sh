#!/bin/bash
# Runs when a Moonlight client connects.
# Disables physical monitors and enables the virtual display for capture.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)

kscreen-doctor \
    output.DP-2.disable \
    output.DP-3.disable \
    output.Virtual-1.disable \
    output.HDMI-A-1.enable
