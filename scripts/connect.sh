#!/bin/bash
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
kscreen-doctor output.DP-2.disable output.DP-3.disable output.HDMI-A-1.enable
sleep 3
