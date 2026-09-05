<?php
/**
 * deploy_webhook.php — GitHub push webhook receiver for the whole fleet.
 *
 * The Hive is the only Pi meant to be reachable from the internet (one
 * forwarded router port, pointed here) — GitHub can only ever reach this
 * Pi, never a Pi Zero directly. So a push to the repo's main branch:
 *   1. lands here as a GitHub webhook call;
 *   2. this Pi pulls + redeploys itself (setup/git_deploy.sh, as root via
 *      a narrow NOPASSWD sudo rule — see setup/setup_deploy_webhook.sh);
 *   3. this Pi then relays a deploy trigger to every registered Pi Zero's
 *      own web/deploy_trigger.php, over the LAN, using each sensor's
 *      ip_address from the `sensors` table (same lookup
 *      api/sync_trigger.php uses for "Sync Now" — see that file).
 *
 * Verified by X-Hub-Signature-256 (HMAC-SHA256 of the raw request body,
 * keyed by /etc/git-deploy/webhook_secret — set this same value as the
 * webhook's "Secret" in GitHub's repo settings). This is a SEPARATE secret
 * from /etc/git-deploy/token, the one relayed to each Pi Zero below —
 * GitHub never sees that one, and no Pi Zero ever sees this one.
 *
 * The actual pull+redeploy can take a few seconds per Pi (longer still
 * multiplied across an unreachable Pi Zero's relay timeout), which risks
 * outrunning GitHub's own wait time for a response. So once the request is
 * verified, this responds to GitHub immediately and keeps working after
 * the connection closes (fastcgi_finish_request) — the real per-Pi results
 * land in DEPLOY_LOG_FILE instead of the HTTP response.
 *
 * Request:  POST, GitHub's push payload (JSON), header
 *           X-Hub-Signature-256, header X-GitHub-Event: push (or `ping`,
 *           answered immediately without deploying anything, so GitHub's
 *           "Recent Deliveries" test button confirms setup works).
 * Response: {"ok": true, "note": "..."} immediately; real results go to
 *           DEPLOY_LOG_FILE.
 */

declare(strict_types=1);

const WEBHOOK_SECRET_FILE = '/etc/git-deploy/webhook_secret';
const DEPLOY_TOKEN_FILE = '/etc/git-deploy/token';
const GIT_DEPLOY_SCRIPT_PATH_FILE = '/etc/git-deploy/git_deploy_script';
const DEPLOY_LOG_FILE = '/var/log/git-deploy.log';
const BRANCH_REF = 'refs/heads/main';
const FLEET_REQUEST_TIMEOUT_SECONDS = 60; // a Pi Zero's own pull+redeploy runs synchronously before it responds

set_time_limit(300); // runs after the response is sent — see fastcgi_finish_request below

require __DIR__ . '/db.php'; // for fail() and db()

// This file runs from a *copy* of web/ under the nginx web root (see
// deploy_web.sh) — not from the git checkout — so it can't find
// git_deploy.sh by walking up from its own __DIR__. Read the path
// setup_deploy_webhook.sh resolved and recorded instead. That setup script
// wrote it via realpath(), the same canonical form the sudoers rule was
// installed for, so exec() below matches it exactly.
if (!is_file(GIT_DEPLOY_SCRIPT_PATH_FILE)) {
    fail(500, 'Deploy webhook is not configured — run setup/setup_deploy_webhook.sh.');
}
$gitDeployScript = trim((string) file_get_contents(GIT_DEPLOY_SCRIPT_PATH_FILE));
if ($gitDeployScript === '' || !is_file($gitDeployScript)) {
    fail(500, 'git_deploy.sh not found — check the checkout is intact.');
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    fail(405, 'POST required.');
}

if (!is_file(WEBHOOK_SECRET_FILE)) {
    fail(500, 'Deploy webhook is not configured — run setup/setup_deploy_webhook.sh.');
}
$secret = trim((string) file_get_contents(WEBHOOK_SECRET_FILE));
$payload = (string) file_get_contents('php://input');
$signatureHeader = (string) ($_SERVER['HTTP_X_HUB_SIGNATURE_256'] ?? '');
$expectedSignature = 'sha256=' . hash_hmac('sha256', $payload, $secret);
// hash_equals guards against timing attacks; the empty check comes first
// only so a misconfigured (empty) secret file can never itself count as a
// match.
if ($secret === '' || $signatureHeader === '' || !hash_equals($expectedSignature, $signatureHeader)) {
    fail(403, 'Invalid or missing signature.');
}

$event = (string) ($_SERVER['HTTP_X_GITHUB_EVENT'] ?? '');
if ($event === 'ping') {
    echo json_encode(['ok' => true, 'note' => 'pong']);
    exit;
}
if ($event !== 'push') {
    fail(400, "Unsupported event: {$event}");
}

$data = json_decode($payload, true);
$ref = is_array($data) ? (string) ($data['ref'] ?? '') : '';
if ($ref !== BRANCH_REF) {
    echo json_encode(['ok' => true, 'note' => "Ignoring push to {$ref}"]);
    exit;
}
$after = is_array($data) ? substr((string) ($data['after'] ?? ''), 0, 8) : '';

// -- Ack GitHub now; the real deploy work happens after this returns --------
echo json_encode(['ok' => true, 'note' => 'Deploy started — see ' . DEPLOY_LOG_FILE . ' on the Hive for results.']);
if (function_exists('fastcgi_finish_request')) {
    fastcgi_finish_request();
} else {
    // Fallback for a non-FPM SAPI (shouldn't apply here — setup_nginx_php.sh
    // always installs PHP-FPM — but keeps this safe if that ever changes).
    ignore_user_abort(true);
    while (ob_get_level() > 0) {
        ob_end_flush();
    }
    flush();
}

$log = fopen(DEPLOY_LOG_FILE, 'a');
$logLine = function (string $line) use ($log): void {
    fwrite($log, $line . "\n");
};
$logLine('==== ' . date('c') . " push {$ref} @ {$after} ====");

// -- Redeploy this Pi (the Hive) first ---------------------------------------
exec('sudo ' . escapeshellarg('/usr/bin/bash') . ' ' . escapeshellarg($gitDeployScript) . ' 2>&1', $selfOutputLines, $selfExit);
$logLine('[self] exit ' . $selfExit);
foreach ($selfOutputLines as $line) {
    $logLine('[self] ' . $line);
}

// -- Relay to every registered Pi Zero ---------------------------------------
if (!is_file(DEPLOY_TOKEN_FILE)) {
    $logLine('[fleet] Deploy token not configured — run setup/setup_deploy_webhook.sh. Skipping fleet relay.');
    fclose($log);
    exit;
}
$token = trim((string) file_get_contents(DEPLOY_TOKEN_FILE));

$pdo = db();
$sensors = $pdo->query('SELECT name, ip_address FROM sensors')->fetchAll();
foreach ($sensors as $row) {
    $name = (string) $row['name'];
    // Prefer the address dht22_logger.py keeps current on every successful
    // write (see remote_db.py's register_sensor); fall back to mDNS for a
    // sensor that's never gone through that code path yet.
    $host = ($row['ip_address'] !== null && $row['ip_address'] !== '') ? $row['ip_address'] : "{$name}.local";

    $context = stream_context_create([
        'http' => [
            'method'        => 'POST',
            'header'        => "X-Deploy-Token: {$token}\r\n",
            'timeout'       => FLEET_REQUEST_TIMEOUT_SECONDS,
            'ignore_errors' => true, // so a non-2xx response body is still readable, not just `false`
        ],
    ]);
    $body = @file_get_contents("http://{$host}/deploy_trigger.php", false, $context);

    if ($body === false) {
        $logLine("[{$name}] Could not reach {$host}.");
        continue;
    }
    $decoded = json_decode($body, true);
    if (!is_array($decoded)) {
        $logLine("[{$name}] Unexpected response: " . substr($body, 0, 300));
        continue;
    }
    $logLine("[{$name}] ok=" . ($decoded['ok'] ?? 'false') . ' ' . trim((string) ($decoded['output'] ?? ($decoded['error'] ?? ''))));
}

fclose($log);
