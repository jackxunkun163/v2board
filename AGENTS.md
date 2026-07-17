# AGENTS.md

This is the **wyx2685 fork of V2Board** (panel version `config('app.version')` in `config/app.php`), a proxy/subscription management panel. It pairs with the modified [V2bX](https://github.com/wyx2685/V2bX) backend; not all features interop with upstream V2bX.

## Stack

Laravel 8 application running as a **hybrid**: traditional PHP-FPM via `public/index.php`, **or** Webman/AdapterMan via `webman.php` + `start.php` (looks for `isWEBMAN` constant, dispatches through a global `run()` function). Queue worker is Laravel Horizon, run under pm2 (`pm2.yaml`).

- PHP `^7.3|^8.0`. Webman mode requires PHP 8+ and the `pcntl` extension (see `update.sh`).
- Required PHP extensions: `redis`, `igbinary` (see `cli-php.ini`).
- Timezone `Asia/Shanghai`, locale `zh-CN`. UI strings and many code comments are Chinese.

## Database / schema — important

**Do not use `php artisan migrate` for app tables.** Schema lives in raw SQL:

- `database/install.sql` — full initial schema, run by `php artisan v2board:install`
- `database/update.sql` — incremental changes, run by `php artisan v2board:update` (these statements fail silently by design)

The only Laravel migration in `database/migrations/` is `failed_jobs`. To change schema, edit the SQL files (and run via `v2board:update`), not migrations.

`v2board:install` is interactive (prompts for DB creds + admin email), copies `.env.example` → `.env`, generates `APP_KEY`, imports `install.sql`, and creates an admin user. It refuses to run if `.env` exists.

## Runtime config — important

`config/v2board.php` is **gitignored** and **generated at runtime**. Admin `ConfigController@save` (`app/Http/Controllers/V1/Admin/ConfigController.php:198`) writes it via `var_export()` + `File::put()`, then runs `config:cache` and, when Webman is active, restarts the worker by killing the PID cached in `Cache::get('WEBMANPID')`.

Every `config('v2board.*')` call across the app reads from this file — defaults are passed inline (e.g. `config('v2board.app_name', 'V2Board')`). Never commit `config/v2board.php`, and don't expect it to exist on a fresh checkout.

## Routing

API routes are **auto-discovered by glob**, not declared:

- `app/Http/Routes/V1/*.php` → mounted under `/api/v1`
- `app/Http/Routes/V2/*.php` → mounted under `/api/v2`

Each file is a class with `public function map(Registrar $router)` (`RouteServiceProvider.php:75`). To add an API route group, drop a new class in one of those dirs — no other registration needed. (Note: the glob path `app_path('Http//Routes//V1')` deliberately contains double slashes; it works, leave it.)

Web routes are in `routes/web.php` only. Admin panel path is dynamic: `v2board.secure_path` → `frontend_admin_path` → fallback `hash('crc32b', config('app.key'))`.

## Auth middleware

API auth is **not** Laravel session-based. Route middleware `admin`, `user`, `staff`, `client` (defined in `app/Http/Middleware/*`, registered in `app/Http/Kernel.php`) read `auth_data` input or the `authorization` header, decrypt via `AuthService::decryptAuthData`, then merge the user array into `$request->user`. Require one of these middlewares on any controller needing identity.

## Controller conventions

- Return JSON with `return response(['data' => ...]);`
- Signal errors with `abort(500, 'message')` (or other codes)
- Request validation via Form Requests in `app/Http/Requests/`
- Business logic belongs in `app/Services/*`, not controllers

## Layout pointers

- `app/Console/Commands/*` — Artisan commands. Real entrypoints: `v2board:install`, `v2board:update`, `v2board:statistics`, plus scheduled `check:*`, `reset:*`, `send:*`, `traffic:update`. Schedule defined in `app/Console/Kernel.php`.
- `app/Payments/*` — one file per payment driver (Stripe, AlipayF2F, etc.)
- `app/Protocols/*` — generate subscription configs for client apps (Clash, Singbox, Surge, …)
- `app/Plugins/Telegram/*` — Telegram bot commands
- `app/Jobs/*` — Horizon-queued jobs (email, telegram, stats, traffic)
- `app/Models/*` — Eloquent models; one per proxy protocol (`ServerVmess`, `ServerTrojan`, `ServerHysteria`, `ServerTuic`, `ServerVless`, `ServerShadowsocks`, `ServerAnytls`, …)
- View namespace `theme::` maps to `public/theme/` (registered in `AppServiceProvider`). Themes are static assets served from `public/theme/<name>/`, not Blade packages.

## Development commands

```bash
composer install                         # also runs post-autoload-dump → artisan package:discover
php artisan v2board:install              # initial install (interactive)
php artisan v2board:update               # apply update.sql + restart horizon
php artisan config:cache                 # required after any config/v2board.php change
php artisan horizon:terminate            # restart queue workers

./init.sh                                # fresh install path (composer install + v2board:install)
./update.sh                              # production update (see warning below)
```

**`./update.sh` does `git reset --hard origin/master`** — any uncommitted local edits to tracked files are destroyed. Commit or stash before running it. It also removes `composer.lock`/`composer.phar` and runs `composer update`.

After any `v2board:*` or config change in a running deployment, run `php artisan config:clear && php artisan config:cache && php artisan horizon:terminate`.

## Testing

PHPUnit 9, configured in `phpunit.xml`. Suites: `tests/Unit`, `tests/Feature`.

```bash
vendor/bin/phpunit                       # full suite
vendor/bin/phpunit --testsuite Unit      # one suite
vendor/bin/phpunit tests/Feature/ExampleTest.php   # one file
```

- `Tests\Bootstrap` (PHPUnit extension) runs `config:cache` + `event:cache` before the first test and cleans `bootstrap/cache/*.phpunit.php` after the last.
- Test env forces `CACHE_DRIVER=array`, `SESSION_DRIVER=array`, `QUEUE_CONNECTION=sync`, `MAIL_DRIVER=array`, and writes framework caches to `bootstrap/cache/*.phpunit.php` (kept separate from the runtime cache).
- `vendor/bin/phpunit` requires a working DB connection (`CreatesApplication` bootstraps the full Laravel app). **The committed tests are stubs** (`ExampleTest` only) — there is no real coverage to regression-check against.

No lint/typecheck/format script is defined in `composer.json`. Follow `.editorconfig`: 4-space indent, LF line endings, UTF-8, trim trailing whitespace.

## Things that look broken but aren't

- `RouteServiceProvider` glob path `app_path('Http//Routes//V1')` — double slash, intentional/working.
- `web` middleware group is almost entirely commented out in `app/Http/Kernel.php` — the SPA frontend doesn't use Laravel sessions/CSRF.
- `cli-php.ini` `disable_functions` blocks `session_*`, `header`, `setcookie`, etc. — these are handled by AdapterMan/Webman, not PHP's normal SAPI.
