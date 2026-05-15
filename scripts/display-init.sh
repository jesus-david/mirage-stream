#!/bin/bash
# Ensure virtual display is off and physical monitors are on at login.
# Sunshine's connect.sh will enable HDMI-A-1 when a client connects.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus

sleep 3  # wait for KWin to finish initializing outputs
kscreen-doctor output.HDMI-A-1.disable output.DP-2.enable output.DP-3.enable
