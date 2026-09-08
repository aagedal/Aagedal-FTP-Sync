FROM php:8.3-cli
RUN docker-php-ext-install pdo_mysql
WORKDIR /srv
COPY public /srv/public
COPY tests /srv/tests
COPY tests/config.php /srv/config.php
CMD ["php", "-S", "0.0.0.0:8080", "-t", "public"]
