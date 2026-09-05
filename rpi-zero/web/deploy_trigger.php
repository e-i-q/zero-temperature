<?php
/**
 * deploy_trigger.php — pulls the latest main branch and redeploys this Pi
 * Zero's web/ directory, on demand.
 *
 * Called by rpi5/web/api/deploy_webhook.php after GitHub's push webhook
 * fires on the Hive — see that file's docstring for the overall flow (the
 * Hive is the only Pi with a port forwarded to the internet, so it's the
 * one GitHub can reach; it relays here over the LAN for every Pi Zero).
 *
 * Unlike readings.php, this is NOT read-only — it runs setup/git_deploy.sh
 * as root (via a narrow NOPASSWD sudo rule — see
 * setup/setup_deploy_trigger.sh), so it's gated by a shared-secret header
 * rather than being open to anyone who can reach this Pi's web port. Same
 * pattern as sync.php, but a SEPARATE secret — deploy and sync are
 * different privileges. See setup/setup_deploy_trigger.sh for how the
 * secret is provisioned. Deliberately kept outside the web root
 * (/etc/git-deploy/), so deploy_web.sh re-syncing web/ can never touch or
 * expose it.
 *
 * Request:  POST, header X-Deploy-Token: <shared secret>, no body.
 * Response: JSON {"ok": true, "output": "..."} or {"ok": false, "error": "..."}.
 */

declare(strict_types=1);

const TOKEN_FILE = '/etc/git-deploy/token';

// A first deploy of a change touching setup/ or python/ is still just a
// git pull + a small `cp -a` of web/ — this is generous mainly so a
// momentarily slow SD card never turns a real success into a reported
// timeout.
set_time_limit(120);

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
    fail(500, 'Deploy trigger is not configured on this Pi — run setup/setup_deploy_trigger.sh.');
}
$expected = trim((string) file_get_contents(TOKEN_FILE));
$given = trim((string) ($_SERVER['HTTP_X_DEPLOY_TOKEN'] ?? ''));
// hash_equals guards against timing attacks on the comparison; the empty
// checks come first only so a misconfigured (empty) token file can never
// itself count as a match.
if ($expected === '' || $given === '' || !hash_equals($expected, $given)) {
    fail(403, 'Invalid or missing deploy token.');
}

// realpath(), not a literal __DIR__ . '/../setup/...' concatenation — the
// sudoers rule setup_deploy_trigger.sh installs matches this exact
// canonical path with no '..' segments, so exec() below must pass the
// same string or sudo will refuse it.
$gitDeployScript = realpath(__DIR__ . '/../setup/git_deploy.sh');
if ($gitDeployScript === false) {
    fail(500, 'git_deploy.sh not found — check the checkout is intact.');
}

exec('sudo ' . escapeshellarg('/usr/bin/bash') . ' ' . escapeshellarg($gitDeployScript) . ' 2>&1', $outputLines, $exitCode);

echo json_encode([
    'ok'     => $exitCode === 0,
    'output' => implode("\n", $outputLines),
]);
