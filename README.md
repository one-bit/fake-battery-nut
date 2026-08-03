# fake-battery-nut

A Linux kernel module that bridges NUT (Network UPS Tools) to the desktop power stack, making any NUT-supported UPS appear as a laptop battery to your desktop environment.

![Walnut-powered PC](docs/media/battery-nut.png)

### The Duality of Engineering

**Power delivery:**
```
Wall → 1350VA UPS → surge-only outlet → 450VA mini UPS → monitor
                  → battery outlet → gaming PC (93% load)
```
*"eh, the cords are beefy, it's probably fine"*

**Monitoring:**
```
UPS → USB HID → NUT daemon → upsc → bash script →
/dev/fake_battery_nut → custom kernel module →
/sys/class/power_supply/ → UPower → KDE
```
*"we need proper kernel-level integration for the data to show up correctly"*

One is an extension cord chain held together by vibes. The other is a DKMS-managed kernel module with systemd integration.

---

## The Problem

Linux has two parallel power management systems that don't talk to each other:

| System | Focus | Sees UPS? |
|--------|-------|-----------|
| **NUT** | Server/infrastructure, scripted shutdown | Yes (1382+ devices) |
| **UPower** | Desktop UI, suspend/hibernate | Only some USB HID devices |

When NUT claims your UPS (which it must, to manage it), UPower can't see it anymore. Your desktop has no idea a UPS exists - no battery icon, no low-power warnings, no auto-hibernate when the UPS battery gets critical.

## The Solution

This module creates a virtual battery in `/sys/class/power_supply/` that a daemon updates with NUT data:

```
Any NUT-supported UPS → daemon → kernel module → UPower → Desktop
```

Your computer now looks like a laptop to the desktop environment. KDE/GNOME see a battery that charges (on mains) and discharges (on UPS battery), and respond accordingly.

**This works with any of NUT's 1382+ supported devices** - serial, USB, SNMP, network-monitored, whatever. If NUT speaks to it, your desktop can now react to it.

## The Origin Story

This project was born when a gaming PC (Ryzen 9950X3D, RX 7900 XTX, 57" ultrawide) started tripping UPS overload alarms while running Minecraft with shaders. After plugging in a USB cable ignored for 4 years, we discovered the UPS was running at 123% capacity.

The fix? Move the monitor to a different UPS. $0 solution.

But then: "I want to see UPS stats in btop."

btop doesn't support NUT. So we wrote a kernel module.

Then we discovered UPower couldn't see the UPS either, because NUT had claimed it. So accidentally, we built the missing bridge between NUT and desktop power management.

## Components

- **fake_battery_nut.ko** - Kernel module creating BAT0 and AC0 in `/sys/class/power_supply/`
- **/dev/fake_battery_nut** - Control interface for updating values
- **nut-to-fakebattery** - Daemon that reads NUT and writes to the kernel module

## Installation

### From AUR (Arch Linux)

```bash
yay -S fake-battery-nut-dkms
```

### Manual Installation

```bash
# Build
make

# Install module
sudo make install

# Or use DKMS - take the version from dkms.conf rather than pasting a literal,
# because a staged tree whose directory version disagrees with its own dkms.conf
# is rejected by `dkms add`, and the error does not say why.
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
sudo cp -r . "/usr/src/fake-battery-nut-$VERSION"
sudo dkms add "fake-battery-nut/$VERSION"
sudo dkms build "fake-battery-nut/$VERSION"
sudo dkms install "fake-battery-nut/$VERSION"

# Install daemon
sudo install -m755 nut-to-fakebattery.sh /usr/bin/nut-to-fakebattery
sudo install -m644 fake-battery-nut.service /etc/systemd/system/

# Enable
echo "fake_battery_nut" | sudo tee /etc/modules-load.d/fake-battery-nut.conf
sudo systemctl enable --now fake-battery-nut
```

## Configuration

The daemon is configured entirely through the environment in its unit file -
`/etc/systemd/system/fake-battery-nut.service` for a manual install, or
`sudo systemctl edit fake-battery-nut` if the AUR package put it under `/usr/lib`:

```ini
Environment=NUT_UPS=myups@localhost
Environment=NUT_LB_CAPACITY=5
```

- **`NUT_UPS`** - the `upsname@host` the daemon polls. Default `cyberpower@localhost`,
  which is almost certainly not yours; `upsc -l` lists what NUT actually has.
- **`NUT_LB_CAPACITY`** - the capacity percentage reported while the UPS asserts `LB`
  (low battery) or `FSD`. Default `5`.

`LB` is the flag `upsmon` itself acts on, so the daemon does not let it pass silently: it
sets the capacity level to critical *and* clamps the reported percentage, because UPower
with `UsePercentageForPolicy=true` derives its warning level from the percentage and would
otherwise ignore the level entirely. The default of 5 is deliberately low enough to raise a
critical-battery warning but above the usual `PercentageAction` threshold of 2 - `upsmon`
stays the authority on shutdown, and UPower's `CriticalPowerAction` stays a backstop that
only fires if the charge really does keep falling. Lower it only if you want UPower, rather
than NUT, deciding when the machine goes down.

## Control Interface

Write `key=value` lines to `/dev/fake_battery_nut`. Every line must end with a newline:

```bash
echo "capacity=100" | sudo tee /dev/fake_battery_nut     # Battery capacity, 0-100 %, or -1
echo "status=2" | sudo tee /dev/fake_battery_nut         # 0=discharging, 1=charging, 2=full
echo "charging=1" | sudo tee /dev/fake_battery_nut       # AC online, 0 or 1
echo "level=0" | sudo tee /dev/fake_battery_nut          # Capacity level override, see below
echo "time=1800" | sudo tee /dev/fake_battery_nut        # Runtime in seconds, or -1
echo "voltage=24000000" | sudo tee /dev/fake_battery_nut # Voltage in µV, or -1
echo "temp=260" | sudo tee /dev/fake_battery_nut         # Temperature in tenths of °C, or -1
```

**`level=N` overrides the capacity level** that the module otherwise derives from `capacity`:

| N | Capacity level |
|---|----------------|
| 0 | derive from capacity (the default) |
| 1 | critical |
| 2 | low |
| 3 | normal |
| 4 | high |
| 5 | full |

A non-zero level stays in force until `level=0` is written again; the derived level keeps
tracking capacity underneath, so clearing the override takes effect immediately. This exists
so the daemon can state outright that the UPS said `LB`, instead of hoping the reported
percentage happens to have fallen far enough for anyone to notice.

**`-1` means "unknown"** for `capacity`, `time`, `voltage` and `temp`. The module returns
`-ENODATA` for that property, so the sysfs attribute errors out and UPower omits the value
rather than being handed a fabricated one. They all start out unknown at load - nothing is
known until the daemon says so. A UPS that never publishes `battery.runtime` therefore produces
no `time_to_empty_avg` at all, instead of a stately, permanent, entirely invented "1 hour
remaining".

`capacity=-1` carries two extra consequences, both deliberate. The capacity level becomes
`Unknown` rather than falling through the thresholds to `Critical` - the lowest band would
otherwise turn "no reading" into "flat battery". And the battery reports itself **not present**,
because a reader that cannot get a percentage tends to derive one, and with no `CHARGE_*` or
energy properties left to derive from it can settle on 0% - which is indistinguishable from a
genuinely empty battery and quite enough to trigger a critical-power action. An absent battery
is the safe direction to be wrong in. The practical effect is that the desktop battery
indicator disappears while the charge is unknown, rather than showing an alarming lie.

Note the daemon still clamps to `NUT_LB_CAPACITY` when the UPS asserts `LB`, even with no
percentage available: `LB` is the UPS stating it is about to run out, and that is worth
reporting on its own.

**Values are range-checked and a write is transactional.** `capacity` 0-100 or -1, `status` 0-2,
`charging` 0-1, `level` 0-5, `temp` -400 to 1500 tenths of °C, `time` and `voltage` -1 or any
non-negative value. Out of range is `-ERANGE`; an unknown key, or a line without an `=`, is
`-EINVAL`. Keys are matched exactly, so `capacity_level=3` is an error rather than a silent
`capacity=3`. The whole batch is parsed into a private copy of the state and committed only if
every line validated - one bad line rejects the entire write and leaves the published state
exactly as it was.

## UPS telemetry beyond the battery

A UPS publishes a great deal that is not battery state - line voltage, load, frequency, shutdown
timers, the beeper. None of it belongs in the power_supply class, and inventing a second power
supply to carry it is exactly the mistake ADR-001 records: UPower averaged the old `BAT1` load
meter into its `DisplayDevice` and reported a 100% UPS as a 34% battery.

So it is published read-only under `/sys/class/misc/fake_battery_nut/` instead, where scripts and
monitors can read it and nothing that walks the power_supply class ever sees it:

```
$ grep . /sys/class/misc/fake_battery_nut/{load,input_voltage,ups_type}
/sys/class/misc/fake_battery_nut/load:46 %
/sys/class/misc/fake_battery_nut/input_voltage:239200 mV
/sys/class/misc/fake_battery_nut/ups_type:offline / line interactive
```

| Attribute | NUT variable | Unit |
|-----------|--------------|------|
| `load` | ups.load | percent |
| `input_voltage` | input.voltage | mV |
| `output_voltage` | output.voltage | mV |
| `input_frequency` | input.frequency | mHz |
| `input_voltage_nominal` | input.voltage.nominal | mV |
| `input_frequency_nominal` | input.frequency.nominal | mHz |
| `input_current_nominal` | input.current.nominal | mA |
| `battery_voltage_nominal` | battery.voltage.nominal | mV |
| `delay_shutdown` | ups.delay.shutdown | seconds |
| `delay_start` | ups.delay.start | seconds |
| `beeper` | ups.beeper.status | 0 disabled, 1 enabled, 2 muted |
| `ups_type` | ups.type | string |
| `status_raw` | ups.status | string, verbatim |
| `manufacturer` | device.mfr | string |
| `model` | device.model, or driver.parameter.product | string |

Everything is scaled to integers - millivolts, millihertz, milliamperes - so no floating point is
needed anywhere in the kernel. A value the UPS does not publish reads `unknown` rather than `0`,
which would be indistinguishable from a real measurement.

## Data Mapping

| NUT Field | Control Command | power_supply Property |
|-----------|-----------------|----------------------|
| battery.charge | capacity | BAT0/capacity, BAT0/present |
| battery.voltage.high | voltage_max_design | BAT0/voltage_max_design |
| battery.voltage.low | voltage_min_design | BAT0/voltage_min_design |
| device.mfr | mfr | BAT0/manufacturer |
| device.model (or driver.parameter.product) | model | BAT0/model_name |
| device.serial | serial | BAT0/serial_number |
| ups.status `RB` | health | BAT0/health |
| battery.runtime | time | BAT0/time_to_empty_avg |
| battery.voltage | voltage | BAT0/voltage_now |
| battery.temperature (or ups.temperature) | temp | BAT0/temp |
| ups.status `OL`/`OB` | status, charging | BAT0/status, AC0/online |
| ups.status `CHRG`/`DISCHRG` | status | BAT0/status |
| ups.status `LB`/`FSD` | level, clamped capacity | BAT0/capacity_level, BAT0/capacity |

Status flags are matched as whole whitespace-delimited tokens, for the excellent reason that
`DISCHRG` contains `CHRG`.

**Deliberately not mapped:** `CHARGE_NOW`, `CHARGE_FULL` and `CHARGE_FULL_DESIGN` used to carry
the capacity percentage. The power_supply class defines those in µAh, so UPower dutifully
multiplied by the voltage and advertised a 0.00276 Wh battery. They are gone. Percentage stands
alone, which is all UPower wanted in the first place.

`TIME_TO_FULL_NOW` is gone for the same reason. NUT's `battery.runtime` is a discharge estimate,
and there is no time-to-full figure anywhere behind it - reporting one meant telling anything that
asked about a charging battery it would be full in however long it had left to live.

## Requirements

- Linux kernel headers
- NUT (nut package)
- bash 4+ and awk (both already on any system that has NUT). The daemon used to
  shell out to `bc` for one multiplication; it now does the extraction and the
  volts-to-microvolts scaling in a single `awk` pass, so `bc` is no longer a dependency.

## License

GPL v2 (same as original linux-fake-battery-module)

## Credits

Based on [linux-fake-battery-module](https://github.com/hoelzro/linux-fake-battery-module) by Rob Hoelz.

## See Also

- [ADR-001: Extended NUT Data Mapping](docs/architecture/001-extended-nut-data-mapping.md) - Architecture decisions and the UPower bridge discovery
