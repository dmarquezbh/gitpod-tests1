<?php
// PHP "platform" entry: roteador mínimo sobre o servidor embutido (PHP_CLI_SERVER_WORKERS=4),
// pg_* direto (extensão php-pgsql) e Content-Length explícito.
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$path = $uri === null ? '/' : $uri;

function db(): PgSql\Connection {
    static $c = null;
    if ($c === null) {
        $c = pg_pconnect("host=127.0.0.1 user=benchmarkdbuser password=benchmarkdbpass dbname=hello_world connect_timeout=5");
    }
    return $c;
}

function enviar(string $corpo, string $tipo = 'application/json'): void {
    $len = strlen($corpo);
    header('Content-Type: ' . $tipo);
    header('Content-Length: ' . $len);
    echo $corpo;
}

if ($path === '/plaintext') {
    enviar('Hello, World!', 'text/plain');
} elseif ($path === '/json') {
    enviar('{"message":"Hello, World!"}');
} elseif ($path === '/db') {
    $id = random_int(1, 10000);
    $r = pg_query_params(db(), 'SELECT id, randomnumber FROM world WHERE id = $1', [$id]);
    $linha = pg_fetch_row($r);
    enviar('{"id":' . (int)$linha[0] . ',"randomNumber":' . (int)$linha[1] . '}');
} elseif ($path === '/queries') {
    $q = isset($_GET['q']) ? max(1, min(500, (int)$_GET['q'])) : 1;
    $ids = [];
    for ($i = 0; $i < $q; $i++) { $ids[] = random_int(1, 10000); }
    $arr = '{' . implode(',', $ids) . '}';
    $r = pg_query_params(db(), 'SELECT id, randomnumber FROM world WHERE id = ANY($1::int[])', [$arr]);
    $porId = [];
    while ($linha = pg_fetch_row($r)) { $porId[(int)$linha[0]] = (int)$linha[1]; }
    $partes = [];
    foreach ($ids as $id) { $partes[] = '{"id":' . $id . ',"randomNumber":' . $porId[$id] . '}'; }
    enviar('[' . implode(',', $partes) . ']');
} elseif ($path === '/updates') {
    $q = isset($_GET['q']) ? max(1, min(500, (int)$_GET['q'])) : 1;
    $ids = []; $novos = [];
    for ($i = 0; $i < $q; $i++) { $ids[] = random_int(1, 10000); $novos[] = random_int(1, 10000); }
    $sql = 'UPDATE world SET randomnumber = v.rn FROM unnest($1::int[], $2::int[]) AS v(id, rn) ' .
           'WHERE world.id = v.id RETURNING world.id, world.randomnumber';
    $r = pg_query_params(db(), $sql, ['{' . implode(',', $ids) . '}', '{' . implode(',', $novos) . '}']);
    $porId = [];
    while ($linha = pg_fetch_row($r)) { $porId[(int)$linha[0]] = (int)$linha[1]; }
    $partes = [];
    foreach ($ids as $i => $id) { $partes[] = '{"id":' . $id . ',"randomNumber":' . ($porId[$id] ?? $novos[$i]) . '}'; }
    enviar('[' . implode(',', $partes) . ']');
} elseif ($path === '/fortunes') {
    $r = pg_query(db(), 'SELECT id, message FROM fortune');
    $itens = [];
    while ($linha = pg_fetch_row($r)) { $itens[] = [(int)$linha[0], $linha[1]]; }
    $itens[] = [0, 'Additional fortune added at request time.'];
    usort($itens, fn($a, $b) => strcmp($a[1], $b[1]));
    $html = '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>';
    foreach ($itens as [$id, $msg]) {
        $html .= '<tr><td>' . $id . '</td><td>' . htmlspecialchars($msg, ENT_QUOTES, 'UTF-8') . '</td></tr>';
    }
    $html .= '</table></body></html>';
    enviar($html, 'text/html; charset=utf-8');
} else {
    http_response_code(404);
    header('Content-Length: 0');
}
