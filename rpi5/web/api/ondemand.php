<?php
/**
 * ondemand.php — Hive-side relay for the Overview tab's "Read Now" button:
 * starts an on-demand DHT22 reading on one Pi Zero and relays its live
 * progress back to the browser.
 *
 * Same messenger pattern as sync_trigger.php: only the Pi Zero can read its
 * own DHT22, so this just looks up the sensor's address and calls that Pi
 * Zero's own web/ondemand.php (see its docstring for the request/progress
 * file mechanics), authenticating with the shared sync token
 * (/etc/dht22-sync/token — see rpi5/setup/setup_sync_trigger.sh).
 *
 * The browser fans out itself — one POST per online sensor, then one GET per
 * sensor per second — so a slow or unreachable Pi Zero only ever stalls its
 * own row of the progress window, never the others.
 *
 * Unlike sync_trigger.php this is NOT behind the Settings-tab login: it sits
 * on the Overview tab for anyone viewing the dashboard, and the worst it can
 * do is take one extra reading (each Pi Zero refuses to queue a second one
 * while one is already running).
 *
 * Requests (X-Requested-With: fetch, same CSRF speed bump as settings.php):
 *   POST {"sensor": "<name>"}  start → {"ok": true, "id": "...", "already": bool}
 *   GET  ?sensor=<name>        progress → {"ok": true, "pending": bool, "status": {...}|null}
 * Errors use db.php's fail() shape: {"error": "..."}.
 */

declare(strict_types=1);

const SYNC_TOKEN_FILE = '/etc/dht22-sync/token';
// Polled once a second — keep a dead Pi Zero from tying up a PHP worker.
const REQUEST_TIMEOUT_SECONDS = 4;

require __DIR__ . '/db.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'fetch') {
    fail(400, 'Missing required header.');
}

$method = $_SERVER['REQUEST_METHOD'] ?? '';
if ($method === 'POST') {
    $input = json_decode((string) file_get_contents('php://input'), true);
    $sensorName = is_array($input) ? (string) ($input['sensor'] ?? '') : '';
} elseif ($method === 'GET') {
    $sensorName = (string) ($_GET['sensor'] ?? '');
} else {
    fail(405, 'GET or POST required.');
}
if ($sensorName === '') {
    fail(400, 'sensor is required.');
}

$stmt = db()->prepare('SELECT ip_address FROM sensors WHERE name = :name');
$stmt->execute(['name' => $sensorName]);
$row = $stmt->fetch();
if (!$row) {
    fail(404, "Unknown sensor: {$sensorName}");
}
// Same address preference/fallback as sync_trigger.php.
$host = ($row['ip_address'] !== null && $row['ip_address'] !== '')
    ? $row['ip_address']
    : $sensorName . '.local';

if (!is_file(SYNC_TOKEN_FILE)) {
    fail(500, 'Sync token is not configured on the Hive — run rpi5/setup/setup_sync_trigger.sh.');
}
$token = trim((string) file_get_contents(SYNC_TOKEN_FILE));

$context = stream_context_create([
    'http' => [
        'method'        => $method,
        'header'        => "X-Sync-Token: {$token}\r\n",
        'timeout'       => REQUEST_TIMEOUT_SECONDS,
        'ignore_errors' => true,
    ],
]);
$body = @file_get_contents("http://{$host}/ondemand.php", false, $context);
if ($body === false) {
    fail(502, "Could not reach {$sensorName} at {$host}.");
}

$decoded = json_decode($body, true);
if (!is_array($decoded)) {
    // Most likely a Pi Zero that hasn't been redeployed since this feature
    // landed (nginx 404 page instead of JSON).
    fail(502, "{$sensorName} doesn't support on-demand readings yet — update it first.");
}
if (empty($decoded['ok'])) {
    fail(502, (string) ($decoded['error'] ?? "Unexpected response from {$sensorName}."));
}

echo json_encode($decoded);
