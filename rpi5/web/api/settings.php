<?php
/**
 * settings.php — password-profile-backed Settings for the Hive dashboard.
 *
 * There's no username, just a password: whoever knows a profile's password
 * can read and change that profile's saved settings from any browser. This
 * is NOT a security boundary protecting sensitive data — see
 * ../../../../db/database/sensors/meta.md's Users table, where this reuses
 * web_reader's own DB credentials, now also granted read/write on `settings`
 * and `passwords`. A second role (and a second ~/.pgpass entry) felt like a
 * lot of new moving parts for a feature that only ever decides which chart
 * ranges are offered and which one loads first. It's a convenience so your
 * choices follow you across browsers/devices, nothing more — a visitor who
 * never logs in just keeps using their browser's own localStorage and the
 * fixed default chip set, exactly as before this feature existed.
 *
 * A profile stores two things:
 *   - `ranges`: the ordered, user-editable set of time-span chips offered on
 *     BOTH the Overview and Forecast tabs (they're the same list — those two
 *     tabs have always shown identical chip sets, just interpreted
 *     differently: a historical window in readings.php, a forward-looking
 *     one in forecast.php). Each entry is a "<number><unit>" token (unit one
 *     of h/d/w/m — hours/days/weeks/months) or the literal "all" — see
 *     validRangeToken() below, and the matching parsers in readings.php's
 *     rangeModifier() and forecast.php's rangeHours().
 *   - `overview_range`/`forecast_range`: which one of those chips is
 *     currently active, independently per tab (unchanged from before this
 *     tab supported editing the list itself).
 *
 * Known, accepted simplifications (fine at this project's scale, revisit if
 * that ever changes):
 *   - No brute-force throttling on login. Checking a password is O(number
 *     of profiles) bcrypt verifications — negligible for the handful of
 *     profiles a household dashboard will ever have.
 *   - No cleanup of abandoned profiles (e.g. an accidental "Make New
 *     Settings" click leaves an orphaned row forever).
 *   - CSRF protection is the cheap kind (see the X-Requested-With check
 *     below), not a token scheme — proportionate to the worst case being
 *     "someone's chart ranges changed."
 *
 * Session: a PHP session cookie remembers which password_id is "logged in"
 * for this browser, for SESSION_LIFETIME_DAYS days, so the password only
 * has to be re-entered occasionally rather than on every visit. That cookie
 * lifetime is only half the story — the server also has to keep the session
 * *file* around that long, or the browser presents a still-valid cookie for
 * a session PHP has already garbage-collected. session.gc_maxlifetime is
 * ini_set() below to match, but Debian/Ubuntu's default php.ini also sets
 * session.gc_probability = 0 and delegates GC to the phpsessionclean
 * systemd timer, which runs every 30 minutes and reads gc_maxlifetime from
 * php.ini/conf.d directly — a runtime ini_set() here can't reach it. See
 * setup/setup_nginx_php.sh's configure_php_session_lifetime(), which drops
 * a conf.d override so that timer agrees with SESSION_LIFETIME_DAYS too.
 *
 * Everything comes in as a JSON POST body (no other query params):
 *   {"action": "status"}
 *   {"action": "login",  "password": "..."}
 *   {"action": "create", "password": "...", "overview_range": "24h", "forecast_range": "24h"}
 *   {"action": "save",   "overview_range": "24h", "forecast_range": "24h"}
 *   {"action": "save_ranges", "ranges": ["6h", "12h", "24h", "2d", "5d", "1w", "1m"]}
 *   {"action": "logout"}
 *
 * All responses are JSON. Errors use db.php's fail() shape ({"error": "..."}),
 * the same convention script.js's fetchJson() already expects from every
 * other api/*.php endpoint.
 */

declare(strict_types=1);

const SESSION_LIFETIME_DAYS = 60;
const MAX_RANGES = 12; // sane ceiling on how many chips one profile can pile up

// Keep the server-side session file alive as long as the cookie claims it
// is. Only fixes GC triggered by this request (gc_probability, which
// Debian/Ubuntu ships as 0 anyway) — the periodic systemd timer that
// actually deletes stale session files reads php.ini directly, see the
// docstring above and setup/setup_nginx_php.sh.
ini_set('session.gc_maxlifetime', (string) (SESSION_LIFETIME_DAYS * 86400));

session_set_cookie_params([
    'lifetime' => SESSION_LIFETIME_DAYS * 86400,
    'path'     => '/',
    'secure'   => !empty($_SERVER['HTTPS']),
    'httponly' => true,
    'samesite' => 'Lax',
]);
session_start();

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

// Cheap CSRF speed bump: a cross-site <form> POST can't add custom headers,
// and a cross-site fetch/XHR that tries to would trigger a CORS preflight
// this server never approves for foreign origins. Doesn't matter much given
// what's at stake here (see docstring above), but it's free.
if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'fetch') {
    fail(400, 'Missing required header.');
}

// The default chip set logged-out visitors (and brand-new profiles) get —
// unchanged from what used to be hardcoded in index.html.
const DEFAULT_RANGES = ['12h', '24h', '2d', '5d', '1m', 'all'];

// Same token shape api/readings.php's rangeModifier() and api/forecast.php's
// rangeHours() accept — keep these three in sync.
function validRangeToken($v): bool {
    return is_string($v) && ($v === 'all' || preg_match('/^[1-9]\d{0,2}(h|d|w|m)$/', $v) === 1);
}

// Reads a profile's settings row, normalizing a NULL/empty `ranges` column
// (either a pre-existing profile from before this column existed, or one
// that's never customized its list) to the default set. Returns `ranges` as
// an array — everywhere else in this file works with the list, not the
// stored comma string.
function currentSettings(PDO $pdo, int $passwordId): ?array {
    $stmt = $pdo->prepare('SELECT overview_range, forecast_range, ranges FROM settings WHERE password_id = :id');
    $stmt->bindValue(':id', $passwordId, PDO::PARAM_INT);
    $stmt->execute();
    $row = $stmt->fetch();
    if (!$row) {
        return null;
    }
    $rangesStr = ($row['ranges'] !== null && $row['ranges'] !== '') ? $row['ranges'] : implode(',', DEFAULT_RANGES);
    return [
        'overview_range' => $row['overview_range'],
        'forecast_range' => $row['forecast_range'],
        'ranges'         => explode(',', $rangesStr),
    ];
}

$input = json_decode((string) file_get_contents('php://input'), true);
if (!is_array($input)) {
    fail(400, 'Invalid JSON body.');
}
$action = (string) ($input['action'] ?? '');

$pdo = db();

switch ($action) {
    case 'status': {
        $passwordId = $_SESSION['password_id'] ?? null;
        if (!$passwordId) {
            echo json_encode(['loggedIn' => false]);
            break;
        }
        $settings = currentSettings($pdo, (int) $passwordId);
        if (!$settings) {
            // Profile was deleted (by hand, in the DB) out from under an
            // existing session — drop back to logged-out rather than 500.
            $_SESSION = [];
            session_destroy();
            echo json_encode(['loggedIn' => false]);
            break;
        }
        echo json_encode(['loggedIn' => true, 'settings' => $settings]);
        break;
    }

    case 'login': {
        $password = (string) ($input['password'] ?? '');
        if ($password === '') {
            fail(400, 'Password is required.');
        }
        // No username means no indexed lookup — every login checks the
        // submitted password against every stored hash. Fine at the scale
        // this ever runs at; see the docstring's accepted simplifications.
        $rows = $pdo->query('SELECT id, password_hash FROM passwords')->fetchAll();
        $matchId = null;
        foreach ($rows as $row) {
            if (password_verify($password, $row['password_hash'])) {
                $matchId = (int) $row['id'];
                break;
            }
        }
        if ($matchId === null) {
            fail(401, 'Incorrect password.');
        }
        $settings = currentSettings($pdo, $matchId);
        if (!$settings) {
            fail(500, 'That profile is missing its settings row.');
        }
        session_regenerate_id(true);
        $_SESSION['password_id'] = $matchId;
        echo json_encode(['ok' => true, 'settings' => $settings]);
        break;
    }

    case 'create': {
        $password = (string) ($input['password'] ?? '');
        $overviewRange = (string) ($input['overview_range'] ?? '24h');
        $forecastRange = (string) ($input['forecast_range'] ?? '24h');
        if (strlen(trim($password)) < 4) {
            fail(400, 'Password must be at least 4 characters.');
        }
        if (!validRangeToken($overviewRange) || !validRangeToken($forecastRange)) {
            fail(400, 'Invalid range.');
        }
        $hash = password_hash($password, PASSWORD_BCRYPT);
        try {
            $pdo->beginTransaction();
            $ins = $pdo->prepare('INSERT INTO passwords (password_hash, created_at) VALUES (:hash, :created_at)');
            $ins->execute(['hash' => $hash, 'created_at' => gmdate('Y-m-d H:i:s')]);
            $newId = (int) $pdo->lastInsertId('passwords_id_seq');
            // New profiles always start from the default chip set — there's
            // no "current custom list" to inherit, since only a logged-in
            // profile can have customized one in the first place.
            $ins2 = $pdo->prepare(
                'INSERT INTO settings (password_id, overview_range, forecast_range, ranges) VALUES (:pid, :ov, :fc, :ranges)'
            );
            $ins2->execute([
                'pid'    => $newId,
                'ov'     => $overviewRange,
                'fc'     => $forecastRange,
                'ranges' => implode(',', DEFAULT_RANGES),
            ]);
            $pdo->commit();
        } catch (PDOException $e) {
            $pdo->rollBack();
            fail(500, 'Could not create settings profile: ' . $e->getMessage());
        }
        session_regenerate_id(true);
        $_SESSION['password_id'] = $newId;
        echo json_encode([
            'ok'       => true,
            'settings' => ['overview_range' => $overviewRange, 'forecast_range' => $forecastRange, 'ranges' => DEFAULT_RANGES],
        ]);
        break;
    }

    case 'save': {
        $passwordId = $_SESSION['password_id'] ?? null;
        if (!$passwordId) {
            fail(401, 'Not logged in.');
        }
        $settings = currentSettings($pdo, (int) $passwordId);
        if (!$settings) {
            fail(500, 'That profile is missing its settings row.');
        }
        $overviewRange = (string) ($input['overview_range'] ?? '');
        $forecastRange = (string) ($input['forecast_range'] ?? '');
        // Must be one of THIS profile's configured chips, not just any
        // well-formed token — the client only ever offers chips from that
        // list, so a mismatch here means a stale/crafted request.
        if (!in_array($overviewRange, $settings['ranges'], true) || !in_array($forecastRange, $settings['ranges'], true)) {
            fail(400, "Range must be one of this profile's configured time spans.");
        }
        $stmt = $pdo->prepare(
            'UPDATE settings SET overview_range = :ov, forecast_range = :fc WHERE password_id = :pid'
        );
        $stmt->execute(['ov' => $overviewRange, 'fc' => $forecastRange, 'pid' => $passwordId]);
        echo json_encode(['ok' => true]);
        break;
    }

    case 'save_ranges': {
        $passwordId = $_SESSION['password_id'] ?? null;
        if (!$passwordId) {
            fail(401, 'Not logged in.');
        }
        $ranges = $input['ranges'] ?? null;
        if (!is_array($ranges) || count($ranges) < 1) {
            fail(400, 'At least one time span is required.');
        }
        if (count($ranges) > MAX_RANGES) {
            fail(400, 'At most ' . MAX_RANGES . ' time spans are allowed.');
        }
        $clean = [];
        foreach ($ranges as $r) {
            $r = is_string($r) ? strtolower(trim($r)) : '';
            if (!validRangeToken($r)) {
                fail(400, "Invalid time span: \"{$r}\" (use a number plus h/d/w/m, or \"all\").");
            }
            if (!in_array($r, $clean, true)) {
                $clean[] = $r; // de-dupe, keeping the first occurrence's position
            }
        }

        // If the profile's currently-active selection got removed from the
        // new list (or this profile predates having any active selection
        // that matches), fall back to the new list's first entry rather than
        // leaving overview_range/forecast_range pointing at a chip that no
        // longer exists.
        $current = currentSettings($pdo, (int) $passwordId);
        if (!$current) {
            fail(500, 'That profile is missing its settings row.');
        }
        $overviewRange = in_array($current['overview_range'], $clean, true) ? $current['overview_range'] : $clean[0];
        $forecastRange = in_array($current['forecast_range'], $clean, true) ? $current['forecast_range'] : $clean[0];

        $stmt = $pdo->prepare(
            'UPDATE settings SET ranges = :ranges, overview_range = :ov, forecast_range = :fc WHERE password_id = :pid'
        );
        $stmt->execute([
            'ranges' => implode(',', $clean),
            'ov'     => $overviewRange,
            'fc'     => $forecastRange,
            'pid'    => $passwordId,
        ]);
        echo json_encode([
            'ok'       => true,
            'settings' => ['ranges' => $clean, 'overview_range' => $overviewRange, 'forecast_range' => $forecastRange],
        ]);
        break;
    }

    case 'logout': {
        $_SESSION = [];
        session_destroy();
        echo json_encode(['ok' => true]);
        break;
    }

    default:
        fail(400, 'Unknown action.');
}
