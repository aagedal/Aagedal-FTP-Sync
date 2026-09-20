FROM php:8.3-apache

RUN docker-php-ext-install pdo_mysql \
    && rm -f /var/www/html/index.html
COPY public/ /var/www/html/
COPY docker/apache.conf /etc/apache2/conf-enabled/sync.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/sync.ini
COPY docker/configure.php docker/healthcheck.php /usr/local/lib/metadata-sync/
COPY docker/entrypoint.sh /usr/local/bin/sync-entrypoint
RUN chmod 755 /usr/local/bin/sync-entrypoint

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["php", "/usr/local/lib/metadata-sync/healthcheck.php"]
ENTRYPOINT ["sync-entrypoint"]
CMD ["apache2-foreground"]
