#!/bin/bash
set -e

# Function to wait for database
wait_for_db() {
    echo "Waiting for database connection..."
    
    if [ -n "$MAUTIC_DB_HOST" ]; then
        RETRY_COUNT=0
        MAX_RETRIES=60  # 5 minutes total wait time
        
        until php -r "
            try {
                \$pdo = new PDO('mysql:host=$MAUTIC_DB_HOST;port=${MAUTIC_DB_PORT:-3306}', '$MAUTIC_DB_USER', '$MAUTIC_DB_PASSWORD');
                echo 'Database connected successfully\n';
                exit(0);
            } catch (Exception \$e) {
                echo 'Database connection failed: ' . \$e->getMessage() . '\n';
                exit(1);
            }
        "; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                echo "ERROR: Failed to connect to database after $MAX_RETRIES attempts"
                echo "DB_HOST: $MAUTIC_DB_HOST"
                echo "DB_PORT: ${MAUTIC_DB_PORT:-3306}"
                echo "DB_USER: $MAUTIC_DB_USER"
                echo "DB_NAME: $MAUTIC_DB_NAME"
                exit 1
            fi
            echo "Database not ready, retrying in 5 seconds... (attempt $RETRY_COUNT/$MAX_RETRIES)"
            sleep 5
        done
    else
        echo "No database host configured, skipping database wait"
    fi
}

# Function to initialize Mautic
init_mautic() {
    if [ ! -d "/var/www/html/config" ]; then
        mkdir -p /var/www/html/config
    fi

    #

    # Auto-generate config/local.php from environment if missing
    if [ ! -f "/var/www/html/config/local.php" ]; then
        echo "Generating config/local.php from environment..."
        secret="${MAUTIC_SECRET_KEY}"
        if [ -z "$secret" ]; then
            secret=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)
        fi
        # Configure trusted proxies for Railway and other cloud platforms
        # REMOTE_ADDR tells Symfony to trust the immediate proxy (Railway's load balancer)
        trusted_proxies_php="array('127.0.0.1', 'REMOTE_ADDR')"
        if [ -n "$MAUTIC_TRUSTED_PROXIES" ]; then
            # Allow override via environment variable
            IFS=',' read -ra PROXIES_ARR <<< "$MAUTIC_TRUSTED_PROXIES"
            quoted=$(printf "'%s'," "${PROXIES_ARR[@]}" | sed 's/,$//')
            trusted_proxies_php="array(${quoted})"
        fi

        cat > /var/www/html/config/local.php <<PHP
<?php

// Auto-generated from environment by entrypoint
\$parameters = array(
    'db_driver'       => getenv('MAUTIC_DB_DRIVER') ?: 'pdo_mysql',
    'db_host'         => getenv('MAUTIC_DB_HOST') ?: '127.0.0.1',
    'db_port'         => (int) (getenv('MAUTIC_DB_PORT') ?: 3306),
    'db_name'         => getenv('MAUTIC_DB_NAME') ?: '',
    'db_user'         => getenv('MAUTIC_DB_USER') ?: '',
    'db_password'     => getenv('MAUTIC_DB_PASSWORD') ?: '',
    'db_table_prefix' => getenv('MAUTIC_DB_TABLE_PREFIX') ?: '',
    'site_url'        => getenv('MAUTIC_URL') ?: '',
    'secret_key'      => '${secret}',
    'trusted_proxies' => ${trusted_proxies_php},
    // Ensure mailer DSN is persisted into parameters so console/messenger gets it via ParameterLoader
    'mailer_dsn'      => getenv('MAUTIC_MAILER_DSN') ?: 'smtp://localhost:25',
    'default_timezone'=> getenv('MAUTIC_DEFAULT_TIMEZONE') ?: 'UTC',
);

PHP
    fi

    # Set proper permissions
    chown -R www-data:www-data /var/www/html/config
    chown -R www-data:www-data /var/www/html/media
    chown -R www-data:www-data /var/www/html/var

    echo "Mautic initialization complete"
}

# Function to run database migrations
run_migrations() {
    if [ -f "/var/www/html/bin/console" ]; then
        # Only run if explicitly enabled for safety in production
        case "${RUN_DB_MIGRATIONS,,}" in
            "1"|"true"|"yes")
                echo "Running Doctrine migrations (safe, idempotent)..."
                # Run as www-data to match file permissions
                su -s /bin/bash -c "php /var/www/html/bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration" www-data \
                    || echo "Migrations completed with warnings"
                ;;
            *)
                echo "Skipping DB migrations (set RUN_DB_MIGRATIONS=true to enable)."
                ;;
        esac
    fi
}

# Function to setup cron jobs inside this container
setup_cron() {
    echo "Configuring in-container cron jobs..."

    # Export current environment for cron jobs (DB/Mautic vars etc.)
    # Caution: this writes env vars inside the container only
    printenv | awk -F= '{print $1 "=" $2}' > /etc/environment

    # Create cron log file and tail to stdout
    touch /var/log/mautic-cron.log
    chown www-data:www-data /var/log/mautic-cron.log
    # Tail the log file to stdout in background
    (tail -F /var/log/mautic-cron.log &)

    # Create cron file
    cat > /etc/cron.d/mautic <<'CRONEOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# Core operations (staggered) - official Mautic schedule
0,15,30,45 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:segments:update --no-interaction >> /var/log/mautic-cron.log 2>&1
5,20,35,50 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:campaigns:rebuild --no-interaction >> /var/log/mautic-cron.log 2>&1
10,25,40,55 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:campaigns:trigger --no-interaction >> /var/log/mautic-cron.log 2>&1

# Reports
*/15 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:reports:scheduler --no-interaction >> /var/log/mautic-cron.log 2>&1

# Daily maintenance
0 2 * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:maintenance:cleanup --days-old=90 --no-interaction >> /var/log/mautic-cron.log 2>&1
5 2 * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:contacts:cleanup_exported_files --no-interaction >> /var/log/mautic-cron.log 2>&1
10 2 * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:webhooks:delete_logs --no-interaction >> /var/log/mautic-cron.log 2>&1

# Optional queues (enabled)
# Webhooks batch processing
*/2 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:webhooks:process --no-interaction >> /var/log/mautic-cron.log 2>&1

# Monitored email fetch (bounces/replies)
*/5 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:email:fetch --no-interaction >> /var/log/mautic-cron.log 2>&1

# Scheduled broadcasts (segment emails with publishUp window)
*/10 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:broadcasts:send --channel=email --no-interaction >> /var/log/mautic-cron.log 2>&1

# Marketing messages queue processing
# Processes deferred marketing messages (frequency rules), required for campaign/list sends
*/3 * * * * www-data /usr/local/bin/php /var/www/html/bin/console mautic:messages:send --no-interaction >> /var/log/mautic-cron.log 2>&1

CRONEOF

    chmod 0644 /etc/cron.d/mautic

    # Docker-specific cron fixes
    # Fix hardlink count issue in Docker
    touch /etc/crontab /etc/cron.*/*

    # Fix PAM authentication issue
    sed -i '/pam_loginuid.so/s/^/#/' /etc/pam.d/cron 2>/dev/null || true

    # /etc/cron.d/ files are read automatically by cron daemon
    # No need to load via crontab command (which would fail due to username field)

    # Start cron in background
    cron || true
    echo "Cron: enabled mautic:messages:send every 3 minutes"

    # Give cron a moment to start
    sleep 2

    # Verify cron is running
    if pgrep -x cron > /dev/null; then
        echo "Cron daemon started successfully"
    else
        echo "WARNING: Cron daemon failed to start"
    fi
}

# Function to start Messenger worker if DSNs are configured
start_messenger_worker() {
    # Start a long-running worker only if a non-sync DSN is provided
    if [ -n "$MAUTIC_MESSENGER_DSN_EMAIL" ] && [[ "$MAUTIC_MESSENGER_DSN_EMAIL" != sync* ]]; then
        # Only start once Mautic is installed (local.php exists)
        if [ ! -f "/var/www/html/config/local.php" ]; then
            echo "Messenger worker not started (local.php not found yet)."
            return 0
        fi
        # Ensure transports are set up (creates messenger_messages for Doctrine)
        echo "Ensuring Messenger transports are set up..."
        # Preserve environment so MAUTIC_* vars (e.g., MAUTIC_MAILER_DSN) are available
        su -m -s /bin/bash -c "php /var/www/html/bin/console messenger:setup-transports --no-interaction || true" www-data
        echo "Starting Messenger worker (email, hit)..."
        # Symfony Messenger requires positive time-limit; omit and use keepalive
        su -m -s /bin/bash -c "php /var/www/html/bin/console messenger:consume -vv email hit --keepalive=30 --memory-limit=256M" www-data &
    else
        echo "Messenger worker not started (email DSN not set or using sync://)."
    fi
}

# Background watcher to start worker once install completes
watch_install_then_worker() {
    if [ -z "$MAUTIC_MESSENGER_DSN_EMAIL" ] || [[ "$MAUTIC_MESSENGER_DSN_EMAIL" == sync* ]]; then
        return 0
    fi
    (
        for i in $(seq 1 60); do
            if [ -f "/var/www/html/config/local.php" ]; then
                if [ ! -f "/var/www/html/var/.worker_started" ]; then
                    echo "Detected install completion; starting Messenger worker..."
                    start_messenger_worker
                    touch /var/www/html/var/.worker_started || true
                fi
                break
            fi
            sleep 5
        done
    ) &
}

# Main execution
echo "Starting Mautic container..."

# Wait for database if configured
wait_for_db

# Initialize Mautic
init_mautic

# Run DB migrations (optional, controlled by RUN_DB_MIGRATIONS)
run_migrations

# Configure and start cron + queue worker (after migrations)
setup_cron
start_messenger_worker
watch_install_then_worker

# Configure Apache for Railway's PORT environment variable
if [ -n "$PORT" ]; then
    echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
    echo "Listen 0.0.0.0:$PORT" > /etc/apache2/conf-available/railway-port.conf
    echo "<VirtualHost 0.0.0.0:$PORT>" > /etc/apache2/sites-available/000-default.conf
    echo "    ServerAdmin webmaster@localhost" >> /etc/apache2/sites-available/000-default.conf
    echo "    DocumentRoot /var/www/html" >> /etc/apache2/sites-available/000-default.conf
    echo "    <Directory /var/www/html>" >> /etc/apache2/sites-available/000-default.conf
    echo "        Options Indexes FollowSymLinks" >> /etc/apache2/sites-available/000-default.conf
    echo "        AllowOverride All" >> /etc/apache2/sites-available/000-default.conf
    echo "        RewriteEngine On" >> /etc/apache2/sites-available/000-default.conf
    echo "        # Map /health to health.php" >> /etc/apache2/sites-available/000-default.conf
    echo "        RewriteRule ^health$ /health.php [L]" >> /etc/apache2/sites-available/000-default.conf
    echo "        # Trust upstream HTTPS header so Symfony sees secure requests" >> /etc/apache2/sites-available/000-default.conf
    echo "        SetEnvIf X-Forwarded-Proto \"https\" HTTPS=on" >> /etc/apache2/sites-available/000-default.conf
    echo "        Require all granted" >> /etc/apache2/sites-available/000-default.conf
    echo "    </Directory>" >> /etc/apache2/sites-available/000-default.conf
    echo "    <Location /health>" >> /etc/apache2/sites-available/000-default.conf
    echo "        Require all granted" >> /etc/apache2/sites-available/000-default.conf
    echo "    </Location>" >> /etc/apache2/sites-available/000-default.conf
    echo "    ErrorLog \${APACHE_LOG_DIR}/error.log" >> /etc/apache2/sites-available/000-default.conf
    echo "    CustomLog \${APACHE_LOG_DIR}/access.log combined" >> /etc/apache2/sites-available/000-default.conf
    echo "</VirtualHost>" >> /etc/apache2/sites-available/000-default.conf
    a2enconf servername railway-port
    echo "Apache configured for Railway port $PORT"
fi

# Ensure Apache uses a single MPM. php:apache should run with prefork.
a2dismod mpm_event 2>/dev/null || true
a2enmod mpm_prefork 2>/dev/null || true

# Start Apache
echo "Starting Apache server..."
exec apache2-foreground
