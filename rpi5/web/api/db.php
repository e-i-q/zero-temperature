<?php
/**
 * db.php — shared PostgreSQL connection for the Hive dashboard's API
 * endpoints. Connects to the central database on this same Pi 5 as the
 * `web_reader` role (see ../../../../db/database/sensors/meta.md — read-only
 * grants on `sensors` and `readings`).
 *
 * Auth: no password is passed in code or read from the environment — PDO's
 * pgsql driver (via libpq) picks it up from www-data's ~/.pgpass, same
 * pattern as rpi-zero/python/dht22_logger.py uses for its writer role. That
 * file must exist and be chmod 600, with a line of the form:
 *     127.0.0.1:5432:sensors:web_reader:<password>
 */

declare(strict_types=1);

const PG_HOST = '127.0.0.1'; // the Hive database runs on this same Pi 5
const PG_PORT = 5432;
const PG_DBNAME = 'sensors';
const PG_USER = 'web_reader';

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error' => $message]);
    exit;
}

// PostgreSQL TIMESTAMP columns (no time zone) come back from PDO as bare
// "YYYY-MM-DD HH:MM:SS" strings — no offset, no 'Z'. Every recorded_at in
// this schema is a UTC wall-clock value (see
// rpi-zero/python/dht22_logger.py's timestamp = datetime.now(timezone.utc)...),
// but a browser parsing that bare string via `new Date(...)` treats it as
// LOCAL time, not UTC. Stamp it unambiguous ISO-8601 before it ever reaches
// the client, so charts/tables/"last seen" all land on the real instant
// regardless of the viewer's time zone.
function toIsoUtc(string $pgTimestamp): string {
    return str_replace(' ', 'T', $pgTimestamp) . 'Z';
}

function db(): PDO {
    static $pdo = null;
    if ($pdo !== null) {
        return $pdo;
    }
    try {
        $dsn = sprintf('pgsql:host=%s;port=%d;dbname=%s', PG_HOST, PG_PORT, PG_DBNAME);
        // No password= here on purpose — see docstring above.
        $pdo = new PDO($dsn, PG_USER, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    } catch (PDOException $e) {
        fail(
            500,
            'Could not connect to the Hive database: ' . $e->getMessage() .
            '. Check that PostgreSQL is running on ' . PG_HOST . ' and that www-data has a ~/.pgpass entry for ' . PG_USER . '.'
        );
    }
    return $pdo;
}
