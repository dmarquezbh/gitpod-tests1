// Dart "platform" entry: dart:io HttpServer (um isolate por CPU) + libpq via dart:ffi.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _Malloc = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _Free = void Function(Pointer<Uint8>);
typedef _ConnectNative = Pointer<Void> Function(Pointer<Uint8>);
typedef _Connect = Pointer<Void> Function(Pointer<Uint8>);
typedef _ExecNative = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>);
typedef _Exec = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>);
typedef _NtuplesNative = Int32 Function(Pointer<Void>);
typedef _Ntuples = int Function(Pointer<Void>);
typedef _GetvalueNative = Pointer<Uint8> Function(Pointer<Void>, Int32, Int32);
typedef _Getvalue = Pointer<Uint8> Function(Pointer<Void>, int, int);
typedef _ClearNative = Void Function(Pointer<Void>);
typedef _Clear = void Function(Pointer<Void>);

final _lib = DynamicLibrary.open('libpq.so.5');
final _libc = DynamicLibrary.process();
late final _malloc = _libc.lookupFunction<_MallocNative, _Malloc>('malloc');
late final _free = _libc.lookupFunction<_FreeNative, _Free>('free');
late final _connect = _lib.lookupFunction<_ConnectNative, _Connect>('PQconnectdb');
late final _exec = _lib.lookupFunction<_ExecNative, _Exec>('PQexec');
late final _ntuples = _lib.lookupFunction<_NtuplesNative, _Ntuples>('PQntuples');
late final _getvalue = _lib.lookupFunction<_GetvalueNative, _Getvalue>('PQgetvalue');
late final _clear = _lib.lookupFunction<_ClearNative, _Clear>('PQclear');

Pointer<Uint8> _toC(String s) {
  final bytes = utf8.encode(s);
  final p = _malloc(bytes.length + 1);
  for (var i = 0; i < bytes.length; i++) {
    p[i] = bytes[i];
  }
  p[bytes.length] = 0;
  return p;
}

String _fromC(Pointer<Uint8> p) {
  final bytes = <int>[];
  var i = 0;
  while (true) {
    final b = p[i];
    if (b == 0) break;
    bytes.add(b);
    i++;
  }
  return String.fromCharCodes(bytes);
}

Future<void> main(List<String> args) async {
  final port = int.parse(Platform.environment['PORT'] ?? '8099');
  await _worker(port);
}

Future<void> _worker(int port) async {
  final db = _connect(_toC('postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world'));
  final rnd = Random();
  String qtd(Uri uri) {
    final q = int.tryParse(uri.queryParameters['q'] ?? '1') ?? 1;
    return q.clamp(1, 500).toString();
  }

  List<(int, int)> consulta(String sql) {
    final r = _exec(db, _toC(sql));
    final n = _ntuples(r);
    final linhas = <(int, int)>[];
    for (var i = 0; i < n; i++) {
      linhas.add((int.tryParse(_fromC(_getvalue(r, i, 0))) ?? 0, int.tryParse(_fromC(_getvalue(r, i, 1))) ?? 0));
    }
    _clear(r);
    return linhas;
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('dart-platform on :$port');
  server.autoCompress = false;
  await for (final req in server) {
    final uri = req.uri;
    final path = uri.path;
    req.response.headers.contentType = ContentType.json;
    try {
      if (path == '/plaintext') {
        req.response.headers.contentType = ContentType.text;
        req.response.write('Hello, World!');
      } else if (path == '/json') {
        req.response.write('{"message":"Hello, World!"}');
      } else if (path == '/db') {
        final id = rnd.nextInt(10000) + 1;
        final r = consulta('SELECT id, randomnumber FROM world WHERE id = $id');
        req.response.write('{"id":${r[0].$1},"randomNumber":${r[0].$2}}');
      } else if (path == '/queries') {
        final q = int.parse(qtd(uri));
        final ids = List.generate(q, (_) => rnd.nextInt(10000) + 1);
        final rows = consulta('SELECT id, randomnumber FROM world WHERE id IN (${ids.join(",")})');
        final porId = {for (final r in rows) r.$1: r.$2};
        req.response.write('[${ids.map((id) => '{"id":$id,"randomNumber":${porId[id] ?? 0}}').join(",")}]');
      } else if (path == '/updates') {
        final q = int.parse(qtd(uri));
        final pares = List.generate(q, (_) => (rnd.nextInt(10000) + 1, rnd.nextInt(10000) + 1));
        final values = pares.map((p) => '(${p.$1},${p.$2})').join(',');
        final rows = consulta(
            'UPDATE world SET randomnumber = v.rn FROM (VALUES $values) AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber');
        final porId = {for (final r in rows) r.$1: r.$2};
        req.response.write('[${pares.map((p) => '{"id":${p.$1},"randomNumber":${porId[p.$1] ?? p.$2}}').join(",")}]');
      } else if (path == '/fortunes') {
        final rows = consulta('SELECT id, message FROM fortune');
        final r2 = _exec(db, _toC('SELECT id, message FROM fortune'));
        final itens = <(int, String)>[];
        for (var i = 0; i < _ntuples(r2); i++) {
          itens.add((int.tryParse(_fromC(_getvalue(r2, i, 0))) ?? 0, _fromC(_getvalue(r2, i, 1))));
        }
        _clear(r2);
        itens.add((0, 'Additional fortune added at request time.'));
        itens.sort((a, b) => a.$2.compareTo(b.$2));
        final html = StringBuffer(
            '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>');
        for (final it in itens) {
          final msg = it.$2
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;');
          html.write('<tr><td>${it.$1}</td><td>$msg</td></tr>');
        }
        html.write('</table></body></html>');
        req.response.headers.contentType = ContentType.html;
        req.response.write(html.toString());
      } else {
        req.response.statusCode = 404;
      }
    } finally {
      await req.response.close();
    }
  }
}
