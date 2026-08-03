/*
 * fake_battery_nut - Kernel module to expose NUT UPS data as power_supply
 *
 * Based on linux-fake-battery-module by Rob Hoelz
 * Modified to support NUT (Network UPS Tools) data passthrough
 *
 * Control interface: /dev/fake_battery_nut
 *
 * Commands are "key=value" lines, one per line, newline terminated, delivered
 * in a single write().  A write is transactional: every line is parsed and
 * validated into a private copy of the state, and that copy is committed only
 * if the whole write validated.  A rejected write leaves the published state
 * completely unchanged.
 *
 *   capacity=N    - Battery capacity, 0-100 percent - maps to UPS battery
 *                   charge, or -1 = unknown.  An unknown capacity also reports
 *                   the battery as not present and its level as UNKNOWN, so
 *                   that missing data is never mistaken for a flat battery.
 *   status=N      - Set status (0=discharging, 1=charging, 2=full)
 *   charging=N    - Set AC online status (0=offline, 1=online)
 *   level=N       - Capacity level override, 0-5:
 *                     0 = derive from capacity (the default),
 *                     1 = critical, 2 = low, 3 = normal, 4 = high, 5 = full
 *                   A non-zero level overrides the capacity-derived level
 *                   until level=0 is written again.  The derived level keeps
 *                   tracking capacity in the background while overridden, so
 *                   clearing the override does the right thing immediately.
 *   time=N        - Set time_to_empty in seconds - maps to UPS runtime,
 *                   or -1 = unknown
 *   voltage=N     - Set voltage in microvolts, or -1 = unknown
 *   temp=N        - Set temperature in tenths of °C (e.g., 260 = 26.0°C),
 *                   range -400..1500, or -1 = unknown
 *
 * The -1 sentinel means "the UPS does not publish this".  The matching
 * property then reports -ENODATA, so the sysfs attribute errors out and
 * consumers such as UPower omit the value instead of being handed a
 * fabricated one.  time, voltage and temp all start out unknown at load time
 * for exactly that reason - nothing is known until the daemon says so.
 *
 * Keys are matched exactly.  An unrecognised key is rejected with -EINVAL, a
 * line with no '=' with -EINVAL, and an out-of-range value with -ERANGE.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 */

#include <linux/ctype.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/power_supply.h>
#include <linux/spinlock.h>
#include <linux/string.h>

#include <linux/uaccess.h>

/* Value meaning "the UPS does not publish this" for time, voltage and temp */
#define VALUE_UNKNOWN (-1)

#define TEMP_MIN (-400)   /* -40.0°C in tenths */
#define TEMP_MAX (1500)   /* 150.0°C in tenths */

#define STR_MAX 32

/*
 * Everything a UPS publishes that is not battery state.
 *
 * None of this belongs in the power_supply class: line voltage, load and
 * shutdown timers are not properties of a battery, and inventing a second
 * power supply to carry them is what produced the BAT1 mistake described in
 * ADR-001 (UPower averaged it into DisplayDevice and reported nonsense).  It
 * is published read-only under /sys/class/misc/fake_battery_nut/ instead,
 * where it is available to scripts and monitors without confusing anything
 * that reads the power_supply class.
 *
 * Integer fields are VALUE_UNKNOWN when the UPS does not publish them, and
 * scaled so no floating point is needed: millivolts, millihertz,
 * milliamperes, whole seconds, whole percent.  Strings are empty when
 * unknown.  Field order keeps the ints together so the struct has no interior
 * padding and can be compared with memcmp().
 */
struct ups_extra {
    int load;                     /* percent */
    int input_voltage;            /* mV */
    int output_voltage;           /* mV */
    int input_frequency;          /* mHz */
    int input_voltage_nominal;    /* mV */
    int input_frequency_nominal;  /* mHz */
    int input_current_nominal;    /* mA */
    int battery_voltage_nominal;  /* mV */
    int delay_shutdown;           /* seconds */
    int delay_start;              /* seconds */
    int beeper;                   /* 0 disabled, 1 enabled, 2 muted */
    char mfr[STR_MAX];
    char model[STR_MAX];
    char serial[STR_MAX];
    char ups_type[STR_MAX];
    char status_raw[STR_MAX];
};

static struct ups_extra fake_ups_extra = {
    .load                    = VALUE_UNKNOWN,
    .input_voltage           = VALUE_UNKNOWN,
    .output_voltage          = VALUE_UNKNOWN,
    .input_frequency         = VALUE_UNKNOWN,
    .input_voltage_nominal   = VALUE_UNKNOWN,
    .input_frequency_nominal = VALUE_UNKNOWN,
    .input_current_nominal   = VALUE_UNKNOWN,
    .battery_voltage_nominal = VALUE_UNKNOWN,
    .delay_shutdown          = VALUE_UNKNOWN,
    .delay_start             = VALUE_UNKNOWN,
    .beeper                  = VALUE_UNKNOWN,
};

/*
 * MANUFACTURER, MODEL_NAME and SERIAL_NUMBER are string properties:
 * get_property hands the power_supply core a pointer, and the core formats it
 * after we have returned, outside any lock we hold.  Pointing it at a buffer a
 * concurrent write could be rewriting would let it format a half-updated
 * string, so the strings are double buffered - writers fill the inactive bank
 * and then flip the index, and a reader that took the old index keeps reading
 * a bank nobody is touching.
 */
enum { PS_STR_MFR, PS_STR_MODEL, PS_STR_SERIAL, PS_STR_COUNT };
static char ps_strings[2][PS_STR_COUNT][STR_MAX] = {
    { "NUT", "UPS Battery", "" },
    { "NUT", "UPS Battery", "" },
};
static int ps_string_bank;

static int
fake_battery_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val);

static int
fake_ac_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val);

static struct battery_status {
    int status;
    int capacity_level;           /* always derived from capacity */
    int capacity_level_override;  /* 0 = none, else POWER_SUPPLY_CAPACITY_LEVEL_* */
    int capacity;
    int time_left;
    int voltage;
    int temp;
    int voltage_max_design;   /* uV, from the UPS's full/high battery voltage */
    int voltage_min_design;   /* uV, from the UPS's empty/low battery voltage */
    int health;               /* POWER_SUPPLY_HEALTH_* */
} fake_battery_status = {
    .status = POWER_SUPPLY_STATUS_FULL,
    .capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_FULL,
    .capacity_level_override = 0,
    .capacity = 100,
    .time_left = VALUE_UNKNOWN,
    .voltage = VALUE_UNKNOWN,
    .temp = VALUE_UNKNOWN,
    .voltage_max_design = VALUE_UNKNOWN,
    .voltage_min_design = VALUE_UNKNOWN,
    .health = POWER_SUPPLY_HEALTH_GOOD,
};

static int ac_status = 1;

/*
 * fake_battery_status and ac_status are written from the control device and
 * read from the property handlers, which the power_supply core may call
 * concurrently on another CPU and, for some callers, from atomic context.
 * That rules out a mutex for the data itself, so a spinlock guards it.
 * Readers hold it just long enough to snapshot the whole struct, which also
 * keeps the fields mutually consistent - "1% and on mains" is exactly the
 * torn combination that matters here.
 *
 * control_write_lock is a separate mutex that serialises writers only.  The
 * write path snapshots the state, parses into the snapshot and commits it, so
 * without it two concurrent writers could lose one another's updates.
 * Writers are always in process context, so a mutex is the right primitive
 * there and it is never held across a copy_from_user().
 */
static DEFINE_SPINLOCK(fake_battery_lock);
static DEFINE_MUTEX(control_write_lock);

static char *fake_ac_supplies[] = {
    "BAT0",
};

static enum power_supply_property fake_battery_properties[] = {
    POWER_SUPPLY_PROP_STATUS,
    POWER_SUPPLY_PROP_CHARGE_TYPE,
    POWER_SUPPLY_PROP_HEALTH,
    POWER_SUPPLY_PROP_PRESENT,
    POWER_SUPPLY_PROP_TECHNOLOGY,
    POWER_SUPPLY_PROP_CAPACITY,
    POWER_SUPPLY_PROP_CAPACITY_LEVEL,
    /*
     * Only time-to-empty. NUT's battery.runtime is the discharge estimate;
     * there is no time-to-full figure behind it, and reporting the discharge
     * runtime as TIME_TO_FULL_NOW told anything reading a charging battery
     * that it would be full in however long it had left.
     */
    POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
    POWER_SUPPLY_PROP_MODEL_NAME,
    POWER_SUPPLY_PROP_MANUFACTURER,
    POWER_SUPPLY_PROP_SERIAL_NUMBER,
    POWER_SUPPLY_PROP_TEMP,
    POWER_SUPPLY_PROP_VOLTAGE_NOW,
    POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN,
    POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
};

static enum power_supply_property fake_ac_properties[] = {
    POWER_SUPPLY_PROP_ONLINE,
};

static struct power_supply_desc descriptions[] = {
    {
        .name = "BAT0",
        .type = POWER_SUPPLY_TYPE_BATTERY,
        .properties = fake_battery_properties,
        .num_properties = ARRAY_SIZE(fake_battery_properties),
        .get_property = fake_battery_get_property,
    },

    {
        .name = "AC0",
        .type = POWER_SUPPLY_TYPE_MAINS,
        .properties = fake_ac_properties,
        .num_properties = ARRAY_SIZE(fake_ac_properties),
        .get_property = fake_ac_get_property,
    },
};

static struct power_supply_config configs[] = {
    { },
    {
        .supplied_to = fake_ac_supplies,
        .num_supplicants = ARRAY_SIZE(fake_ac_supplies),
    },
};

static struct power_supply *supplies[sizeof(descriptions) / sizeof(descriptions[0])];

static ssize_t
control_device_read(struct file *file, char *buffer, size_t count, loff_t *ppos)
{
    static char *message = "fake_battery_nut: capacity, time, voltage, temp, status, charging, level\n";
    size_t message_len = strlen(message);

    if(count < message_len) {
        return -EINVAL;
    }

    if(*ppos != 0) {
        return 0;
    }

    if(copy_to_user(buffer, message, message_len)) {
        return -EINVAL;
    }

    *ppos = message_len;

    return message_len;
}

static int
capacity_to_level(int capacity)
{
    /*
     * An unknown charge must not fall through the thresholds below - the
     * lowest of them is CRITICAL, so treating "no reading" as a number would
     * report a flat battery on missing data, which is exactly the direction
     * that gets a machine powered off.
     */
    if(capacity == VALUE_UNKNOWN) {
        return POWER_SUPPLY_CAPACITY_LEVEL_UNKNOWN;
    }

    if(capacity >= 98) {
        return POWER_SUPPLY_CAPACITY_LEVEL_FULL;
    } else if(capacity >= 70) {
        return POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
    } else if(capacity >= 30) {
        return POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
    } else if(capacity >= 5) {
        return POWER_SUPPLY_CAPACITY_LEVEL_LOW;
    }

    return POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
}

/* Maps the level= command value onto the power_supply level, 0 = no override */
static int
level_to_capacity_level(long level)
{
    switch(level) {
        case 1:
            return POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
        case 2:
            return POWER_SUPPLY_CAPACITY_LEVEL_LOW;
        case 3:
            return POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
        case 4:
            return POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
        case 5:
            return POWER_SUPPLY_CAPACITY_LEVEL_FULL;
        default:
            return 0;
    }
}

/*
 * Parses one "key=value" line into the caller's copy of the state.  The line
 * is modified in place (it is split at the '='), and nothing global is
 * touched, so a failure here leaves the published state untouched.
 */
static int
handle_control_line(char *line, int *ac_status, struct battery_status *battery,
        struct ups_extra *extra)
{
    char *key;
    char *key_end;
    char *value_p;
    char *value_end;
    long value;
    int ret;

    value_p = strchr(line, '=');

    if(!value_p) {
        return -EINVAL;
    }

    /* Split at the '=' so the key can be compared exactly, not by prefix */
    *value_p = '\0';
    key_end  = value_p;
    key      = skip_spaces(line);

    while(key_end > key && isspace(key_end[-1])) {
        *--key_end = '\0';
    }

    value_p   = skip_spaces(value_p + 1);
    value_end = value_p + strlen(value_p);

    /*
     * Trim trailing whitespace (and any \r) from the value too.  kstrtol
     * tolerates a single trailing newline but nothing else, and a write is
     * now all-or-nothing, so one stray space from a shell pipeline would
     * otherwise reject the whole batch.
     */
    while(value_end > value_p && isspace(value_end[-1])) {
        *--value_end = '\0';
    }

    /*
     * String-valued keys are handled before the numeric parse, since they are
     * not numbers.  Anything non-printable is rejected rather than sanitised:
     * these end up in sysfs, and a control character there is a bug worth
     * hearing about, not something to quietly paper over.
     */
    if(!strcmp(key, "mfr") || !strcmp(key, "model") || !strcmp(key, "serial") ||
            !strcmp(key, "ups_type") || !strcmp(key, "status_raw")) {
        char *dest;
        size_t len = strlen(value_p);
        size_t i;

        if(len >= STR_MAX) {
            return -ERANGE;
        }

        for(i = 0; i < len; i++) {
            if(!isprint(value_p[i])) {
                return -EINVAL;
            }
        }

        if(!strcmp(key, "mfr")) {
            dest = extra->mfr;
        } else if(!strcmp(key, "model")) {
            dest = extra->model;
        } else if(!strcmp(key, "serial")) {
            dest = extra->serial;
        } else if(!strcmp(key, "ups_type")) {
            dest = extra->ups_type;
        } else {
            dest = extra->status_raw;
        }

        strscpy(dest, value_p, STR_MAX);
        return 0;
    }

    ret = kstrtol(value_p, 10, &value);

    if(ret) {
        return ret;
    }

    if(!strcmp(key, "capacity")) {
        if(value != VALUE_UNKNOWN && (value < 0 || value > 100)) {
            return -ERANGE;
        }
        battery->capacity = value;
        /* Keep the derived level current even while an override is active */
        battery->capacity_level = capacity_to_level(value);
    } else if(!strcmp(key, "level")) {
        if(value < 0 || value > 5) {
            return -ERANGE;
        }
        battery->capacity_level_override = level_to_capacity_level(value);
    } else if(!strcmp(key, "status")) {
        switch(value) {
            case 0:
                battery->status = POWER_SUPPLY_STATUS_DISCHARGING;
                break;
            case 1:
                battery->status = POWER_SUPPLY_STATUS_CHARGING;
                break;
            case 2:
                battery->status = POWER_SUPPLY_STATUS_FULL;
                break;
            default:
                return -ERANGE;
        }
    } else if(!strcmp(key, "charging")) {
        if(value < 0 || value > 1) {
            return -ERANGE;
        }
        *ac_status = value;
    } else if(!strcmp(key, "time")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        battery->time_left = value;
    } else if(!strcmp(key, "voltage")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        battery->voltage = value;
    } else if(!strcmp(key, "temp")) {
        if(value < TEMP_MIN || value > TEMP_MAX) {
            return -ERANGE;
        }
        battery->temp = value;
    } else if(!strcmp(key, "voltage_max_design")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        battery->voltage_max_design = value;
    } else if(!strcmp(key, "voltage_min_design")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        battery->voltage_min_design = value;
    } else if(!strcmp(key, "health")) {
        switch(value) {
            case 0:
                battery->health = POWER_SUPPLY_HEALTH_GOOD;
                break;
            case 1:
                /* NUT's RB - the UPS is asking for a new battery */
                battery->health = POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
                break;
            case 2:
                battery->health = POWER_SUPPLY_HEALTH_OVERVOLTAGE;
                break;
            case 3:
                battery->health = POWER_SUPPLY_HEALTH_DEAD;
                break;
            default:
                return -ERANGE;
        }
    } else if(!strcmp(key, "load")) {
        if(value < VALUE_UNKNOWN || value > 1000) {
            return -ERANGE;
        }
        extra->load = value;
    } else if(!strcmp(key, "beeper")) {
        if(value < VALUE_UNKNOWN || value > 2) {
            return -ERANGE;
        }
        extra->beeper = value;
    } else if(!strcmp(key, "input_voltage")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->input_voltage = value;
    } else if(!strcmp(key, "output_voltage")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->output_voltage = value;
    } else if(!strcmp(key, "input_frequency")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->input_frequency = value;
    } else if(!strcmp(key, "input_voltage_nominal")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->input_voltage_nominal = value;
    } else if(!strcmp(key, "input_frequency_nominal")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->input_frequency_nominal = value;
    } else if(!strcmp(key, "input_current_nominal")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->input_current_nominal = value;
    } else if(!strcmp(key, "battery_voltage_nominal")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->battery_voltage_nominal = value;
    } else if(!strcmp(key, "delay_shutdown")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->delay_shutdown = value;
    } else if(!strcmp(key, "delay_start")) {
        if(value < VALUE_UNKNOWN || value > INT_MAX) {
            return -ERANGE;
        }
        extra->delay_start = value;
    } else {
        return -EINVAL;
    }

    return 0;
}

static ssize_t
control_device_write(struct file *file, const char *buffer, size_t count, loff_t *ppos)
{
    /*
     * Why a batch of separate write()s to one open fd all land:
     * ksys_write() copies f_pos into a local, passes that local to this
     * handler and copies it back afterwards.  This handler never advances
     * *ppos, so every write - including each echo of a
     * `{ echo a=1; echo b=2; } > /dev/fake_battery_nut` batch - arrives at
     * offset 0 and passes the check below.
     *
     * The hazard to watch for is a future change that starts advancing
     * *ppos: the second and later writes of a batch would then be rejected.
     * (This has nothing to do with .llseek - adding one would not break the
     * daemon, which never seeks.)
     */
    struct battery_status new_status;
    struct ups_extra new_extra;
    char kbuffer[1025];
    char *buffer_cursor;
    char *newline;
    size_t bytes_left = count;
    unsigned long flags;
    bool battery_changed;
    bool ac_changed;
    bool strings_changed;
    int bank;
    int new_ac_status;
    int status;

    if(*ppos != 0) {
        printk(KERN_ERR "writes to /dev/fake_battery_nut must be completed in a single system call\n");
        return -EINVAL;
    }

    if(count == 0) {
        return 0;
    }

    if(count >= sizeof(kbuffer)) {
        printk(KERN_ERR "Too much data provided to /dev/fake_battery_nut (limit %zu bytes)\n",
                sizeof(kbuffer) - 1);
        return -EINVAL;
    }

    status = copy_from_user(kbuffer, buffer, count);

    if(status != 0) {
        printk(KERN_ERR "bad copy_from_user\n");
        return -EFAULT;
    }

    /* Always terminated inside the data actually supplied */
    kbuffer[count] = '\0';

    mutex_lock(&control_write_lock);

    spin_lock_irqsave(&fake_battery_lock, flags);
    new_status    = fake_battery_status;
    new_extra     = fake_ups_extra;
    new_ac_status = ac_status;
    spin_unlock_irqrestore(&fake_battery_lock, flags);

    buffer_cursor = kbuffer;

    while((newline = memchr(buffer_cursor, '\n', bytes_left))) {
        *newline = '\0';
        status = handle_control_line(buffer_cursor, &new_ac_status, &new_status,
                &new_extra);

        if(status) {
            mutex_unlock(&control_write_lock);
            return status;
        }

        bytes_left    -= (newline - buffer_cursor) + 1;
        buffer_cursor  = newline + 1;
    }

    if(bytes_left != 0) {
        printk(KERN_ERR "writes to /dev/fake_battery_nut must end with a newline\n");
        mutex_unlock(&control_write_lock);
        return -EINVAL;
    }

    /* Everything validated - commit the batch as a unit */
    spin_lock_irqsave(&fake_battery_lock, flags);
    battery_changed = memcmp(&new_status, &fake_battery_status, sizeof(new_status)) != 0;
    ac_changed      = new_ac_status != ac_status;
    strings_changed = strcmp(new_extra.mfr, fake_ups_extra.mfr) ||
                      strcmp(new_extra.model, fake_ups_extra.model) ||
                      strcmp(new_extra.serial, fake_ups_extra.serial);
    fake_battery_status = new_status;
    fake_ups_extra      = new_extra;
    ac_status           = new_ac_status;
    spin_unlock_irqrestore(&fake_battery_lock, flags);

    /*
     * Republish the power_supply strings into the inactive bank and flip.
     * Only writers touch this and they are serialised by control_write_lock,
     * so the bank being filled is never the one readers are looking at.  An
     * empty string means "not published", in which case the previous default
     * is kept rather than showing a blank manufacturer.
     */
    if(strings_changed) {
        bank = !READ_ONCE(ps_string_bank);
        if(new_extra.mfr[0]) {
            strscpy(ps_strings[bank][PS_STR_MFR], new_extra.mfr, STR_MAX);
        }
        if(new_extra.model[0]) {
            strscpy(ps_strings[bank][PS_STR_MODEL], new_extra.model, STR_MAX);
        }
        if(new_extra.serial[0]) {
            strscpy(ps_strings[bank][PS_STR_SERIAL], new_extra.serial, STR_MAX);
        }
        /* Contents must be visible before the index that publishes them */
        smp_wmb();
        WRITE_ONCE(ps_string_bank, bank);
    }

    mutex_unlock(&control_write_lock);

    if(battery_changed) {
        power_supply_changed(supplies[0]);
    }

    if(ac_changed) {
        power_supply_changed(supplies[1]);
    }

    return count;
}

static const struct file_operations control_device_ops = {
    .owner = THIS_MODULE,
    .read = control_device_read,
    .write = control_device_write,
};

/*
 * The UPS telemetry that has no power_supply equivalent, published read-only
 * under /sys/class/misc/fake_battery_nut/.  A value the UPS does not report
 * reads as "unknown" rather than as a zero that cannot be told apart from a
 * real measurement.
 */
static ssize_t show_extra_int(char *buf, int value, const char *unit)
{
    if(value == VALUE_UNKNOWN) {
        return sysfs_emit(buf, "unknown\n");
    }

    return sysfs_emit(buf, "%d%s\n", value, unit);
}

#define UPS_EXTRA_INT_ATTR(name, field, unit)                                 \
static ssize_t name##_show(struct device *dev,                                \
        struct device_attribute *attr, char *buf)                             \
{                                                                             \
    struct ups_extra snapshot;                                                \
    unsigned long flags;                                                      \
                                                                              \
    spin_lock_irqsave(&fake_battery_lock, flags);                             \
    snapshot = fake_ups_extra;                                                \
    spin_unlock_irqrestore(&fake_battery_lock, flags);                        \
                                                                              \
    return show_extra_int(buf, snapshot.field, unit);                         \
}                                                                             \
static DEVICE_ATTR_RO(name)

#define UPS_EXTRA_STR_ATTR(name, field)                                       \
static ssize_t name##_show(struct device *dev,                                \
        struct device_attribute *attr, char *buf)                             \
{                                                                             \
    struct ups_extra snapshot;                                                \
    unsigned long flags;                                                      \
                                                                              \
    spin_lock_irqsave(&fake_battery_lock, flags);                             \
    snapshot = fake_ups_extra;                                                \
    spin_unlock_irqrestore(&fake_battery_lock, flags);                        \
                                                                              \
    if(!snapshot.field[0]) {                                                  \
        return sysfs_emit(buf, "unknown\n");                                  \
    }                                                                         \
                                                                              \
    return sysfs_emit(buf, "%s\n", snapshot.field);                           \
}                                                                             \
static DEVICE_ATTR_RO(name)

UPS_EXTRA_INT_ATTR(load,                    load,                    " %");
UPS_EXTRA_INT_ATTR(input_voltage,           input_voltage,           " mV");
UPS_EXTRA_INT_ATTR(output_voltage,          output_voltage,          " mV");
UPS_EXTRA_INT_ATTR(input_frequency,         input_frequency,         " mHz");
UPS_EXTRA_INT_ATTR(input_voltage_nominal,   input_voltage_nominal,   " mV");
UPS_EXTRA_INT_ATTR(input_frequency_nominal, input_frequency_nominal, " mHz");
UPS_EXTRA_INT_ATTR(input_current_nominal,   input_current_nominal,   " mA");
UPS_EXTRA_INT_ATTR(battery_voltage_nominal, battery_voltage_nominal, " mV");
UPS_EXTRA_INT_ATTR(delay_shutdown,          delay_shutdown,          " s");
UPS_EXTRA_INT_ATTR(delay_start,             delay_start,             " s");
UPS_EXTRA_INT_ATTR(beeper,                  beeper,                  "");
UPS_EXTRA_STR_ATTR(ups_type,                ups_type);
UPS_EXTRA_STR_ATTR(status_raw,              status_raw);
UPS_EXTRA_STR_ATTR(manufacturer,            mfr);
UPS_EXTRA_STR_ATTR(model,                   model);

static struct attribute *fake_battery_nut_attrs[] = {
    &dev_attr_load.attr,
    &dev_attr_input_voltage.attr,
    &dev_attr_output_voltage.attr,
    &dev_attr_input_frequency.attr,
    &dev_attr_input_voltage_nominal.attr,
    &dev_attr_input_frequency_nominal.attr,
    &dev_attr_input_current_nominal.attr,
    &dev_attr_battery_voltage_nominal.attr,
    &dev_attr_delay_shutdown.attr,
    &dev_attr_delay_start.attr,
    &dev_attr_beeper.attr,
    &dev_attr_ups_type.attr,
    &dev_attr_status_raw.attr,
    &dev_attr_manufacturer.attr,
    &dev_attr_model.attr,
    NULL,
};
ATTRIBUTE_GROUPS(fake_battery_nut);

static struct miscdevice control_device = {
    .minor  = MISC_DYNAMIC_MINOR,
    .name   = "fake_battery_nut",
    .fops   = &control_device_ops,
    .groups = fake_battery_nut_groups,
};

static int
fake_battery_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val)
{
    struct battery_status status;
    unsigned long flags;

    spin_lock_irqsave(&fake_battery_lock, flags);
    status = fake_battery_status;
    spin_unlock_irqrestore(&fake_battery_lock, flags);

    switch (psp) {
        case POWER_SUPPLY_PROP_MANUFACTURER:
            val->strval = ps_strings[READ_ONCE(ps_string_bank)][PS_STR_MFR];
            break;
        case POWER_SUPPLY_PROP_MODEL_NAME:
            val->strval = ps_strings[READ_ONCE(ps_string_bank)][PS_STR_MODEL];
            break;
        case POWER_SUPPLY_PROP_SERIAL_NUMBER:
            val->strval = ps_strings[READ_ONCE(ps_string_bank)][PS_STR_SERIAL];
            if(!val->strval[0]) {
                return -ENODATA;
            }
            break;
        case POWER_SUPPLY_PROP_STATUS:
            val->intval = status.status;
            break;
        case POWER_SUPPLY_PROP_CHARGE_TYPE:
            val->intval = POWER_SUPPLY_CHARGE_TYPE_FAST;
            break;
        case POWER_SUPPLY_PROP_HEALTH:
            val->intval = status.health;
            break;
        case POWER_SUPPLY_PROP_PRESENT:
            /*
             * With no charge reading there is nothing to bridge, so report the
             * battery as absent rather than as a battery of unknown charge.
             * Userspace that cannot read a percentage tends to fall back to
             * deriving one, and with no CHARGE_* or energy properties to derive
             * from it can settle on 0% - indistinguishable from a flat battery,
             * and enough to trigger a critical-power action. Absent is both
             * honest and the safe direction to be wrong in.
             */
            val->intval = status.capacity != VALUE_UNKNOWN;
            break;
        case POWER_SUPPLY_PROP_TECHNOLOGY:
            val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
            break;
        case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
            val->intval = status.capacity_level_override ?
                    status.capacity_level_override : status.capacity_level;
            break;
        case POWER_SUPPLY_PROP_CAPACITY:
            if(status.capacity == VALUE_UNKNOWN) {
                return -ENODATA;
            }
            val->intval = status.capacity;
            break;
        case POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG:
            if(status.time_left < 0) {
                return -ENODATA;
            }
            val->intval = status.time_left;
            break;
        case POWER_SUPPLY_PROP_TEMP:
            if(status.temp == VALUE_UNKNOWN) {
                return -ENODATA;
            }
            val->intval = status.temp;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN:
            if(status.voltage_max_design == VALUE_UNKNOWN) {
                return -ENODATA;
            }
            val->intval = status.voltage_max_design;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
            if(status.voltage_min_design == VALUE_UNKNOWN) {
                return -ENODATA;
            }
            val->intval = status.voltage_min_design;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_NOW:
            if(status.voltage < 0) {
                return -ENODATA;
            }
            val->intval = status.voltage;
            break;
        default:
            pr_info("%s: some properties deliberately report errors.\n",
                    __func__);
            return -EINVAL;
    }
    return 0;
}

static int
fake_ac_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val)
{
    unsigned long flags;

    switch (psp) {
    case POWER_SUPPLY_PROP_ONLINE:
            spin_lock_irqsave(&fake_battery_lock, flags);
            val->intval = ac_status;
            spin_unlock_irqrestore(&fake_battery_lock, flags);
            break;
    default:
            return -EINVAL;
    }
    return 0;
}

static int __init
fake_battery_nut_init(void)
{
    int result;
    int i;

    /*
     * Register the supplies before the control device, not after.  The write
     * handler calls power_supply_changed() on both supplies, so a write
     * arriving between misc_register() and the loop below would dereference a
     * NULL supplies[] entry.  The window is tiny, but the ordering rule is
     * free: publish the interface only once everything behind it exists.
     */
    for(i = 0; i < ARRAY_SIZE(descriptions); i++) {
        supplies[i] = power_supply_register(NULL, &descriptions[i], &configs[i]);
        if(IS_ERR(supplies[i])) {
            result = PTR_ERR(supplies[i]);
            printk(KERN_ERR "Unable to register power supply %d in fake_battery_nut: %d\n",
                    i, result);
            goto error;
        }
    }

    result = misc_register(&control_device);
    if(result) {
        printk(KERN_ERR "Unable to register misc device: %d\n", result);
        goto error;
    }

    printk(KERN_INFO "fake_battery_nut: loaded - NUT UPS to power_supply bridge\n");
    return 0;

error:
    while(--i >= 0) {
        power_supply_unregister(supplies[i]);
    }
    return result;
}

static void __exit
fake_battery_nut_exit(void)
{
    int i;

    misc_deregister(&control_device);

    for(i = ARRAY_SIZE(descriptions) - 1; i >= 0; i--) {
        power_supply_unregister(supplies[i]);
    }

    printk(KERN_INFO "fake_battery_nut: unloaded\n");
}

module_init(fake_battery_nut_init);
module_exit(fake_battery_nut_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("NUT UPS to Linux power_supply bridge");
MODULE_AUTHOR("Based on linux-fake-battery-module by Rob Hoelz");
MODULE_VERSION("1.4.0");
