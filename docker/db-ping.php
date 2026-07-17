<?php
/**
 * Lightweight MySQL reachability probe used by the container entrypoint.
 *
 * We use PHP's PDO (same driver Laravel uses) instead of `mysqladmin ping`,
 * because the mariadb-client shipped in Alpine produces false negatives against
 * mysql:5.7 in some auth configurations. Exit 0 = reachable, 1 = not.
 *
 * Env: DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD
 */
$host = getenv('DB_HOST') ?: 'mysql';
$port = getenv('DB_PORT') ?: '3306';
$name = getenv('DB_DATABASE') ?: 'v2board';
$user = getenv('DB_USERNAME') ?: '';
$pass = getenv('DB_PASSWORD') ?: '';

$dsn = "mysql:host={$host};port={$port};dbname={$name}";

try {
    $pdo = new PDO($dsn, $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 3,
    ]);
    $pdo->query('SELECT 1');
    exit(0);
} catch (\Throwable $e) {
    fwrite(STDERR, '[db-ping] ' . $e->getMessage() . "\n");
    exit(1);
}
