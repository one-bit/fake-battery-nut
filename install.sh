#!/bin/bash
# fake-battery-nut installer
set -e

MODULE_NAME="fake-battery-nut"

# Run from the directory holding this script, so the sources and dkms.conf are
# found no matter where the installer was invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Single source of truth for the version: dkms.conf. Hardcoding it here means
# 'dkms add' asserts a version the staged tree does not declare, and DKMS
# rejects it.
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
if [ -z "$VERSION" ]; then
    echo "ERROR: could not read PACKAGE_VERSION from ${SCRIPT_DIR}/dkms.conf"
    exit 1
fi

SRCDIR="/usr/src/${MODULE_NAME}-${VERSION}"

echo "=== Installing ${MODULE_NAME} v${VERSION} ==="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0)"
    exit 1
fi

# Check dependencies
# Test for the commands and the kernel build tree themselves, not for a
# particular distro's package name - the module builds fine anywhere DKMS and
# kernel headers exist. Package names appear only as hints in the errors.
echo "Checking dependencies..."
if ! command -v upsc &> /dev/null; then
    echo "ERROR: NUT client not found ('upsc' is not in PATH)."
    echo "       Arch:   pacman -S nut"
    echo "       Fedora: dnf install nut"
    echo "       Debian: apt install nut-client"
    exit 1
fi

if ! command -v dkms &> /dev/null; then
    echo "ERROR: DKMS not found ('dkms' is not in PATH)."
    echo "       Arch:   pacman -S dkms"
    echo "       Fedora: dnf install dkms"
    echo "       Debian: apt install dkms"
    exit 1
fi

KERNEL_BUILD="/lib/modules/$(uname -r)/build"
if [ ! -d "$KERNEL_BUILD" ]; then
    echo "ERROR: kernel headers for $(uname -r) not found at ${KERNEL_BUILD}"
    echo "       Arch:   pacman -S linux-headers"
    echo "       Fedora: dnf install kernel-devel-$(uname -r)"
    echo "       Debian: apt install linux-headers-$(uname -r)"
    exit 1
fi

# Install DKMS module
echo "Installing DKMS module..."
mkdir -p "$SRCDIR"
cp fake_battery_nut.c "$SRCDIR/"
cp Makefile "$SRCDIR/"
cp dkms.conf "$SRCDIR/"

# Skip 'dkms add' only when this exact module/version is already registered.
# Every other failure must surface with its output intact - swallowing it hides
# the real diagnostic and the script then dies later inside 'dkms build' for a
# reason that reads as unrelated.
if [ -n "$(dkms status -m "$MODULE_NAME" -v "$VERSION" 2>/dev/null)" ]; then
    echo "  ${MODULE_NAME}/${VERSION} already registered with DKMS, skipping 'dkms add'"
else
    dkms add -m "$MODULE_NAME" -v "$VERSION"
fi
dkms build -m "$MODULE_NAME" -v "$VERSION"
dkms install -m "$MODULE_NAME" -v "$VERSION" --force

# Auto-load module on boot
echo "Configuring module autoload..."
echo "fake_battery_nut" > /etc/modules-load.d/fake-battery-nut.conf

# Load the module, replacing an older build if one is already resident.
#
# This matters more than it looks. modprobe is a silent no-op when the module
# is already loaded, and the daemon below IS replaced unconditionally - so
# without this an upgrade leaves the new daemon talking to the old module.
# That pairing is worse than either version alone: the daemon speaks a control
# grammar the old module does not implement, and values the old module has no
# validation for (such as the -1 unknown sentinel) get published verbatim as
# battery state.
LOADED_VERSION=""
if [ -e /sys/module/fake_battery_nut/version ]; then
    LOADED_VERSION=$(cat /sys/module/fake_battery_nut/version)
elif [ -d /sys/module/fake_battery_nut ]; then
    # Loaded, but built before MODULE_VERSION existed - definitely stale.
    LOADED_VERSION="unknown"
fi

if [ -n "$LOADED_VERSION" ] && [ "$LOADED_VERSION" != "$VERSION" ]; then
    echo "Replacing loaded module (${LOADED_VERSION} -> ${VERSION})..."
    # Stop the daemon first so it is not writing to a device about to vanish.
    systemctl stop fake-battery-nut 2>/dev/null || true
    if ! rmmod fake_battery_nut; then
        echo "ERROR: could not unload the running fake_battery_nut module."
        echo "Something still has it open. Stop anything using"
        echo "/dev/fake_battery_nut and re-run, or reboot to complete the upgrade."
        exit 1
    fi
fi

modprobe fake_battery_nut 2>/dev/null || insmod "$(modinfo -n fake_battery_nut)"

# No udev rule is installed. /dev/fake_battery_nut is the module's only write
# interface and it is unauthenticated - whatever is written becomes the
# machine's battery state, which the desktop power stack will act on (UPower's
# CriticalPowerAction can be PowerOff). Only the daemon writes to it and it runs
# as root, so the miscdevice default of 0600 root:root is exactly right.
# Versions up to 1.2.0 shipped a rule with MODE="0666" here; drop it on upgrade
# and re-evaluate the live node so it goes back to 0600.
LEGACY_UDEV_RULE="/etc/udev/rules.d/99-fake-battery-nut.rules"
if [ -e "$LEGACY_UDEV_RULE" ]; then
    echo "Removing world-writable udev rule from a previous install..."
    rm -f "$LEGACY_UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
    # --reload-rules re-reads rules but does not re-apply them to devices that
    # already exist; that needs a trigger.
    udevadm trigger --subsystem-match=misc 2>/dev/null || true
fi

# Install daemon
echo "Installing daemon..."
install -Dm755 nut-to-fakebattery.sh /usr/bin/nut-to-fakebattery

# Install systemd service
echo "Installing systemd service..."
install -Dm644 fake-battery-nut.service /etc/systemd/system/fake-battery-nut.service

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable fake-battery-nut

echo ""
echo "=== Installation complete ==="
echo ""
echo "To configure your UPS, edit /etc/systemd/system/fake-battery-nut.service"
echo "and change NUT_UPS=yourups@localhost"
echo ""
echo "Then reload and start the service:"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl start fake-battery-nut"
echo ""
echo "Check status:"
echo "  systemctl status fake-battery-nut"
echo "  cat /sys/class/power_supply/BAT0/capacity  # UPS battery %"
echo "  cat /sys/class/power_supply/AC0/online     # 1 = on mains, 0 = on battery"
echo ""
echo "UPS load % is not a battery, so it is not exposed here. Ask NUT directly:"
echo "  upsc yourups@localhost ups.load"
