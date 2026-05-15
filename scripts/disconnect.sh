#!/bin/bash
# Runs when the Moonlight client disconnects.
# Disables the virtual display and restores physical monitors.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)

kscreen-doctor \
    output.HDMI-A-1.disable \
    output.DP-2.enable \
    output.DP-3.enable
