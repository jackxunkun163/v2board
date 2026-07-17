<?php
/**
 * One-shot DB initializer, run from the container entrypoint on first boot.
 * - Imports database/install.sql into the (external) MySQL.
 * - Creates an admin user from ADMIN_EMAIL / ADMIN_PASSWORD env vars.
 *
 * Invoked as: php /tmp/init-db.php
 */
require '/var/www/v2board/vendor/autoload.php';

// Bootstrap a minimal Laravel kernel so Eloquent models work.
$app = require '/var/www/v2board/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\User;
use App\Utils\Helper;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

$email    = getenv('ADMIN_EMAIL') ?: '';
$password = getenv('ADMIN_PASSWORD') ?: '';

// Use v2_user as the "schema already imported" marker.
$alreadyInstalled = false;
try {
    $alreadyInstalled = Schema::hasTable('v2_user');
} catch (\Throwable $e) {
    // ignore — DB unreachable or empty
}

if (!$alreadyInstalled) {
    $sqlFile = '/var/www/v2board/database/install.sql';
    if (!is_file($sqlFile)) {
        fwrite(STDERR, "[init-db] install.sql not found at {$sqlFile}\n");
        exit(1);
    }
    $raw   = (string) file_get_contents($sqlFile);
    $flat  = str_replace("\r\n", "\n", $raw);
    $stmts = preg_split('/;\s*[\r\n]+/', $flat);
    $imported = 0;
    foreach ($stmts as $stmt) {
        $stmt = trim($stmt);
        if ($stmt === '' || str_starts_with($stmt, '--') || str_starts_with($stmt, '/*')) {
            continue;
        }
        try {
            DB::statement($stmt);
            $imported++;
        } catch (\Throwable $e) {
            // Statements fail silently by design (matches v2board:update behavior).
        }
    }
    echo "[init-db] Imported install.sql ({$imported} statements)\n";
} else {
    echo "[init-db] Schema already present, skipping import\n";
}

// Create admin user if requested and not present.
if ($email === '' || $password === '') {
    echo "[init-db] ADMIN_EMAIL/ADMIN_PASSWORD not set; skipping admin creation\n";
    exit(0);
}

if (strlen($password) < 8) {
    fwrite(STDERR, "[init-db] ADMIN_PASSWORD must be at least 8 characters\n");
    exit(1);
}

$existing = User::where('email', $email)->first();
if ($existing) {
    echo "[init-db] Admin '{$email}' already exists, skipping\n";
    exit(0);
}

$user = new User();
$user->email    = $email;
$user->password = password_hash($password, PASSWORD_DEFAULT);
$user->uuid     = Helper::guid(true);
$user->token    = Helper::guid();
$user->is_admin = 1;
$user->save();

echo "[init-db] Admin user created: {$email}\n";
