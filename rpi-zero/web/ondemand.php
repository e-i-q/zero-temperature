<?php
/**
 * ondemand.php — starts an on-demand DHT22 reading on this Pi Zero and
 * reports its live progress.
 *
 * Exists for the Hive dashboard's "Read Now" button: rpi5/web/api/ondemand.php
 * relays here for every online sensor, then polls GET once a second to fill
 * in its progress window.
 *
 * This file never touches the sensor itself (PHP runs as www-data, which has
 * neither GPIO access nor the sensor_writer ~/.pgpass). It only drops a
 * request file into ONDEMAND_DIR; the systemd path unit dht22-ondemand.path
 * (installed by setup/setup_dht22_logger.sh) notices it and runs
 * python/dht22_logger.py --ondemand-dir as the normal logger user, which
 * claims the request and writes status.json after every DHT22 attempt — see
 * that script's "On-demand readings" docstring section.
 *
 * Gated by the same shared secret as sync.php (/etc/dht22-sync/token, see
 * setup/setup_sync_trigger.sh) — the Hive already holds it, and asking for
 * one extra reading is no bigger a privilege than asking for a sync.
 *
 * Requests (header X-Sync-Token: <shared secret> on both):
 *   POST  start a reading → {"ok": true, "id": "<request id>", "already": bool}
 *         ("already" = a reading was already queued/running; its id is
 *         returned so the caller just follows that one)
 *   GET   progress → {"ok": true, "pending": bool, "status": {...} | null}
 *         (pending = request written but not picked up by the logger yet;
 *         status = the last status.json, see dht22_logger.py's Progress)
 * Errors: {"ok": false, "error": "..."}.
 */

declare(strict_types=1);

const TOKEN_FILE = '/etc/dht22-sync/token';
const ONDEMAND_DIR = '/run/dht22-ondemand';
const REQUEST_FILE = ONDEMAND_DIR . '/request.json';
const STATUS_FILE = ONDEMAND_DIR . '/status.json';
// A request the path unit hasn't picked up within this long means the
// trigger isn't running — report that rather than queueing forever.
const REQUEST_STALE_SECONDS = 30;
// A run that hasn't updated its status within this long (one attempt is
// ~2.5s; waiting on the sensor lock can take up to ~2 min) is assumed dead.
const RUN_STALE_SECONDS = 180;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['ok' => false, 'error' => $message]);
    exit;
}

function readJsonFile(string $path): ?array {
    $raw = @file_get_contents($path);
    if ($raw === false) {
        return null;
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : null;
}

$method = $_SERVER['REQUEST_METHOD'] ?? '';
if ($method !== 'POST' && $method !== 'GET') {
    fail(405, 'GET or POST required.');
}

if (!is_file(TOKEN_FILE)) {
    fail(500, 'Trigger token is not configured on this Pi — run setup/setup_sync_trigger.sh.');
}
$expected = trim((string) file_get_contents(TOKEN_FILE));
$given = trim((string) ($_SERVER['HTTP_X_SYNC_TOKEN'] ?? ''));
if ($expected === '' || $given === '' || !hash_equals($expected, $given)) {
    fail(403, 'Invalid or missing sync token.');
}

if (!is_dir(ONDEMAND_DIR)) {
    fail(500, 'On-demand reading is not set up on this Pi — re-run setup/setup_dht22_logger.sh.');
}

clearstatcache();
$pending = is_file(REQUEST_FILE);

if ($method === 'GET') {
    echo json_encode([
        'ok'      => true,
        'pending' => $pending,
        'status'  => readJsonFile(STATUS_FILE),
    ]);
    exit;
}

// -- POST: start a reading, unless one is already queued or running ----------
if ($pending) {
    $age = time() - (int) @filemtime(REQUEST_FILE);
    if ($age > REQUEST_STALE_SECONDS) {
        fail(503, 'A previous request was never picked up — is dht22-ondemand.path running? (systemctl status dht22-ondemand.path)');
    }
    $req = readJsonFile(REQUEST_FILE);
    echo json_encode(['ok' => true, 'id' => (string) ($req['id'] ?? ''), 'already' => true]);
    exit;
}

$status = readJsonFile(STATUS_FILE);
if ($status && in_array($status['state'] ?? '', ['waiting', 'reading'], true)) {
    $updated = isset($status['updated_at']) ? strtotime((string) $status['updated_at']) : false;
    if ($updated !== false && time() - $updated <= RUN_STALE_SECONDS) {
        echo json_encode(['ok' => true, 'id' => (string) ($status['id'] ?? ''), 'already' => true]);
        exit;
    }
}

$id = bin2hex(random_bytes(8));
$tmp = REQUEST_FILE . '.tmp';
// Written to a temp name and renamed, so the path unit never fires on a
// half-written file.
if (@file_put_contents($tmp, json_encode(['id' => $id, 'requested_at' => gmdate('c')])) === false || !@rename($tmp, REQUEST_FILE)) {
    @unlink($tmp);
    fail(500, 'Could not write the request file in ' . ONDEMAND_DIR . '.');
}

echo json_encode(['ok' => true, 'id' => $id, 'already' => false]);
