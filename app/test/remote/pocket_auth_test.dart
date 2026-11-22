// dsh-pocket's access-PIN exchange: POST /pocket-login, the GET fallback and
// the `dsh_pocket_token` cookie. No DSH engine is involved.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/url/pocket_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late List<_Seen> seen;
  late Future<void> Function(HttpRequest request) handle;

  setUp(() async {
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      seen.add(
        _Seen(
          method: request.method,
          path: request.uri.path,
          query: request.uri.queryParametersAll,
          contentType: request.headers.contentType?.mimeType,
          cfAccess: request.headers.value('cf-access-client-id'),
          body: body,
        ),
      );
      await handle(request);
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void respond(HttpRequest request, {int status = 200, String? cookie, String body = ''}) {
    if (cookie != null) {
      request.response.headers.add(HttpHeaders.setCookieHeader, cookie);
    }
    request.response.statusCode = status;
    request.response.write(body);
    request.response.close();
  }

  test('POST /pocket-login carries the PIN as a form field and captures the cookie', () async {
    handle = (request) async {
      respond(request, status: 303, cookie: 'dsh_pocket_token=sha256value; Max-Age=2592000; HttpOnly; Path=/');
    };

    final cookie = await PocketAuth.login(base, ' 12345678 ', headers: {'CF-Access-Client-Id': 'id'});

    expect(cookie, 'dsh_pocket_token=sha256value');
    expect(seen.single.cfAccess, 'id', reason: 'a Cloudflare Access host logs in through the same headers');
    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.path, '/pocket-login');
    expect(seen.single.contentType, 'application/x-www-form-urlencoded');
    expect(seen.single.body, 'token=12345678');
    expect(seen.single.query, isEmpty, reason: 'the PIN never goes in a query string');
  });

  test('the form body percent-encodes the PIN', () async {
    handle = (request) async => respond(request, cookie: 'dsh_pocket_token=ok; Path=/');

    await PocketAuth.login(base, 'a b&c=d');

    expect(seen.single.body, 'token=a+b%26c%3Dd');
  });

  test('a wrong PIN answers the login page and is reported, without the GET fallback', () async {
    handle = (request) async => respond(request, body: '<form action="/pocket-login">wrong</form>');

    await expectLater(
      PocketAuth.login(base, '12345678'),
      throwsA(
        isA<PocketLoginException>()
            .having((e) => e.reason, 'reason', PocketLoginReason.rejected)
            .having((e) => e.statusCode, 'status', 200),
      ),
    );
    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
  });

  test('a locked gate (429) is reported without trying the GET fallback', () async {
    handle = (request) async => respond(request, status: 429);

    await expectLater(
      PocketAuth.login(base, '12345678'),
      throwsA(
        isA<PocketLoginException>()
            .having((e) => e.reason, 'reason', PocketLoginReason.locked)
            .having((e) => e.statusCode, 'status', 429),
      ),
    );
    expect(seen, hasLength(1));
  });

  test('a proxy without the POST route falls back to GET /?token= and captures the cookie', () async {
    handle = (request) async {
      if (request.method == 'POST') {
        respond(request, status: 405);
        return;
      }
      respond(request, cookie: 'dsh_pocket_token=fromget; Path=/');
    };

    final cookie = await PocketAuth.login(base, '12345678', headers: {'CF-Access-Client-Id': 'id'});

    expect(cookie, 'dsh_pocket_token=fromget');
    expect(seen, hasLength(2));
    expect(seen.map((s) => s.cfAccess), everyElement('id'));
    expect(seen.last.method, 'GET');
    expect(seen.last.path, '/');
    expect(seen.last.query, {
      'token': ['12345678'],
    });
  });

  test('only the dsh_pocket_token cookie is accepted', () async {
    handle = (request) async {
      request.response.headers.add(HttpHeaders.setCookieHeader, 'other=1; Path=/');
      request.response.headers.add(HttpHeaders.setCookieHeader, 'dsh_pocket_token=; Path=/');
      respond(request);
    };

    await expectLater(
      PocketAuth.login(base, '12345678'),
      throwsA(isA<PocketLoginException>().having((e) => e.reason, 'reason', PocketLoginReason.rejected)),
    );
  });

  test('an unreachable proxy is retryable', () async {
    final port = server.port;
    await server.close(force: true);
    await expectLater(
      PocketAuth.login(Uri.parse('http://127.0.0.1:$port'), '12345678'),
      throwsA(isA<PocketLoginException>().having((e) => e.retryable, 'retryable', isTrue)),
    );
  });
}

class _Seen {
  const _Seen({
    required this.method,
    required this.path,
    required this.query,
    required this.contentType,
    required this.cfAccess,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, List<String>> query;
  final String? contentType;
  final String? cfAccess;
  final String body;
}
