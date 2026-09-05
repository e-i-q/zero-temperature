<?php
/**
 * deploy_trigger.php — Hive-side relay for the Settings tab's "Update Now"
 * buttons: looks up a sensor's address and calls that Pi Zero's own
 * web/deploy_trigger.php to pull + redeploy it on demand, then relays the
 * result back.
 *
 * Same relationship to rpi-zero/web/deploy_trigger.php that
 * api/sync_trigger.php has to rpi-zero/web/sync.php — this file is just the
 * messenger, the actual git pull + redeploy happens on the Pi Zero itself
 * (setup/git_deploy.sh). Normally that's triggered automatically and
 * fleet-wide by api/deploy_webhook.php after a GitHub push (see that file's
 * docstring) — this endpoint is for redeploying ONE sensor by hand, e.g.
 * one that missed the automatic relay (offline, unreachable at the time) or
 * that you just don't want to wait on for the next push.
 *
 * Gated behind the same Settings-tab login as settings.php ($_SESSION
 * ['password_id']) — that authenticates the BROWSER to this server. The
 * X-Deploy-Token sent on to the Pi Zero below is the SAME shared secret
 * api/deploy_webhook.php already uses for its fleet-wide relay — see that
 * file's docstring, rpi-zero/web/deploy_trigger.php, and
 * setup_deploy_trigger.sh on both sides.
 *
 * Request:  POST {"sensor": "<name>"} (X-Requested-With: fetch, same speed
 *           bump as settings.php).
 * Response: whatever JSON that Pi Zero's web/deploy_trigger.php returned,
 *           i.e. {"ok": true, "output": "..."} or {"ok": false, "error": "..."}.
 */

declare(strict_types=1);

const DEPLOY_TOKEN_FILE = '/etc/git-deploy/token';
// A pull + redeploy on the Pi Zero itself is normally quick, but generous
// anyway — same reasoning as sync_trigger.php's timeout: a one-off manual
// action, not something on a tight polling loop.
const REQUEST_TIMEOUT_SECONDS = 60;

// Just reads the session settings.php's login already established — no
// need to repeat its session_set_cookie_params() call, since that only
// matters when a NEW cookie is about to be issued.
session_start();

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'fetch') {
    fail(400, 'Missing required header.');
}
if (empty($_SESSION['password_id'])) {
    fail(401, 'Log in on the Settings tab first.');
}

$input = json_decode((string) file_get_contents('php://input'), true);
$sensorName = is_array($input) ? (string) ($input['sensor'] ?? '') : '';
if ($sensorName === '') {
    fail(400, 'sensor is required.');
}

$pdo = db();
$stmt = $pdo->prepare('SELECT ip_address FROM sensors WHERE name = :name');
$stmt->execute(['name' => $sensorName]);
$row = $stmt->fetch();
if (!$row) {
    fail(404, "Unknown sensor: {$sensorName}");
}

// Prefer the address dht22_logger.py keeps current on every successful
// write (see remote_db.py's register_sensor); fall back to mDNS for a
// sensor that's never gone through that code path yet — same fallback as
// sync_trigger.php and deploy_webhook.php's fleet relay.
$host = ($row['ip_address'] !== null && $row['ip_address'] !== '')
    ? $row['ip_address']
    : $sensorName . '.local';

if (!is_file(DEPLOY_TOKEN_FILE)) {
    fail(500, 'Deploy trigger is not configured on the Hive — run rpi5/setup/setup_deploy_webhook.sh.');
}
$token = trim((string) file_get_contents(DEPLOY_TOKEN_FILE));

// file_get_contents + stream context instead of curl, same as
// api/forecast.php (setup_nginx_php.sh doesn't install php-curl).
$context = stream_context_create([
    'http' => [
        'method'        => 'POST',
        'header'        => "X-Deploy-Token: {$token}\r\n",
        'timeout'       => REQUEST_TIMEOUT_SECONDS,
        'ignore_errors' => true, // so a non-2xx response body is still readable, not just `false`
    ],
]);
$body = @file_get_contents("http://{$host}/deploy_trigger.php", false, $context);

if ($body === false) {
    fail(502, "Could not reach {$sensorName} at {$host}.");
}

$decoded = json_decode($body, true);
if (!is_array($decoded)) {
    fail(502, "Unexpected response from {$sensorName} (" . substr($body, 0, 300) . ')');
}

echo json_encode($decoded);
