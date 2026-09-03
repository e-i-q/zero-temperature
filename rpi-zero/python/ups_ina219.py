"""
ups_ina219.py — Read a Geekworm/Waveshare-style INA219-based UPS HAT and
report this Pi Zero's power status to the Hive database.

Usage:
    python3 ups_ina219.py
    python3 ups_ina219.py --addr 0x43 --bus 1

Requires:
    python3-smbus (apt) — provides the `smbus` module the INA219 class below
    uses for I2C.
    pip3 install psycopg2-binary --break-system-packages
    (needed for the remote PostgreSQL write; see remote_db.py)

Remote DB:
    Uses the same shared connection/config as dht22_logger.py — see
    remote_db.py for connection config and auth. Unlike dht22_logger.py this
    writes only `sensors.status`, never `readings` — there's no history to
    keep here, just a live status label — so there's no local SQLite mirror
    and no offline backlog to replay. The write is best-effort: if the
    remote host is unreachable, a warning goes to stderr and the script
    exits non-zero, but there's nothing else to do locally — the next cron
    run (5 minutes later, see setup/setup_ups_ina219.sh) just tries again.

Status:
    The HAT reports `Current` negative while the Pi is running off the
    battery (discharging, mains lost) and positive while the battery is
    being charged from mains. A charging battery's current tapers toward
    zero as it approaches full, and the bus-voltage-based percentage
    estimate below (the same formula this file used to just print) tops out
    around ~91% in practice rather than ever reaching 100 — so "full" is
    detected from `Current` dropping back near zero, not from the
    percentage reaching some threshold. See FULL_CURRENT_THRESHOLD_MA.

    sensors.status ends up one of:
        "OK"             — on mains, battery full (|current| below threshold)
        "CHARGING <pct>%" — on mains, battery topping up
        "BATTERY <pct>%"  — off mains, running on battery
"""

import argparse
import sys

import psycopg2
import smbus

import remote_db

# Config Register (R/W)
_REG_CONFIG                 = 0x00
# SHUNT VOLTAGE REGISTER (R)
_REG_SHUNTVOLTAGE           = 0x01

# BUS VOLTAGE REGISTER (R)
_REG_BUSVOLTAGE             = 0x02

# POWER REGISTER (R)
_REG_POWER                  = 0x03

# CURRENT REGISTER (R)
_REG_CURRENT                = 0x04

# CALIBRATION REGISTER (R/W)
_REG_CALIBRATION            = 0x05

class BusVoltageRange:
    """Constants for ``bus_voltage_range``"""
    RANGE_16V               = 0x00      # set bus voltage range to 16V
    RANGE_32V               = 0x01      # set bus voltage range to 32V (default)

class Gain:
    """Constants for ``gain``"""
    DIV_1_40MV              = 0x00      # shunt prog. gain set to  1, 40 mV range
    DIV_2_80MV              = 0x01      # shunt prog. gain set to /2, 80 mV range
    DIV_4_160MV             = 0x02      # shunt prog. gain set to /4, 160 mV range
    DIV_8_320MV             = 0x03      # shunt prog. gain set to /8, 320 mV range

class ADCResolution:
    """Constants for ``bus_adc_resolution`` or ``shunt_adc_resolution``"""
    ADCRES_9BIT_1S          = 0x00      #  9bit,   1 sample,     84us
    ADCRES_10BIT_1S         = 0x01      # 10bit,   1 sample,    148us
    ADCRES_11BIT_1S         = 0x02      # 11 bit,  1 sample,    276us
    ADCRES_12BIT_1S         = 0x03      # 12 bit,  1 sample,    532us
    ADCRES_12BIT_2S         = 0x09      # 12 bit,  2 samples,  1.06ms
    ADCRES_12BIT_4S         = 0x0A      # 12 bit,  4 samples,  2.13ms
    ADCRES_12BIT_8S         = 0x0B      # 12bit,   8 samples,  4.26ms
    ADCRES_12BIT_16S        = 0x0C      # 12bit,  16 samples,  8.51ms
    ADCRES_12BIT_32S        = 0x0D      # 12bit,  32 samples, 17.02ms
    ADCRES_12BIT_64S        = 0x0E      # 12bit,  64 samples, 34.05ms
    ADCRES_12BIT_128S       = 0x0F      # 12bit, 128 samples, 68.10ms

class Mode:
    """Constants for ``mode``"""
    POWERDOW                = 0x00      # power down
    SVOLT_TRIGGERED         = 0x01      # shunt voltage triggered
    BVOLT_TRIGGERED         = 0x02      # bus voltage triggered
    SANDBVOLT_TRIGGERED     = 0x03      # shunt and bus voltage triggered
    ADCOFF                  = 0x04      # ADC off
    SVOLT_CONTINUOUS        = 0x05      # shunt voltage continuous
    BVOLT_CONTINUOUS        = 0x06      # bus voltage continuous
    SANDBVOLT_CONTINUOUS    = 0x07      # shunt and bus voltage continuous


class INA219:
    def __init__(self, i2c_bus=1, addr=0x40):
        self.bus = smbus.SMBus(i2c_bus);
        self.addr = addr

        # Set chip to known config values to start
        self._cal_value = 0
        self._current_lsb = 0
        self._power_lsb = 0
        self.set_calibration_16V_5A()

    def read(self,address):
        data = self.bus.read_i2c_block_data(self.addr, address, 2)
        return ((data[0] * 256 ) + data[1])

    def write(self,address,data):
        temp = [0,0]
        temp[1] = data & 0xFF
        temp[0] =(data & 0xFF00) >> 8
        self.bus.write_i2c_block_data(self.addr,address,temp)

    def set_calibration_16V_5A(self):
        """Configures to INA219 to be able to measure up to 16V and 5A of current. Counter
           overflow occurs at 16A.
           ..note :: These calculations assume a 0.01 shunt ohm resistor is present
        """
        # By default we use a pretty huge range for the input voltage,
        # which probably isn't the most appropriate choice for system
        # that don't use a lot of power.  But all of the calculations
        # are shown below if you want to change the settings.  You will
        # also need to change any relevant register settings, such as
        # setting the VBUS_MAX to 16V instead of 32V, etc.

        # VBUS_MAX = 16V             (Assumes 16V, can also be set to 32V)
        # VSHUNT_MAX = 0.08          (Assumes Gain 2, 80mV, can also be 0.32, 0.16, 0.04)
        # RSHUNT = 0.01               (Resistor value in ohms)

        # 1. Determine max possible current
        # MaxPossible_I = VSHUNT_MAX / RSHUNT
        # MaxPossible_I = 8.0A

        # 2. Determine max expected current
        # MaxExpected_I = 5.0A

        # 3. Calculate possible range of LSBs (Min = 15-bit, Max = 12-bit)
        # MinimumLSB = MaxExpected_I/32767
        # MinimumLSB = 0.0001529              (61uA per bit)
        # MaximumLSB = MaxExpected_I/4096
        # MaximumLSB = 0,0012207              (488uA per bit)

        # 4. Choose an LSB between the min and max values
        #    (Preferrably a roundish number close to MinLSB)
        # CurrentLSB = 0.00016 (uA per bit)
        self._current_lsb = 0.1524  # Current LSB = 100uA per bit

        # 5. Compute the calibration register
        # Cal = trunc (0.04096 / (Current_LSB * RSHUNT))
        # Cal = 13434 (0x347a)

        self._cal_value = 26868

        # 6. Calculate the power LSB
        # PowerLSB = 20 * CurrentLSB
        # PowerLSB = 0.002 (2mW per bit)
        self._power_lsb = 0.003048  # Power LSB = 2mW per bit

        # 7. Compute the maximum current and shunt voltage values before overflow
        #
        # Max_Current = Current_LSB * 32767
        # Max_Current = 3.2767A before overflow
        #
        # If Max_Current > Max_Possible_I then
        #    Max_Current_Before_Overflow = MaxPossible_I
        # Else
        #    Max_Current_Before_Overflow = Max_Current
        # End If
        #
        # Max_ShuntVoltage = Max_Current_Before_Overflow * RSHUNT
        # Max_ShuntVoltage = 0.32V
        #
        # If Max_ShuntVoltage >= VSHUNT_MAX
        #    Max_ShuntVoltage_Before_Overflow = VSHUNT_MAX
        # Else
        #    Max_ShuntVoltage_Before_Overflow = Max_ShuntVoltage
        # End If

        # 8. Compute the Maximum Power
        # MaximumPower = Max_Current_Before_Overflow * VBUS_MAX
        # MaximumPower = 3.2 * 32V
        # MaximumPower = 102.4W

        # Set Calibration register to 'Cal' calculated above
        self.write(_REG_CALIBRATION,self._cal_value)

        # Set Config register to take into account the settings above
        self.bus_voltage_range = BusVoltageRange.RANGE_16V
        self.gain = Gain.DIV_2_80MV
        self.bus_adc_resolution = ADCResolution.ADCRES_12BIT_32S
        self.shunt_adc_resolution = ADCResolution.ADCRES_12BIT_32S
        self.mode = Mode.SANDBVOLT_CONTINUOUS
        self.config = self.bus_voltage_range << 13 | \
                      self.gain << 11 | \
                      self.bus_adc_resolution << 7 | \
                      self.shunt_adc_resolution << 3 | \
                      self.mode
        self.write(_REG_CONFIG,self.config)

    def getShuntVoltage_mV(self):
        self.write(_REG_CALIBRATION,self._cal_value)
        value = self.read(_REG_SHUNTVOLTAGE)
        if value > 32767:
            value -= 65535
        return value * 0.01

    def getBusVoltage_V(self):
        self.write(_REG_CALIBRATION,self._cal_value)
        self.read(_REG_BUSVOLTAGE)
        return (self.read(_REG_BUSVOLTAGE) >> 3) * 0.004

    def getCurrent_mA(self):
        value = self.read(_REG_CURRENT)
        if value > 32767:
            value -= 65535
        return value * self._current_lsb

    def getPower_W(self):
        self.write(_REG_CALIBRATION,self._cal_value)
        value = self.read(_REG_POWER)
        if value > 32767:
            value -= 65535
        return value * self._power_lsb
        

# ── Configuration ──────────────────────────────────────────────────────────
DEFAULT_I2C_ADDR = 0x43
DEFAULT_I2C_BUS = 1

# |Current| below this counts as neither charging nor discharging — see the
# module docstring's "Status" section for why this (not the percentage) is
# what flips the battery back to "full"/OK.
FULL_CURRENT_THRESHOLD_MA = 50.0

STATUS_OK = "OK"
STATUS_BATTERY = "BATTERY"
STATUS_CHARGING = "CHARGING"


def battery_percent(bus_voltage_v: float) -> float:
    """Rough state-of-charge estimate from bus voltage alone (this HAT has
    no coulomb counter). Empirically maxes out around ~91% even at a true
    full charge — see FULL_CURRENT_THRESHOLD_MA."""
    percent = (bus_voltage_v - 3) / 1.2 * 100
    return max(0.0, min(100.0, percent))


def compute_status(current_ma: float, percent: float) -> str:
    if current_ma <= -FULL_CURRENT_THRESHOLD_MA:
        return f"{STATUS_BATTERY} {percent:.0f}%"
    if current_ma >= FULL_CURRENT_THRESHOLD_MA:
        return f"{STATUS_CHARGING} {percent:.0f}%"
    return STATUS_OK


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read the INA219-based UPS HAT and report battery status to the Hive database.")
    parser.add_argument("--addr", type=lambda s: int(s, 0), default=DEFAULT_I2C_ADDR, help=f"INA219 I2C address (default {hex(DEFAULT_I2C_ADDR)})")
    parser.add_argument("--bus", type=int, default=DEFAULT_I2C_BUS, help=f"I2C bus number (default {DEFAULT_I2C_BUS})")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ina219 = INA219(i2c_bus=args.bus, addr=args.addr)

    bus_voltage = ina219.getBusVoltage_V()  # voltage on V- (load side)
    current_ma = ina219.getCurrent_mA()
    percent = battery_percent(bus_voltage)
    status = compute_status(current_ma, percent)

    hostname = remote_db.local_hostname()
    try:
        conn = remote_db.connect()
    except psycopg2.OperationalError as e:
        print(f"WARNING: could not connect to remote DB at {remote_db.PG_HOST}:{remote_db.PG_PORT}: {e}", file=sys.stderr)
        return 1

    try:
        remote_db.update_status(conn, hostname, status)
    except psycopg2.Error as e:
        conn.rollback()
        print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
