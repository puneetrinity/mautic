FROM php:8.2-apache

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    zip \
    unzip \
    mariadb-client \
    cron \
    supervisor \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install PHP Extension Installer (better than manual ext configuration)
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Install PHP extensions using the installer (handles dependencies automatically)
RUN install-php-extensions \
    pdo_mysql \
    mbstring \
    exif \
    pcntl \
    bcmath \
    gd \
    intl \
    zip \
    opcache \
    imap

# Increase PHP memory limit for build process
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/memory.ini

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set working directory
WORKDIR /var/www/html

# Copy application files
COPY . /var/www/html

# Create necessary directories with proper permissions
RUN mkdir -p /var/www/html/var/cache \
    && mkdir -p /var/www/html/var/logs \
    && mkdir -p /var/www/html/var/spool \
    && mkdir -p /var/www/html/var/tmp \
    && mkdir -p /var/www/html/media/files \
    && mkdir -p /var/www/html/media/images \
    && mkdir -p /var/www/html/translations

# Install Composer dependencies
# Set higher memory limit for Composer and ignore platform requirements for Railway
ENV COMPOSER_MEMORY_LIMIT=-1
ENV COMPOSER_ALLOW_SUPERUSER=1
# Install from lockfile (7.0.1 ships with composer.lock)
RUN composer install --no-interaction --no-dev --optimize-autoloader --ignore-platform-reqs --no-scripts

# Run individual composer scripts with proper memory limits
RUN composer run-script githooks --no-interaction || true
RUN composer run-script npm-ci --no-interaction
RUN composer run-script npx-patch-package --no-interaction || true

# Clear cache so Symfony rebuilds the container with correct package versions
RUN rm -rf var/cache/*

# Generate assets with increased memory limit
RUN php -d memory_limit=1G bin/console mautic:assets:generate --env=prod || true
RUN php -d memory_limit=1G bin/console assets:install --symlink --relative ./ || true

# Set proper permissions
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 775 /var/www/html/var \
    && chmod -R 775 /var/www/html/media \
    && chmod -R 775 /var/www/html/translations \
    && chmod -R 775 /var/www/html/app/config

# Configure Apache with SSL and security modules
RUN a2enmod rewrite headers expires deflate

# Apache configuration for Mautic - Railway compatibility with security headers
RUN echo '<VirtualHost 0.0.0.0:80>\n\
    ServerAdmin webmaster@localhost\n\
    DocumentRoot /var/www/html\n\
    ServerName localhost\n\
    \n\
    # Security headers for HTTPS and cookie protection\n\
    Header always set X-Content-Type-Options nosniff\n\
    Header always set X-Frame-Options DENY\n\
    Header always set X-XSS-Protection "1; mode=block"\n\
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"\n\
    Header always set Referrer-Policy strict-origin-when-cross-origin\n\
    \n\
    # Cookie security for cross-site tracking\n\
    Header always edit Set-Cookie ^(.*)$ $1;HttpOnly;Secure;SameSite=None\n\
    \n\
    <Directory /var/www/html>\n\
        Options Indexes FollowSymLinks\n\
        AllowOverride All\n\
        Require all granted\n\
        \n\
        # Force HTTPS for tracking pixels and cookies\n\
        RewriteEngine On\n\
        # Health endpoint\n\
        RewriteRule ^health$ /health.php [L]\n\
        RewriteCond %{HTTP:X-Forwarded-Proto} !https\n\
        RewriteCond %{REQUEST_URI} !^/health(\.php)?$\n\
        RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]\n\
    </Directory>\n\
    \n\
    ErrorLog ${APACHE_LOG_DIR}/error.log\n\
    CustomLog ${APACHE_LOG_DIR}/access.log combined\n\
</VirtualHost>' > /etc/apache2/sites-available/000-default.conf

# Configure Apache for Railway
RUN echo "Listen 0.0.0.0:80" >> /etc/apache2/ports.conf

# PHP configuration optimizations for Mautic production
RUN echo "memory_limit = 512M" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "upload_max_filesize = 20M" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "post_max_size = 20M" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "max_execution_time = 300" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "date.timezone = UTC" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "opcache.enable = 1" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "opcache.memory_consumption = 256" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "opcache.max_accelerated_files = 20000" >> /usr/local/etc/php/conf.d/mautic.ini \
    && echo "zend.assertions = -1" >> /usr/local/etc/php/conf.d/mautic.ini

# Copy health check and startup script
COPY health.php /var/www/html/health.php
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose port
EXPOSE 80

# Set entrypoint
ENTRYPOINT ["docker-entrypoint.sh"]
