<?php
/**
 * geocode.php — place-name search for the Settings tab's Forecast section
 * (rpi5/web/js/script.js's places search), backed by Open-Meteo's free
 * geocoding API. A plain proxy, same idea as forecast.php: no database
 * involved, nothing to cache (unlike forecast.php's fixed location, a
 * search query is different on every call, so there's nothing worth
 * keeping around).
 *
 * Query params:
 *   ?q=Brno   Free-text place name, 1-80 chars after trimming. Required.
 *
 * Response: {"results": [{"name": "Brno, South Moravian Region, Czechia",
 * "latitude": 49.19522, "longitude": 16.60796}, ...]} — up to
 * RESULT_LIMIT entries, closest guesses first (Open-Meteo's own ordering).
 * `name` is composed here from the API's name/admin1/country fields so the
 * Settings tab can show one unambiguous label per result and, if added,
 * store it verbatim as that place's forecast_places.name (see
 * ../../../../db/database/sensors/tables/forecast_places.md) — this
 * endpoint itself writes nothing.
 */

declare(strict_types=1);

const RESULT_LIMIT = 8;
const QUERY_MAX_LEN = 80;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate');

function fail(int $httpCode, string $message): never {
    http_response_code($httpCode);
    echo json_encode(['error' => $message]);
    exit;
}

$q = trim((string) ($_GET['q'] ?? ''));
if ($q === '') {
    fail(400, 'q is required.');
}
// Plain strlen(), not mb_strlen() — the mbstring extension isn't installed
// on the Hive (same minimal PHP install forecast.php's docstring notes has
// no php-curl either), and a byte-length cap is a fine approximation for a
// sane ceiling like this one anyway, same convention MAX_LABEL_LEN/
// MAX_PLACE_NAME_LEN already use in settings.php.
if (strlen($q) > QUERY_MAX_LEN) {
    fail(400, 'q must be at most ' . QUERY_MAX_LEN . ' characters.');
}

$url = 'https://geocoding-api.open-meteo.com/v1/search?' . http_build_query([
    'name'     => $q,
    'count'    => RESULT_LIMIT,
    'language' => 'en',
    'format'   => 'json',
]);

// file_get_contents + stream context, same as forecast.php (no php-curl —
// see setup/setup_nginx_php.sh).
$context = stream_context_create(['http' => ['timeout' => 5]]);
$body = @file_get_contents($url, false, $context);
if ($body === false) {
    fail(502, 'Could not reach the place-search service.');
}

$data = json_decode($body, true);
$rows = $data['results'] ?? [];
if (!is_array($rows)) {
    $rows = [];
}

$results = [];
foreach ($rows as $row) {
    $lat = $row['latitude'] ?? null;
    $lon = $row['longitude'] ?? null;
    $name = $row['name'] ?? null;
    if (!is_numeric($lat) || !is_numeric($lon) || !is_string($name) || $name === '') {
        continue; // skip anything Open-Meteo returned without the essentials
    }
    // Compose a disambiguated label: "Brno, South Moravian Region, Czechia"
    // — admin1 (state/region) and country, whichever of the two the API
    // actually returned for this result (smaller places sometimes lack
    // admin1; a handful of results lack country too).
    $parts = [$name];
    if (!empty($row['admin1']) && is_string($row['admin1']) && $row['admin1'] !== $name) {
        $parts[] = $row['admin1'];
    }
    if (!empty($row['country']) && is_string($row['country'])) {
        $parts[] = $row['country'];
    }
    $results[] = [
        'name'      => implode(', ', $parts),
        'latitude'  => round((float) $lat, 5),
        'longitude' => round((float) $lon, 5),
    ];
}

echo json_encode(['results' => $results], JSON_UNESCAPED_SLASHES);
