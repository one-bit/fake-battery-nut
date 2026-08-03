#!/bin/bash
# nut-to-fakebattery - Feed NUT UPS data to fake_battery_nut kernel module
#
# This daemon reads data from NUT and writes it to /dev/fake_battery_nut
# so that tools like btop and desktop environments (via UPower) can see
# UPS battery status.
#
# Control interface (one key=value per line, written as a single write):
#   capacity  0..100, or -1 = unknown
#   status    0=discharging 1=charging 2=full
#   charging  0..1                    (AC online)
#   level     0=derive from capacity, 1=critical, 2=low, 3=normal, 4=high, 5=full
#   time      -1 (unknown) or >= 0    seconds
#   voltage   -1 (unknown) or >= 0    microvolts
#   temp      -1 (unknown) or -400..1500   tenths of a degree C
# The module validates every line and applies the batch atomically: one bad
# value rejects the whole write. Never emit a partial value - emit the -1
# unknown sentinel instead, so a variable that vanishes from NUT clears the
# module's last known value rather than being republished forever.

DEVICE="/dev/fake_battery_nut"
UPS="${NUT_UPS:-cyberpower@localhost}"

# Seconds between polls, and how many consecutive failed polls are tolerated
# before the daemon gives up. A dead upsd/driver otherwise leaves the module
# serving its last values forever, which the desktop cannot distinguish from a
# healthy UPS on mains. On giving up the daemon clears the module's state (see
# publish_unknown) and exits non-zero, which hands the problem to systemd's
# Restart=on-failure and makes it visible in `systemctl status`.
POLL_INTERVAL=2
MAX_POLL_FAILURES=5

# Capacity written while the UPS asserts LB (low battery) or FSD.
#
# Policy, deliberate: UPower is commonly configured with PercentageAction=2 and
# CriticalPowerAction=PowerOff, so clamping to <= 2 would make UPower power the
# machine off - duplicating the shutdown upsmon already performs off the very
# same LB signal, and turning a spurious or flapping LB into an immediate
# poweroff. 5 is low enough for the desktop to raise a critical-battery warning
# while staying above the action threshold. upsmon stays the authority on
# shutdown; UPower's CriticalPowerAction remains a real backstop that only
# engages if the reported charge keeps falling on its own.
LB_CAPACITY="${NUT_LB_CAPACITY:-5}"

log() {
    logger -t nut-to-fakebattery "$@"
}

# Tell the module we no longer know anything, then leave.
#
# Exiting alone is not enough: the module goes on publishing whatever it was
# last told, so a dead upsd looks exactly like a healthy UPS sitting on mains
# at 100%. Systemd knows the daemon failed; the desktop does not, and the
# desktop is the whole point of this bridge. Clearing capacity to the unknown
# sentinel makes the battery report itself absent, which is at least true.
#
# status and charging are deliberately left alone - there is no "unknown" for
# either, and an absent battery already says enough. level is cleared so a
# stale LB override cannot outlive the data it came from.
publish_unknown() {
    printf 'capacity=-1\ntime=-1\nvoltage=-1\ntemp=-1\nlevel=0\n' > "$DEVICE" 2>/dev/null \
        || log "Could not clear $DEVICE on the way out; it keeps its last values"
}

# A non-integer or out-of-range clamp would be rejected by the module and take
# the whole batch down with it, so validate it once at startup.
case "$LB_CAPACITY" in
    ''|*[!0-9]*)
        log "Invalid NUT_LB_CAPACITY='$LB_CAPACITY', falling back to 5"
        LB_CAPACITY=5
        ;;
esac
if [ "$LB_CAPACITY" -gt 100 ]; then
    log "NUT_LB_CAPACITY=$LB_CAPACITY above 100, falling back to 5"
    LB_CAPACITY=5
fi

# Extract everything of interest from one upsc capture in a single awk pass.
# Emits exactly five lines, in order:
#   1 capacity   integer 0..100, or -1 when the UPS publishes no usable
#                battery.charge
#   2 time       seconds, or -1
#   3 voltage    microvolts, or -1
#   4 temp       tenths of a degree C, or -1
#   5 ups.status raw value, internal whitespace preserved so the flags can be
#                matched as whole tokens
parse_nut() {
    awk '
        function isnum(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) }
        {
            p = index($0, ":")
            if (p == 0) next
            key = substr($0, 1, p - 1)
            val = substr($0, p + 1)
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", key)
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", val)
            if (key == "battery.charge")           charge  = val
            else if (key == "battery.runtime")     runtime = val
            else if (key == "battery.voltage")     voltage = val
            else if (key == "battery.temperature") temp    = val
            else if (key == "ups.temperature")     upstemp = val
            else if (key == "ups.status")          status  = val
        }
        END {
            cap = "-1"
            if (isnum(charge)) {
                c = charge + 0
                # A negative charge is not a flat battery, it is a broken
                # reading, and 0 is the most dangerous value to guess: it is
                # what a critical-power action fires on. Report it unknown,
                # like every other out-of-band field. Clamping down from
                # above 100 is safe, so that one stays a clamp.
                if (c > 100) c = 100
                if (c >= 0)  cap = sprintf("%.0f", c)
            }

            secs = "-1"
            if (isnum(runtime)) {
                r = runtime + 0
                if (r >= 0 && r <= 2147483647) secs = sprintf("%.0f", r)
            }

            # NUT reports volts; the module wants microvolts. 2147 V is where a
            # 32-bit microvolt count overflows, so anything beyond it is junk.
            uv = "-1"
            if (isnum(voltage)) {
                v = voltage + 0
                if (v >= 0 && v <= 2147) uv = sprintf("%.0f", v * 1000000)
            }

            # NUT reports degrees C; the module wants tenths.
            if (temp == "") temp = upstemp
            tenths = "-1"
            if (isnum(temp)) {
                d = sprintf("%.0f", temp * 10) + 0
                if (d >= -400 && d <= 1500) tenths = sprintf("%d", d)
            }

            print cap
            print secs
            print uv
            print tenths
            print status
        }
    '
}

# Wait for device to appear
while [ ! -e "$DEVICE" ]; do
    log "Waiting for $DEVICE..."
    sleep "$POLL_INTERVAL"
done

log "Starting NUT to fake_battery_nut bridge for $UPS"

POLL_FAILURES=0
WRITE_FAILED=0

while true; do
    # Every derived value is cleared here: a variable that disappears from NUT
    # must not be carried over from the previous iteration.
    DATA=""
    FIELDS=()
    CAPACITY=""
    RUNTIME="-1"
    VOLTAGE_UV="-1"
    TEMP_TENTHS="-1"
    STATUS=""
    TOKENS=()
    ON_LINE=0
    ON_BATTERY=0
    CHRG_FLAG=0
    DISCHRG_FLAG=0
    LOW_BATTERY=0

    # Get all values in one upsc call
    if ! DATA=$(upsc "$UPS" 2>/dev/null) || [ -z "$DATA" ]; then
        POLL_FAILURES=$((POLL_FAILURES + 1))
        if [ "$POLL_FAILURES" -ge "$MAX_POLL_FAILURES" ]; then
            log "No data from $UPS for $POLL_FAILURES consecutive polls; exiting for restart"
            publish_unknown
            exit 1
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    POLL_FAILURES=0

    mapfile -t FIELDS < <(parse_nut <<< "$DATA")
    # parse_nut always emits five lines; anything else means awk did not run.
    # Falling through would publish a fabricated healthy state, so treat it as
    # a failed poll.
    if [ "${#FIELDS[@]}" -lt 5 ]; then
        POLL_FAILURES=$((POLL_FAILURES + 1))
        if [ "$POLL_FAILURES" -ge "$MAX_POLL_FAILURES" ]; then
            log "Could not parse upsc output for $POLL_FAILURES consecutive polls; exiting for restart"
            publish_unknown
            exit 1
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    CAPACITY="${FIELDS[0]:--1}"
    RUNTIME="${FIELDS[1]:--1}"
    VOLTAGE_UV="${FIELDS[2]:--1}"
    TEMP_TENTHS="${FIELDS[3]:--1}"
    STATUS="${FIELDS[4]}"

    # Match whitespace-delimited status flags exactly. Substring matching is
    # wrong here: DISCHRG contains CHRG.
    read -ra TOKENS <<< "$STATUS"
    for TOKEN in "${TOKENS[@]}"; do
        case "$TOKEN" in
            OL)      ON_LINE=1 ;;
            OB)      ON_BATTERY=1 ;;
            CHRG)    CHRG_FLAG=1 ;;
            DISCHRG) DISCHRG_FLAG=1 ;;
            LB|FSD)  LOW_BATTERY=1 ;;
        esac
    done

    # AC presence follows OL/OB only. A unit can discharge during a self-test
    # or battery calibration while mains is still present, so DISCHRG must not
    # clear it. With no status at all, assume mains: the alternative is telling
    # the desktop it is on battery on the strength of no evidence.
    AC_STATUS=1
    if [ "$ON_BATTERY" -eq 1 ]; then
        AC_STATUS=0
    elif [ "$ON_LINE" -eq 1 ]; then
        AC_STATUS=1
    fi

    # 0=discharging, 1=charging, 2=full
    if [ "$ON_BATTERY" -eq 1 ] || [ "$DISCHRG_FLAG" -eq 1 ]; then
        STATUS_VAL=0
    elif [ "$CHRG_FLAG" -eq 1 ]; then
        STATUS_VAL=1
    else
        STATUS_VAL=2
    fi

    # LB/FSD is the flag upsmon itself acts on. Surface it explicitly as the
    # critical capacity level, and clamp the reported percentage - UPower is
    # configured with UsePercentageForPolicy=true here, so the level alone
    # would change nothing. level=0 when the flag is absent so the override
    # clears again.
    LEVEL=0
    if [ "$LOW_BATTERY" -eq 1 ]; then
        LEVEL=1
        # The clamp also applies when the charge is unknown (-1): LB is a
        # statement from the UPS that it is about to run out, which is worth
        # reporting even with no percentage behind it. Without this the -1
        # would survive, the battery would report itself absent, and the one
        # moment the desktop most needs to react would go unannounced.
        if [ "$CAPACITY" -lt 0 ] || [ "$CAPACITY" -gt "$LB_CAPACITY" ]; then
            CAPACITY="$LB_CAPACITY"
        fi
    fi

    # Build the whole batch first and write it with one printf, so the module
    # sees a single all-or-nothing write.
    PAYLOAD=""
    PAYLOAD+="capacity=$CAPACITY"$'\n'
    PAYLOAD+="time=$RUNTIME"$'\n'
    PAYLOAD+="voltage=$VOLTAGE_UV"$'\n'
    PAYLOAD+="temp=$TEMP_TENTHS"$'\n'
    PAYLOAD+="status=$STATUS_VAL"$'\n'
    PAYLOAD+="charging=$AC_STATUS"$'\n'
    PAYLOAD+="level=$LEVEL"$'\n'

    if printf '%s' "$PAYLOAD" > "$DEVICE" 2>/dev/null; then
        if [ "$WRITE_FAILED" -eq 1 ]; then
            log "Writes to $DEVICE succeeding again"
            WRITE_FAILED=0
        fi
    elif [ "$WRITE_FAILED" -eq 0 ]; then
        # Edge-triggered: the module rejects a batch wholesale, and repeating
        # that every 2 s would only flood the journal.
        log "Write to $DEVICE rejected (capacity=$CAPACITY status=$STATUS_VAL charging=$AC_STATUS level=$LEVEL)"
        WRITE_FAILED=1
    fi

    sleep "$POLL_INTERVAL"
done
