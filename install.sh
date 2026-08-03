#!/bin/bash
# fake-battery-nut installer
set -e

VERSION="1.0.0"
SRCDIR="/usr/src/fake-battery-nut-${VERSION}"

echo "=== Installing fake-battery-nut v${VERSION} ==="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0)"
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
if ! command -v upsc &> /dev/null; then
    echo "ERROR: NUT not installed. Install with: pacman -S nut"
    exit 1
fi

if ! command -v dkms &> /dev/null; then
    echo "ERROR: DKMS not installed. Install with: pacman -S dkms"
    exit 1
fi

if ! pacman -Q linux-headers &> /dev/null; then
    echo "ERROR: linux-headers not installed. Install with: pacman -S linux-headers"
    exit 1
fi

# Install DKMS module
echo "Installing DKMS module..."
mkdir -p "$SRCDIR"
cp fake_battery_nut.c "$SRCDIR/"
cp Makefile "$SRCDIR/"
cp dkms.conf "$SRCDIR/"

dkms add -m fake-battery-nut -v "$VERSION" 2>/dev/null || true
dkms build -m fake-battery-nut -v "$VERSION"
dkms install -m fake-battery-nut -v "$VERSION" --force

# Auto-load module on boot
echo "Configuring module autoload..."
echo "fake_battery_nut" > /etc/modules-load.d/fake-battery-nut.conf

# Load module now
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
echo "Then start the service:"
echo "  sudo systemctl start fake-battery-nut"
echo ""
echo "Check status:"
echo "  cat /sys/class/power_supply/BAT0/capacity"
echo "  cat /sys/class/power_supply/BAT1/capacity"
