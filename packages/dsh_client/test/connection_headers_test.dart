import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('extra headers reach POST, GET and the WebSocket upgrade', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String, Map<String, String>>{};
    const names = ['authorization', 'cf-access-client-id', 'x-extra'];
    server.listen((request) async {
      seen[request.uri.path] = {
        for (final name in names)
          if (request.headers.value(name) case final value?) name: value,
      };
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
      headers: const {'Authorization': 'Bearer t', 'CF-Access-Client-Id': 'id', 'X-Extra': '1'},
    );
    try {
      await connection.postJson('/api/probe', {});
      await connection.get('/health');
      final socket = await connection.connectWebSocket('/ws');
      await socket.close();
      const expected = {'authorization': 'Bearer t', 'cf-access-client-id': 'id', 'x-extra': '1'};
      for (final path in ['/api/probe', '/health', '/ws']) {
        expect(seen[path], expected, reason: path);
      }
      // The offloaded read worker cannot carry these headers, so it stays off.
      expect(connection.canReadSessionsInBackground, isFalse);
    } finally {
      connection.close();
      await server.close(force: true);
    }
  });
}
