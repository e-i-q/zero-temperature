# Update the DB path if yours differs from /mnt/sqlite_ram/sensors.db
sudo cp readings.php /var/www/html/readings.php
sudo cp index.html /var/www/html/index.html
sudo chown www-data:www-data /var/www/html/readings.php /var/www/html/index.html
