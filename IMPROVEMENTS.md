# Improvements

## Workflow

Each improvement implement into separate git commit.


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


## Offline problem

Some zeroes sometimes goes offline. I don't know why. I have connected monitor to one thta was offline
and there was a dialog asking for wifi password. Other times I tried to restart the zero by unpluging
the power suply without looking at the screen and when it didn't go online after reboot I connected monitor
and the zero was stucked on login screen and wanted to manualy enter password for the OS.
I would like to resolve these problems. Some sort of connection retry when the zero detects it is offline.
If that doesn't help for a certain amount of time, then it should try to reboot.

