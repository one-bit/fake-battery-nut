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
# Emits exactly 21 lines, one field per line, in the order listed below. A
# field the UPS does not publish comes out as -1 (numeric) or empty (string),
# never omitted, so the line numbering is stable.
#
#   1 capacity                  percent, or -1
#   2 time                      seconds, or -1
#   3 voltage                   microvolts, or -1
#   4 temp                      tenths of a degree C, or -1
#   5 voltage_max_design        microvolts, or -1
#   6 voltage_min_design        microvolts, or -1
#   7 battery_voltage_nominal   millivolts, or -1
#   8 load                      percent, or -1
#   9 input_voltage             millivolts, or -1
#  10 output_voltage            millivolts, or -1
#  11 input_frequency           millihertz, or -1
#  12 input_voltage_nominal     millivolts, or -1
#  13 input_frequency_nominal   millihertz, or -1
#  14 input_current_nominal     milliamperes, or -1
#  15 delay_shutdown            seconds, or -1
#  16 delay_start               seconds, or -1
#  17 beeper                    0 disabled, 1 enabled, 2 muted, or -1
#  18 mfr                       string
#  19 model                     string
#  20 ups_type                  string
#  21 status_raw                string, internal whitespace preserved so the
#                               flags can be matched as whole tokens
parse_nut() {
    awk '
        function isnum(s) { return (s ~ /^-?[0-9]+(\.[0-9]+)?$/) }
        # Scale a numeric NUT value, or return -1 when it is missing, junk, or
        # outside what a 32-bit field can carry.
        function scaled(v, mult,    n) {
            if (!isnum(v)) return "-1"
            n = v * mult
            if (n < 0 || n > 2147483647) return "-1"
            return sprintf("%.0f", n)
        }
        # The module rejects non-printable characters and anything over 31
        # bytes, and one bad line rejects the whole batch, so clean here.
        function clean(s) {
            gsub(/[^ -~]/, "", s)
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            return substr(s, 1, 31)
        }
        {
            p = index($0, ":")
            if (p == 0) next
            key = substr($0, 1, p - 1)
            val = substr($0, p + 1)
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", key)
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", val)
            v[key] = val
        }
        END {
            # Capacity: a negative reading is broken, not flat. 0 is the most
            # dangerous value to guess, so report it unknown like every other
            # out-of-band field. Clamping down from above 100 is safe.
            cap = "-1"
            if (isnum(v["battery.charge"])) {
                c = v["battery.charge"] + 0
                if (c > 100) c = 100
                if (c >= 0)  cap = sprintf("%.0f", c)
            }

            # Temperature is the one field with a legitimate negative range.
            tenths = "-1"
            temp = (v["battery.temperature"] != "") ? v["battery.temperature"] : v["ups.temperature"]
            if (isnum(temp)) {
                d = sprintf("%.0f", temp * 10) + 0
                if (d >= -400 && d <= 1500) tenths = sprintf("%d", d)
            }

            beeper = "-1"
            if (v["ups.beeper.status"] == "disabled") beeper = "0"
            else if (v["ups.beeper.status"] == "enabled") beeper = "1"
            else if (v["ups.beeper.status"] == "muted") beeper = "2"

            # NUT does not always publish device.model; the driver knows the
            # product string it matched on, which is the next best thing.
            model = (v["device.model"] != "") ? v["device.model"] : v["driver.parameter.product"]

            print cap
            print scaled(v["battery.runtime"], 1)
            print scaled(v["battery.voltage"], 1000000)
            print tenths
            print scaled(v["battery.voltage.high"], 1000000)
            print scaled(v["battery.voltage.low"], 1000000)
            print scaled(v["battery.voltage.nominal"], 1000)
            print scaled(v["ups.load"], 1)
            print scaled(v["input.voltage"], 1000)
            print scaled(v["output.voltage"], 1000)
            print scaled(v["input.frequency"], 1000)
            print scaled(v["input.voltage.nominal"], 1000)
            print scaled(v["input.frequency.nominal"], 1000)
            print scaled(v["input.current.nominal"], 1000)
            print scaled(v["ups.delay.shutdown"], 1)
            print scaled(v["ups.delay.start"], 1)
            print beeper
            print clean(v["device.mfr"])
            print clean(model)
            print clean(v["ups.type"])
            print clean(v["ups.status"])
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
    VOLT_MAX_DESIGN="-1"
    VOLT_MIN_DESIGN="-1"
    BATT_VOLT_NOMINAL="-1"
    LOAD="-1"
    INPUT_VOLTAGE="-1"
    OUTPUT_VOLTAGE="-1"
    INPUT_FREQ="-1"
    INPUT_VOLTAGE_NOM="-1"
    INPUT_FREQ_NOM="-1"
    INPUT_CURRENT_NOM="-1"
    DELAY_SHUTDOWN="-1"
    DELAY_START="-1"
    BEEPER="-1"
    MFR=""
    MODEL=""
    UPS_TYPE=""
    REPLACE_BATTERY=0
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
    if [ "${#FIELDS[@]}" -lt 21 ]; then
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
    VOLT_MAX_DESIGN="${FIELDS[4]:--1}"
    VOLT_MIN_DESIGN="${FIELDS[5]:--1}"
    BATT_VOLT_NOMINAL="${FIELDS[6]:--1}"
    LOAD="${FIELDS[7]:--1}"
    INPUT_VOLTAGE="${FIELDS[8]:--1}"
    OUTPUT_VOLTAGE="${FIELDS[9]:--1}"
    INPUT_FREQ="${FIELDS[10]:--1}"
    INPUT_VOLTAGE_NOM="${FIELDS[11]:--1}"
    INPUT_FREQ_NOM="${FIELDS[12]:--1}"
    INPUT_CURRENT_NOM="${FIELDS[13]:--1}"
    DELAY_SHUTDOWN="${FIELDS[14]:--1}"
    DELAY_START="${FIELDS[15]:--1}"
    BEEPER="${FIELDS[16]:--1}"
    MFR="${FIELDS[17]}"
    MODEL="${FIELDS[18]}"
    UPS_TYPE="${FIELDS[19]}"
    STATUS="${FIELDS[20]}"

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
            RB)      REPLACE_BATTERY=1 ;;
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
    # RB is the UPS asking for a new battery. It says nothing about the
    # current charge, so it maps to health rather than to any capacity signal.
    HEALTH=0
    if [ "$REPLACE_BATTERY" -eq 1 ]; then
        HEALTH=1
    fi

    PAYLOAD=""
    PAYLOAD+="capacity=$CAPACITY"$'\n'
    PAYLOAD+="time=$RUNTIME"$'\n'
    PAYLOAD+="voltage=$VOLTAGE_UV"$'\n'
    PAYLOAD+="temp=$TEMP_TENTHS"$'\n'
    PAYLOAD+="status=$STATUS_VAL"$'\n'
    PAYLOAD+="charging=$AC_STATUS"$'\n'
    PAYLOAD+="level=$LEVEL"$'\n'
    PAYLOAD+="health=$HEALTH"$'\n'
    PAYLOAD+="voltage_max_design=$VOLT_MAX_DESIGN"$'\n'
    PAYLOAD+="voltage_min_design=$VOLT_MIN_DESIGN"$'\n'
    PAYLOAD+="battery_voltage_nominal=$BATT_VOLT_NOMINAL"$'\n'
    PAYLOAD+="load=$LOAD"$'\n'
    PAYLOAD+="input_voltage=$INPUT_VOLTAGE"$'\n'
    PAYLOAD+="output_voltage=$OUTPUT_VOLTAGE"$'\n'
    PAYLOAD+="input_frequency=$INPUT_FREQ"$'\n'
    PAYLOAD+="input_voltage_nominal=$INPUT_VOLTAGE_NOM"$'\n'
    PAYLOAD+="input_frequency_nominal=$INPUT_FREQ_NOM"$'\n'
    PAYLOAD+="input_current_nominal=$INPUT_CURRENT_NOM"$'\n'
    PAYLOAD+="delay_shutdown=$DELAY_SHUTDOWN"$'\n'
    PAYLOAD+="delay_start=$DELAY_START"$'\n'
    PAYLOAD+="beeper=$BEEPER"$'\n'
    # Strings are only sent when the UPS actually published them: an empty
    # value would be a valid write that blanks a previously known name.
    [ -n "$MFR" ]      && PAYLOAD+="mfr=$MFR"$'\n'
    [ -n "$MODEL" ]    && PAYLOAD+="model=$MODEL"$'\n'
    [ -n "$UPS_TYPE" ] && PAYLOAD+="ups_type=$UPS_TYPE"$'\n'
    [ -n "$STATUS" ]   && PAYLOAD+="status_raw=$STATUS"$'\n'

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
