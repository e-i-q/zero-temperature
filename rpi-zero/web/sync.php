<?php
/**
 * sync.php — runs sync_backlog.py on this Pi Zero, on demand.
 *
 * Exists so the Hive dashboard's Settings tab can trigger a manual catch-up
 * sync for this specific sensor node without SSHing in — e.g. right after a
 * Pi Zero that doesn't (yet) have the offline→online auto-trigger deployed,
 * or one you don't want to wait on for its next scheduled reading, comes
 * back on the network. See rpi5/web/api/sync_trigger.php, the Hive-side
 * relay that calls this.
 *
 * Unlike readings.php, this is NOT read-only — it runs a subprocess, so
 * it's gated by a shared-secret header rather than being open to anyone who
 * can reach this Pi's web port. See setup/setup_sync_trigger.sh for how the
 * secret and script/db paths are provisioned. Deliberately kept outside the
 * web root (/etc/dht22-sync/), so `deploy_web.sh` re-syncing web/ can never
 * touch or expose them.
 *
 * Request:  POST, header X-Sync-Token: <shared secret>, no body.
 * Response: JSON {"ok": true, "output": "..."} or {"ok": false, "error": "..."}.
 */

declare(strict_types=1);

const TOKEN_FILE = '/etc/dht22-sync/token';
const CONFIG_FILE = '/etc/dht22-sync/config.php';

// A first run after deploying the backlog-sync feature can walk this Pi's
// entire local history (see sync_backlog.py's docstring) — give it room
// rather than hitting PHP's default 30s limit partway through.
set_time_limit(300);

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['ok' => false, 'error' => $message]);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    fail(405, 'POST required.');
}

if (!is_file(TOKEN_FILE)) {
    fail(500, 'Sync trigger is not configured on this Pi — run setup/setup_sync_trigger.sh.');
}
$expected = trim((string) file_get_contents(TOKEN_FILE));
$given = trim((string) ($_SERVER['HTTP_X_SYNC_TOKEN'] ?? ''));
// hash_equals guards against timing attacks on the comparison; the empty
// checks come first only so a misconfigured (empty) token file can never
// itself count as a match.
if ($expected === '' || $given === '' || !hash_equals($expected, $given)) {
    fail(403, 'Invalid or missing sync token.');
}

if (!is_file(CONFIG_FILE)) {
    fail(500, 'Sync trigger is not configured on this Pi — run setup/setup_sync_trigger.sh.');
}
require CONFIG_FILE; // defines PYTHON_BIN, SYNC_SCRIPT_PATH, DB_PATH

// Every argument here comes from CONFIG_FILE (written once, at setup time,
// by root) — nothing from the request reaches the command line, so there's
// no injection surface despite the shell-out.
$cmd = escapeshellarg(PYTHON_BIN) . ' ' . escapeshellarg(SYNC_SCRIPT_PATH) . ' --db ' . escapeshellarg(DB_PATH);
exec($cmd . ' 2>&1', $outputLines, $exitCode);

echo json_encode([
    'ok'     => $exitCode === 0,
    'output' => implode("\n", $outputLines),
]);
