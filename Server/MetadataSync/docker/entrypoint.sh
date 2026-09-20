#!/bin/sh
set -eu
umask 077
php /usr/local/lib/metadata-sync/configure.php
chown www-data:www-data /var/www/config.php
exec docker-php-entrypoint "$@"
