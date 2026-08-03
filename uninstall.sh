#!/bin/bash
# fake-battery-nut uninstaller
set -e

MODULE_NAME="fake-battery-nut"
WARNINGS=0

echo "=== Uninstalling ${MODULE_NAME} ==="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0)"
    exit 1
fi

# Stop and disable service
echo "Stopping service..."
systemctl stop fake-battery-nut 2>/dev/null || true
systemctl disable fake-battery-nut 2>/dev/null || true

# Unload module
echo "Unloading module..."
rmmod fake_battery_nut 2>/dev/null || true

# Remove from DKMS.
# Enumerate what is actually registered instead of trusting a hardcoded
# version - an install from an older version must be cleaned up too, otherwise
# the module keeps rebuilding on every kernel upgrade while the uninstaller
# reports success. Handles both DKMS status formats:
#   dkms >= 3: "fake-battery-nut/1.2.0, <kernel>, <arch>: installed"
#   dkms 2.x:  "fake-battery-nut, 1.2.0, <kernel>, <arch>: installed"
echo "Removing DKMS module..."
if command -v dkms &> /dev/null; then
    VERSIONS=$(dkms status -m "$MODULE_NAME" 2>/dev/null \
        | sed -n "s#^${MODULE_NAME}[/,][[:space:]]*\([^,:[:space:]]*\).*#\1#p" \
        | sort -u)
    if [ -z "$VERSIONS" ]; then
        echo "  no ${MODULE_NAME} version registered with DKMS"
    else
        for v in $VERSIONS; do
            echo "  removing ${MODULE_NAME}/${v}"
            if ! dkms remove -m "$MODULE_NAME" -v "$v" --all; then
                echo "  WARNING: 'dkms remove ${MODULE_NAME}/${v}' failed"
                WARNINGS=$((WARNINGS + 1))
            fi
        done
    fi
else
    echo "  WARNING: dkms not found in PATH - skipping DKMS removal"
    WARNINGS=$((WARNINGS + 1))
fi

# Remove files
echo "Removing files..."
rm -f /usr/bin/nut-to-fakebattery
rm -f /etc/systemd/system/fake-battery-nut.service
rm -f /etc/modules-load.d/fake-battery-nut.conf

# Installers up to 1.2.0 wrote a world-writable udev rule for the control
# device. Current installs create no rule at all, but any left behind by an
# older install must still be cleaned up.
UDEV_RULE="/etc/udev/rules.d/99-fake-battery-nut.rules"
RULE_REMOVED=0
if [ -e "$UDEV_RULE" ]; then
    rm -f "$UDEV_RULE"
    RULE_REMOVED=1
fi

# Any staged source tree, whatever version it was installed under.
for dir in /usr/src/"${MODULE_NAME}"-*; do
    [ -d "$dir" ] || continue
    echo "  removing $dir"
    rm -rf "$dir"
done

# Reload
systemctl daemon-reload
if [ "$RULE_REMOVED" -eq 1 ]; then
    udevadm control --reload-rules 2>/dev/null || true
    # Re-evaluate live devices too: --reload-rules alone leaves an already
    # existing node with the permissions the removed rule gave it.
    udevadm trigger --subsystem-match=misc 2>/dev/null || true
fi

echo ""
if [ "$WARNINGS" -ne 0 ]; then
    echo "=== Uninstallation finished with ${WARNINGS} warning(s) - see above ==="
    exit 1
fi
echo "=== Uninstallation complete ==="
