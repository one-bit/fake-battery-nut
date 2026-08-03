# Maintainer: Aaron Bockelie <aaronsb@gmail.com>
pkgname=fake-battery-nut-dkms
pkgver=1.2.0
pkgrel=1
pkgdesc="Bridge NUT UPS data to UPower/desktop - makes any UPS look like a laptop battery"
arch=('x86_64')
url="https://github.com/aaronsb/fake-battery-nut"
license=('GPL2')
depends=('dkms' 'nut' 'bc')
makedepends=('linux-headers')
install=${pkgname}.install
source=("${pkgname}-${pkgver}.tar.gz::https://github.com/aaronsb/fake-battery-nut/archive/v${pkgver}.tar.gz")
sha256sums=('30545667d6f1de043d907fe3db533f04b14f50960fba6048d0c194ade4fdf747')

package() {
    cd "$srcdir/fake-battery-nut-${pkgver}"

    # DKMS source
    install -Dm644 fake_battery_nut.c "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/fake_battery_nut.c"
    install -Dm644 Makefile "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/Makefile"
    install -Dm644 dkms.conf "${pkgdir}/usr/src/${pkgname%-dkms}-${pkgver}/dkms.conf"

    # Daemon script
    install -Dm755 nut-to-fakebattery.sh "${pkgdir}/usr/bin/nut-to-fakebattery"

    # Systemd service
    install -Dm644 fake-battery-nut.service "${pkgdir}/usr/lib/systemd/system/fake-battery-nut.service"

    # Module autoload
    install -Dm644 /dev/stdin "${pkgdir}/usr/lib/modules-load.d/fake-battery-nut.conf" <<< "fake_battery_nut"

    # No udev rule is installed. /dev/fake_battery_nut is the module's unauthenticated
    # control interface - whatever is written to it becomes the machine's battery state,
    # which UPower acts on (CriticalPowerAction). The only writer is the daemon, running
    # as root, so the miscdevice default of 0600 root:root is correct. Earlier releases
    # shipped MODE="0666" here, which let any local user trigger a critical-battery
    # shutdown. pacman drops the old rule file on upgrade; the .install hook re-triggers
    # udev so the live node loses those permissions without waiting for a reboot.
}
