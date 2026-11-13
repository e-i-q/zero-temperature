# Improvements

## On Demand Temperature Reading

Add a button to Hive main page which allows the user to run an on demand readings.
A window with status of all zeros will appear in the middle of main page.
For each zero these informations should be shown and updated in real time:

[ zero_name | small_progressbar | current_temp_reading / average_temp | current_reading_counter / success_count / error_count / max_reading_atempt ]


## Offset readings

In the `Settings` tab `Sensors` section, allow user to adjust each sensor with a offset for
temperature and humidity readings. This offset then use in graphs. Don't change reading values
directly, keep storing the actual DHT22 output values.


## Frequent save in offline

When a zero goes offline it often needs to be restarted or attached to a monitor to debug it.
In such case measurements would be lost. So when a zero detects it can't connect, bump up the
frequency of storing database file to SD card. The default interval is 3 hours. Let the user change
this value using `Settings` tab.

