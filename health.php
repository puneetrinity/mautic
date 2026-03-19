<?php
// Health check endpoint for Railway
header('Content-Type: application/json');

$now = date('c');
$health = [
    'status'    => 'ok',
    'timestamp' => $now,
    'checks'    => [],
    'meta'      => [
        'php'      => PHP_VERSION,
        'app_env'  => getenv('APP_ENV') ?: 'prod',
    ],
];

// Helper to set statuses
$set = function (string $key, string $value) use (&$health) {
    $health['checks'][$key] = $value;
    if ('error' === $value) {
        $health['status'] = 'error';
    } elseif ('warn' === $value || 'degraded' === $value) {
        if ('ok' === $health['status']) {
            $health['status'] = 'degraded';
        }
    }
};

// Filesystem checks
$paths = [
    'config'      => __DIR__.'/config',
    'var'         => __DIR__.'/var',
    'var_cache'   => __DIR__.'/var/cache',
    'var_logs'    => __DIR__.'/var/logs',
    'var_tmp'     => __DIR__.'/var/tmp',
    'media'       => __DIR__.'/media',
    'vendor'      => __DIR__.'/vendor',
];

foreach ($paths as $label => $path) {
    if (is_dir($path)) {
        $set($label.'_exists', 'ok');
        if (!is_writable($path) && !in_array($label, ['vendor'], true)) {
            $set($label.'_writable', 'warn');
        } else {
            $set($label.'_writable', 'ok');
        }
    } else {
        $set($label.'_exists', 'warn');
    }
}

// Mautic install check
$set('installed', file_exists(__DIR__.'/config/local.php') ? 'ok' : 'warn');

// Basic cron presence (best-effort)
$set('cron_config', file_exists('/etc/cron.d/mautic') ? 'ok' : 'warn');

// Worker hint (best-effort)
$set('worker_hint', file_exists(__DIR__.'/var/.worker_started') ? 'ok' : 'warn');

// Database check (quick and safe)
$dbHost = getenv('MAUTIC_DB_HOST') ?: getenv('DB_HOST');
if ($dbHost) {
    $dbPort = getenv('MAUTIC_DB_PORT') ?: getenv('DB_PORT') ?: 3306;
    $dbName = getenv('MAUTIC_DB_NAME') ?: getenv('DB_NAME');
    $dbUser = getenv('MAUTIC_DB_USER') ?: getenv('DB_USER');
    $dbPass = getenv('MAUTIC_DB_PASSWORD') ?: getenv('DB_PASSWORD');
    try {
        $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4', $dbHost, $dbPort, $dbName);
        $pdo = new PDO($dsn, $dbUser, $dbPass, [
            PDO::ATTR_TIMEOUT         => 2,
            PDO::ATTR_ERRMODE         => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_NUM,
        ]);
        // Simple query to validate the connection truly works
        $pdo->query('SELECT 1');
        $set('database', 'ok');
        unset($pdo);
    } catch (Throwable $e) {
        $set('database', 'degraded');
        // Attach minimal error info to help debugging (not sensitive)
        $health['checks']['database_error'] = $e->getMessage();
        error_log('[health] DB check failed: '.$e->getMessage());
    }
}

// Disk usage (best-effort)
try {
    $df = @disk_free_space(__DIR__);
    $dt = @disk_total_space(__DIR__);
    if ($df !== false && $dt !== false) {
        $health['meta']['disk'] = [
            'free'  => $df,
            'total' => $dt,
        ];
    }
} catch (Throwable $e) {
    // ignore
}

// HTTP code policy: ok/degraded => 200, error => 503
http_response_code('error' === $health['status'] ? 503 : 200);
echo json_encode($health, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n";
