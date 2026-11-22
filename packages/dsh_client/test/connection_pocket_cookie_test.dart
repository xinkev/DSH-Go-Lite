import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('the pocket gate cookie shares one Cookie header with the engine cookie', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String, String?>{};
    server.listen((request) async {
      seen[request.uri.path] = request.headers.value(HttpHeaders.cookieHeader);
      if (request.uri.path == '/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        await socket.close();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final connection = DshConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      pocketCookie: 'dsh_pocket_token=gate',
      cookie: const DshCookie(name: 'dsh-auth-x', value: 'v1.a.b', authority: '127.0.0.1'),
    );
    try {
      await connection.postJson('/api/probe', {});
      await connection.get('/health');
      final socket = await connection.connectWebSocket('/ws');
      await socket.close();
      const expected = 'dsh_pocket_token=gate; dsh-auth-x=v1.a.b';
      for (final path in ['/api/probe', '/health', '/ws']) {
        expect(seen[path], expected, reason: path);
      }
      // The offloaded read worker cannot carry the gate cookie, so it stays off.
      expect(connection.canReadSessionsInBackground, isFalse);
    } finally {
      connection.close();
      await server.close(force: true);
    }
  });

  test('the gate cookie alone reaches every request before a login', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String?>[];
    server.listen((request) async {
      seen.add(request.headers.value(HttpHeaders.cookieHeader));
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final connection = DshConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      pocketCookie: 'dsh_pocket_token=gate',
    );
    try {
      await connection.get('/');
      await connection.postJson('/api/probe', {});
      expect(seen, ['dsh_pocket_token=gate', 'dsh_pocket_token=gate']);
      expect(connection.canReadSessionsInBackground, isFalse);
    } finally {
      connection.close();
      await server.close(force: true);
    }
  });
}
