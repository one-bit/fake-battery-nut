# Changelog

## 1.3.0

Two themes: the bridge now maps everything a UPS publishes rather than four
variables, and the control interface it does that over was hardened after a
review turned up a security issue and a demonstrable parser bug.

### Security

- **The installer no longer creates a world-writable control device.**
  `install.sh` and the `PKGBUILD` both shipped a udev rule setting
  `/dev/fake_battery_nut` to `MODE="0666"`. That node is an unauthenticated
  control interface - whatever is written to it becomes the machine's battery
  state - so at 0666 any local unprivileged user could write `capacity=1`,
  `status=0`, `charging=0` and make UPower fire its critical-power action.
  Where that action is `PowerOff`, that is an unprivileged local shutdown
  needing no exploit. Only the daemon writes to the node and it runs as root,
  so the miscdevice default of `0600 root:root` is correct. Installing and
  upgrading now also remove a rule left behind by an earlier version and
  re-trigger udev, so an existing machine drops back to 0600 without a reboot.

### Added

- **Full UPS telemetry.** Line voltage, output voltage, frequency, load,
  nominal ratings, shutdown and start delays, beeper state, UPS type and the
  raw status string are published read-only under
  `/sys/class/misc/fake_battery_nut/`. They are deliberately *not* in the
  power_supply class: they are not properties of a battery, and giving them
  their own power supply is what produced the `BAT1` problem recorded in
  ADR-001, where UPower averaged a load meter into its `DisplayDevice` and
  reported a full UPS as a 34% battery.
- **Real device identity.** `device.mfr` and the model string become
  `MANUFACTURER` and `MODEL_NAME`, replacing the hardcoded "NUT" and "UPS
  Battery", so UPower and the desktop name the actual hardware.
  `driver.parameter.product` is used when `device.model` is absent.
- **Battery voltage range.** `battery.voltage.high` and `battery.voltage.low`
  become `VOLTAGE_MAX_DESIGN` and `VOLTAGE_MIN_DESIGN`.
- **Battery health.** `ups.status RB` - the UPS asking for a replacement
  battery - drives `HEALTH`, which was previously hardcoded to `Good`.
- **The low-battery flag reaches the desktop.** `LB`/`FSD` is the signal
  `upsmon` itself shuts down on, and nothing downstream ever saw it. It now
  sets the capacity level to critical *and* clamps the reported percentage,
  because UPower derives its warning level from the percentage when
  `UsePercentageForPolicy` is set, so the level alone changes nothing. The
  clamp defaults to 5% and is tunable with `NUT_LB_CAPACITY`: low enough for a
  critical-battery warning, deliberately above the usual action threshold, so
  `upsmon` stays the authority on shutdown and UPower's action remains a
  backstop rather than a duplicate trigger.
- **An unknown-value convention.** `capacity`, `time`, `voltage` and `temp`
  accept `-1` meaning "the UPS does not publish this", and the module returns
  `-ENODATA` so the attribute is absent rather than carrying an invented
  number. An unknown capacity additionally reports the battery as not present
  and its level as `Unknown`, so missing data can never be mistaken for a flat
  battery.
- **A `level` control key**, 0-5, overriding the capacity-derived level.

### Fixed

- **The control parser could apply a value from the wrong line, and mutated
  state before reporting failure.** `strchrnul()` never returns NULL, so the
  guard against a missing `=` was dead code; for a line with no `=`, the value
  pointer stepped over the terminator and consumed the *next* line's bytes, or
  read uninitialised stack past the supplied data on the last line.
  Demonstrable: `write("capacity\n55\n")` returned `-EINVAL` and still set
  capacity to 55. Writes are now transactional - parsed into a private copy and
  committed only if every line validates - and a write not ending in a newline
  is rejected instead of silently dropping its last line while reporting
  success.
- **No validation on any value.** `capacity=200`, `charging=7` and negative
  voltages were all accepted and published. Every value is now range-checked
  (`-ERANGE`), and keys are matched exactly, so `timeout=9` no longer sets
  `time` and `capacity_level=3` no longer sets `capacity`.
- **`ups.status` was matched by substring, so `DISCHRG` matched `CHRG`.**
  `OL DISCHRG` - reported by some units during a self-test, where the load runs
  from the battery while mains is still present - was reported as *Charging*.
  Status flags are now matched as whole whitespace-delimited tokens.
- **Fabricated readings.** The module served compile-time defaults of 3600 s
  runtime, 26.0 °C and 24 V until the daemon said otherwise, and the daemon
  omitted values it could not read rather than clearing them - so a UPS with no
  `battery.runtime` advertised a permanent, unmoving "1 hour remaining", and a
  variable that vanished mid-run was republished forever. Both now use the
  unknown sentinel.
- **A negative `battery.charge` became 0%** - the one value a critical-power
  action fires on - where every other out-of-band reading was reported unknown.
- **A dead upsd looked like a healthy UPS.** The daemon now gives up after five
  consecutive failed polls, clears the module's published state, and exits
  non-zero so systemd restarts it and `systemctl status` shows the failure.
- **Unsynchronised state.** The published state was written from `write()` and
  read from `get_property()`, which the power_supply core may call concurrently
  on another CPU, with no lock - so a reader could see a new capacity against
  an old status. A spinlock now guards the data and a mutex serialises writers.
- **`CHARGE_NOW`/`CHARGE_FULL`/`CHARGE_FULL_DESIGN` carried a percentage**
  while the power_supply class defines them in µAh, so UPower multiplied by
  voltage and advertised a 0.00276 Wh battery. Removed; `CAPACITY` stands alone.
- **`TIME_TO_FULL_NOW` served the discharge runtime**, telling anything reading
  a charging battery it would be full in however long it had left. Removed.
- **The module registered its control device before the power supplies it
  notifies**, leaving a window where a write would dereference a NULL pointer.
- **A failed `power_supply_register()` surfaced as `-EPERM`** ("Operation not
  permitted") instead of the real error.
- **The installer and uninstaller hardcoded version 1.0.0** while `dkms.conf`
  declared 1.2.0. `dkms add` was rejected for the mismatch and the failure was
  swallowed by `|| true`, so installation died later at `dkms build` with an
  unrelated message; uninstallation removed nothing and reported success,
  leaving the module registered and rebuilding on every kernel upgrade. The
  version is now read from `dkms.conf`, the uninstaller enumerates what is
  actually registered and exits non-zero if a removal fails.
- **Upgrading left the old module loaded under the new daemon.** `modprobe` is
  a no-op when a module is already resident and the daemon is replaced
  regardless, so the two could disagree about the control grammar. The
  installer now compares the loaded module's version against the one being
  installed and reloads when they differ.
- **`install.sh` required pacman** (`pacman -Q linux-headers`) on a DKMS module
  that builds anywhere. It now checks for the kernel build tree and keeps
  package names as hints in the error text.
- **The installer's closing message pointed at `BAT1`**, removed in 1.1.0.

### Changed

- The daemon extracts everything in a single `awk` pass instead of four
  `grep | cut | tr` pipelines and a `bc` call - about 15 processes per two
  second poll down to two. **`bc` is no longer a dependency.**
- Documentation: `CLAUDE.md` and `README.md` no longer describe the removed
  `BAT1`; the README's manual DKMS instructions derive the version from
  `dkms.conf` rather than hardcoding a stale one; ADR-001 is marked partially
  superseded with an addendum covering what changed.
