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
 * range loads first. It's a convenience so a chosen time span follows you
 * across browsers/devices, nothing more — a visitor who never logs in just
 * keeps using their browser's own localStorage, exactly as before this
 * feature existed.
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
 *     "someone's default chart range changed."
 *
 * Session: a PHP session cookie remembers which password_id is "logged in"
 * for this browser, for SESSION_LIFETIME_DAYS days, so the password only
 * has to be re-entered occasionally rather than on every visit.
 *
 * Everything comes in as a JSON POST body (no other query params):
 *   {"action": "status"}
 *   {"action": "login",  "password": "..."}
 *   {"action": "create", "password": "...", "overview_range": "24h", "forecast_range": "24h"}
 *   {"action": "save",   "overview_range": "24h", "forecast_range": "24h"}
 *   {"action": "logout"}
 *
 * All responses are JSON. Errors use db.php's fail() shape ({"error": "..."}),
 * the same convention script.js's fetchJson() already expects from every
 * other api/*.php endpoint.
 */

declare(strict_types=1);

const SESSION_LIFETIME_DAYS = 60;

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

// Must stay in sync with the range tokens api/readings.php's RANGE_MODIFIERS
// and api/forecast.php's RANGE_HOURS accept — both tabs' chip UIs only ever
// send one of these.
const VALID_RANGES = ['12h', '24h', '2d', '5d', '1m', 'all'];

function validRange($v): bool {
    return is_string($v) && in_array($v, VALID_RANGES, true);
}

function currentSettings(PDO $pdo, int $passwordId): ?array {
    $stmt = $pdo->prepare('SELECT overview_range, forecast_range FROM settings WHERE password_id = :id');
    $stmt->bindValue(':id', $passwordId, PDO::PARAM_INT);
    $stmt->execute();
    $row = $stmt->fetch();
    return $row ?: null;
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
        if (mb_strlen(trim($password)) < 4) {
            fail(400, 'Password must be at least 4 characters.');
        }
        if (!validRange($overviewRange) || !validRange($forecastRange)) {
            fail(400, 'Invalid range.');
        }
        $hash = password_hash($password, PASSWORD_BCRYPT);
        try {
            $pdo->beginTransaction();
            $ins = $pdo->prepare('INSERT INTO passwords (password_hash, created_at) VALUES (:hash, :created_at)');
            $ins->execute(['hash' => $hash, 'created_at' => gmdate('Y-m-d H:i:s')]);
            $newId = (int) $pdo->lastInsertId('passwords_id_seq');
            $ins2 = $pdo->prepare(
                'INSERT INTO settings (password_id, overview_range, forecast_range) VALUES (:pid, :ov, :fc)'
            );
            $ins2->execute(['pid' => $newId, 'ov' => $overviewRange, 'fc' => $forecastRange]);
            $pdo->commit();
        } catch (PDOException $e) {
            $pdo->rollBack();
            fail(500, 'Could not create settings profile: ' . $e->getMessage());
        }
        session_regenerate_id(true);
        $_SESSION['password_id'] = $newId;
        echo json_encode(['ok' => true, 'settings' => ['overview_range' => $overviewRange, 'forecast_range' => $forecastRange]]);
        break;
    }

    case 'save': {
        $passwordId = $_SESSION['password_id'] ?? null;
        if (!$passwordId) {
            fail(401, 'Not logged in.');
        }
        $overviewRange = (string) ($input['overview_range'] ?? '');
        $forecastRange = (string) ($input['forecast_range'] ?? '');
        if (!validRange($overviewRange) || !validRange($forecastRange)) {
            fail(400, 'Invalid range.');
        }
        $stmt = $pdo->prepare(
            'UPDATE settings SET overview_range = :ov, forecast_range = :fc WHERE password_id = :pid'
        );
        $stmt->execute(['ov' => $overviewRange, 'fc' => $forecastRange, 'pid' => $passwordId]);
        echo json_encode(['ok' => true]);
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
