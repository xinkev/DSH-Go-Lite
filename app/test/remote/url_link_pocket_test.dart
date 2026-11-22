// The direct URL link around dsh-pocket: sign in with the PIN, carry the gate
// cookie, and recover exactly once from a cookie the engine restart killed.

import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/url/pocket_auth.dart';
import 'package:dsh_app/remote/url/url_host_config.dart';
import 'package:dsh_app/remote/url/url_link.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const goodPin = 'good-pin';
  const freshCookie = 'dsh_pocket_token=fresh';
  const staleCookie = 'dsh_pocket_token=stale';

  UrlHostLink build(_Fixture fixture) => UrlHostLink(
    config: UrlHostConfig(id: 'url-1', name: 'gate', baseUri: Uri.parse('https://dsh.example.com')),
    loadSecrets: () async => fixture.secrets,
    saveCookie: (_) async {},
    savePocketCookie: (cookie) async => fixture.pocketSaves.add(cookie),
    pocketLogin: (base, pin, headers) async {
      fixture.logins.add(pin);
      fixture.loginHeaders.add(headers);
      if (pin != goodPin) throw const PocketLoginException(PocketLoginReason.rejected);
      return freshCookie;
    },
    connect:
        ({
          required Uri baseUri,
          required Map<String, String> headers,
          String? token,
          DshCookie? cookie,
          String? pocketCookie,
          required Duration readyTimeout,
        }) async {
          fixture.attempts++;
          fixture.connectCookies.add(pocketCookie);
          final failure = fixture.remainingFailures;
          if (failure != null) throw failure;
          return DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
        },
    retryFirstOpen: false,
  );

  test('a saved PIN with no gate cookie signs in before the first connect', () async {
    final fixture = _Fixture(const UrlHostSecrets(pocketPin: goodPin));
    final link = build(fixture);
    addTearDown(link.close);

    await link.open();

    expect(fixture.logins, [goodPin]);
    expect(fixture.connectCookies, [freshCookie]);
    expect(fixture.pocketSaves, [freshCookie]);
    expect(link.status.isConnected, isTrue);
  });

  test('the saved proxy headers ride the PIN sign-in too', () async {
    final fixture = _Fixture(
      const UrlHostSecrets(pocketPin: goodPin, accessToken: 'access', headers: 'CF-Access-Client-Id: id'),
    );
    final link = build(fixture);
    addTearDown(link.close);

    await link.open();

    expect(fixture.loginHeaders.single, {'Authorization': 'Bearer access', 'CF-Access-Client-Id': 'id'});
  });

  test('a live gate cookie is reused without signing in again', () async {
    final fixture = _Fixture(const UrlHostSecrets(pocketPin: goodPin, pocketCookie: staleCookie));
    final link = build(fixture);
    addTearDown(link.close);

    await link.open();

    expect(fixture.logins, isEmpty);
    expect(fixture.connectCookies, [staleCookie]);
    expect(fixture.pocketSaves, isEmpty);
  });

  test('a stale gate cookie is cleared once, the PIN signs in, and the open retries once', () async {
    final fixture = _Fixture(
      const UrlHostSecrets(pocketPin: goodPin, pocketCookie: staleCookie),
      failures: [const DshHttpException(401, 'gate refused')],
    );
    final link = build(fixture);
    addTearDown(link.close);

    await link.open();

    expect(fixture.attempts, 2);
    expect(fixture.connectCookies, [staleCookie, freshCookie]);
    expect(fixture.pocketSaves, [null, freshCookie]);
    expect(fixture.logins, [goodPin]);
    expect(link.status.isConnected, isTrue);
  });

  test('a stale gate cookie without a saved PIN is cleared and reported, not retried', () async {
    final fixture = _Fixture(
      const UrlHostSecrets(pocketCookie: staleCookie),
      failures: [const DshHttpException(401, 'gate refused')],
    );
    final link = build(fixture);
    addTearDown(link.close);

    await expectLater(
      link.open(),
      throwsA(isA<HostLinkError>().having((e) => e.message, 'message', appL10n.remoteUrlErrPocketPin)),
    );

    expect(fixture.attempts, 1);
    expect(fixture.logins, isEmpty);
    expect(fixture.pocketSaves, [null]);
  });

  test('a wrong PIN after a stale cookie is reported once and never loops', () async {
    final fixture = _Fixture(
      const UrlHostSecrets(pocketPin: 'bad-pin', pocketCookie: staleCookie),
      failures: [const DshHttpException(401, 'gate refused')],
    );
    final link = build(fixture);
    addTearDown(link.close);

    await expectLater(
      link.open(),
      throwsA(
        isA<HostLinkError>()
            .having((e) => e.kind, 'kind', HostLinkErrorKind.loginFailed)
            .having((e) => e.message, 'message', appL10n.remoteUrlErrPocketPin),
      ),
    );

    expect(fixture.attempts, 1);
    expect(fixture.logins, ['bad-pin']);
    expect(fixture.pocketSaves, [null]);
  });

  test('a fresh PIN that still gets 401 reports the engine token, not the PIN', () async {
    final fixture = _Fixture(
      const UrlHostSecrets(pocketPin: goodPin, pocketCookie: staleCookie),
      failures: [const DshHttpException(401, 'gate refused'), const DshHttpException(401, 'token refused')],
    );
    final link = build(fixture);
    addTearDown(link.close);

    await expectLater(
      link.open(),
      throwsA(isA<HostLinkError>().having((e) => e.message, 'message', appL10n.remoteUrlErrTokenRejected)),
    );

    expect(fixture.attempts, 2);
    expect(fixture.logins, [goodPin]);
    expect(fixture.pocketSaves, [null, freshCookie]);
  });

  test('the connector turns a gate login page served for the engine token into a gate refusal', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<form action="/pocket-login">enter the PIN</form>');
      await request.response.close();
    });

    await expectLater(
      connectUrlHost(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        headers: const {},
        token: 'launch-token',
        pocketCookie: staleCookie,
        readyTimeout: const Duration(seconds: 2),
      ),
      throwsA(isA<PocketGateRefused>()),
    );
  });

  test('the connector probes for a gate login page when only the cookie can sign in', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<form action="/pocket-login">enter the PIN</form>');
      await request.response.close();
    });

    await expectLater(
      connectUrlHost(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        headers: const {},
        pocketCookie: staleCookie,
        readyTimeout: const Duration(seconds: 2),
      ),
      throwsA(isA<PocketGateRefused>()),
    );
  });

  test('without a PIN the link sends no gate cookie and performs no sign-in', () async {
    final fixture = _Fixture(const UrlHostSecrets(launchToken: 'engine-token'));
    final link = build(fixture);
    addTearDown(link.close);

    await link.open();

    expect(fixture.attempts, 1);
    expect(fixture.logins, isEmpty);
    expect(fixture.connectCookies, [null]);
    expect(fixture.pocketSaves, isEmpty);
  });
}

class _Fixture {
  _Fixture(this.secrets, {List<DshHttpException> failures = const []}) : _failures = [...failures];

  final UrlHostSecrets secrets;
  final List<DshHttpException> _failures;
  final logins = <String>[];
  final loginHeaders = <Map<String, String>>[];
  final pocketSaves = <String?>[];
  final connectCookies = <String?>[];
  int attempts = 0;

  DshHttpException? get remainingFailures => _failures.isEmpty ? null : _failures.removeAt(0);
}
