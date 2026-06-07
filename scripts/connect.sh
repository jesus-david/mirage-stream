#!/bin/bash
# Template for Arch/CachyOS manual installs.
# On Fedora/Nobara, install.sh generates this file with the correct connector
# names detected at install time — do not copy this file directly.
#
# Connector names used here (DP-2, DP-3, HDMI-A-1) are from an Arch setup
# where NVIDIA was card2. Adjust to match your system.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
kscreen-doctor output.DP-2.disable output.DP-3.disable output.HDMI-A-1.enable
sleep 3
