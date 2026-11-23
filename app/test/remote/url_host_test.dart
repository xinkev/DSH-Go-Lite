// Direct URL hosts: normalization, stored config and secret placement. These
// are the pieces a Cloudflare Tunnel / reverse-proxy host depends on before
// any socket opens.

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(secrets)]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> loaded(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).ready;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
  });

  group('parseUrlHost', () {
    test('https is the default, trailing slashes go, a mount path stays', () {
      expect(parseUrlHost('dsh.example.com').baseUri, Uri.parse('https://dsh.example.com'));
      expect(parseUrlHost('  https://dsh.example.com/  ').baseUri, Uri.parse('https://dsh.example.com'));
      expect(parseUrlHost('https://dsh.example.com/dsh/').baseUri, Uri.parse('https://dsh.example.com/dsh'));
      expect(parseUrlHost('https://dsh.example.com:8443').baseUri, Uri.parse('https://dsh.example.com:8443'));
    });

    test('loopback may use plain http, and a bare loopback address defaults to it', () {
      for (final raw in ['localhost', 'localhost:3080', '127.0.0.1:3080', '[::1]:3080']) {
        final parsed = parseUrlHost(raw);
        expect(parsed.baseUri.scheme, 'http', reason: raw);
      }
      expect(parseUrlHost('http://127.0.0.1:3080/').baseUri, Uri.parse('http://127.0.0.1:3080'));
      expect(parseUrlHost('http://localhost:3080').baseUri, Uri.parse('http://localhost:3080'));
      expect(parseUrlHost('http://[::1]:3080').baseUri, Uri.parse('http://[::1]:3080'));
    });

    test('plain http off loopback is refused', () {
      for (final raw in ['http://dsh.example.com', 'http://8.8.8.8:3080', 'http://example.local.evil.com']) {
        expect(
          () => parseUrlHost(raw),
          throwsA(isA<UrlHostFormatException>().having((e) => e.problem, 'problem', UrlHostProblem.insecure)),
          reason: raw,
        );
      }
    });

    test('a LAN address may use plain http: dsh-pocket hands out one', () {
      for (final raw in [
        'http://192.168.151.16:3081',
        'http://10.0.2.2:3080',
        'http://172.16.4.9:3080',
        'http://169.254.10.20:3080',
        'http://dsh-pc.local:3080',
      ]) {
        expect(parseUrlHost(raw).baseUri.toString(), raw, reason: raw);
      }
    });

    test('the whole dsh web line is accepted and its token separated', () {
      final parsed = parseUrlHost('dsh web: https://dsh.example.com/?token=abc-123');
      expect(parsed.baseUri, Uri.parse('https://dsh.example.com'));
      expect(parsed.launchToken, 'abc-123');
      final bare = parseUrlHost('https://dsh.example.com/tunnel/?token=t');
      expect(bare.baseUri, Uri.parse('https://dsh.example.com/tunnel'));
      expect(bare.launchToken, 't');
      expect(parseUrlHost('https://dsh.example.com').launchToken, isNull);
    });

    test('other query parts, fragments and credentials are refused', () {
      UrlHostProblem problem(String raw) {
        try {
          parseUrlHost(raw);
        } on UrlHostFormatException catch (e) {
          return e.problem;
        }
        fail('accepted $raw');
      }

      expect(problem(''), UrlHostProblem.missing);
      expect(problem('   '), UrlHostProblem.missing);
      expect(problem('https://dsh.example.com/?foo=1'), UrlHostProblem.query);
      expect(problem('https://dsh.example.com/?token=a&token=b'), UrlHostProblem.query);
      expect(problem('https://dsh.example.com/?token='), UrlHostProblem.query);
      expect(problem('https://dsh.example.com/#chat'), UrlHostProblem.invalid);
      expect(problem('https://user:pw@dsh.example.com'), UrlHostProblem.invalid);
      expect(problem('ftp://dsh.example.com'), UrlHostProblem.invalid);
      expect(problem('https://'), UrlHostProblem.invalid);
    });
  });

  group('url headers', () {
    test('Name: value lines, blank lines ignored', () {
      expect(parseUrlHeaders(''), isEmpty);
      expect(parseUrlHeaders(null), isEmpty);
      expect(parseUrlHeaders(' CF-Access-Client-Id: id\n\nCF-Access-Client-Secret: secret '), {
        'CF-Access-Client-Id': 'id',
        'CF-Access-Client-Secret': 'secret',
      });
    });

    test('a bearer token becomes Authorization unless a header already sets it', () {
      expect(urlRequestHeaders(' abc ', null), {'Authorization': 'Bearer abc'});
      expect(urlRequestHeaders('abc', 'Authorization: Bearer typed'), {'Authorization': 'Bearer typed'});
      expect(urlRequestHeaders('', 'X-Test: 1'), {'X-Test': '1'});
    });

    test('malformed lines and transport-owned names are refused', () {
      for (final raw in ['NoColon', ': value', 'Bad Name: value', 'X-Test: ', 'Host: evil', 'Cookie: a=b']) {
        expect(
          () => parseUrlHeaders(raw),
          throwsA(isA<UrlHostFormatException>().having((e) => e.problem, 'problem', UrlHostProblem.headers)),
          reason: raw,
        );
      }
    });
  });

  group('UrlHostConfig', () {
    final config = UrlHostConfig(
      id: 'url-0123456789abcdef',
      name: '家里的 Mac',
      baseUri: Uri.parse('https://dsh.example.com'),
    );

    test('json round-trip never carries a token', () {
      expect(UrlHostConfig.fromJson(jsonDecode(jsonEncode(config.toJson()))), config);
      expect(jsonEncode(config.toJson()), isNot(contains('token')));
      expect(UrlHostConfig.fromJson({'id': 'url-1', 'url': 'https://dsh.example.com/?token=abc'}), isNull);
      expect(UrlHostConfig.fromJson({'id': 'url-1', 'url': 'http://dsh.example.com'}), isNull);
      expect(UrlHostConfig.fromJson({'id': 'url-1'}), isNull);
      expect(UrlHostConfig.fromJson({'id': 'url-1', 'url': 'dsh.example.com'})!.name, 'dsh.example.com');
      expect(UrlHostConfig.newId(), matches(RegExp(r'^url-[0-9a-f]{16}$')));
    });

    test('a rename keeps the connection key; a new address does not', () {
      expect(config.copyWith(name: '新名字').connectionKey, config.connectionKey);
      expect(config.copyWith(name: '新名字').name, '新名字');
      final moved = UrlHostConfig.fromJson({...config.toJson(), 'url': 'https://other.example.com'})!;
      expect(moved.connectionKey, isNot(config.connectionKey));
    });

    test('secret keys are namespaced per host', () {
      expect(UrlHostSecrets.launchTokenKey('url-1'), 'url.url-1.launchToken');
      expect(UrlHostSecrets.accessTokenKey('url-1'), 'url.url-1.accessToken');
      expect(UrlHostSecrets.headersKey('url-1'), 'url.url-1.headers');
      expect(UrlHostSecrets.cookieKey('url-1'), 'url.url-1.cookie');
      expect(UrlHostSecrets.pocketPinKey('url-1'), 'url.url-1.pocketPin');
      expect(UrlHostSecrets.pocketCookieKey('url-1'), 'url.url-1.pocketCookie');
      expect(const UrlHostSecrets().isEmpty, isTrue);
    });
  });

  group('HostsController direct URL hosts', () {
    final config = UrlHostConfig(
      id: 'url-0123456789abcdef',
      name: '家里的 Mac',
      baseUri: Uri.parse('https://dsh.example.com'),
    );
    const secretsFor = UrlHostSecrets(
      launchToken: 'launch-token',
      accessToken: 'access-token',
      headers: 'CF-Access-Client-Id: id',
    );

    test('configs go to prefs, secrets to the secret store only', () async {
      final c = container();
      await loaded(c);
      expect(await c.read(hostsProvider.notifier).saveUrl(config, secrets: secretsFor), isTrue);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HostsController.urlPrefsKey)!;
      expect(raw, contains('https://dsh.example.com'));
      expect(raw, isNot(contains('launch-token')));
      expect(raw, isNot(contains('access-token')));
      expect(raw, isNot(contains('CF-Access-Client-Id')));
      expect(secrets.values[UrlHostSecrets.launchTokenKey(config.id)], 'launch-token');
      expect(secrets.values[UrlHostSecrets.accessTokenKey(config.id)], 'access-token');
      expect(secrets.values[UrlHostSecrets.headersKey(config.id)], 'CF-Access-Client-Id: id');

      // A fresh container (app restart) reads the same host and secrets back.
      final again = container();
      await loaded(again);
      expect(again.read(hostsProvider).url.single, config);
      expect(again.read(hostsProvider).urlById(config.id), config);
      final loadedSecrets = await again.read(hostsProvider.notifier).loadUrlSecrets(config.id);
      expect(loadedSecrets.launchToken, 'launch-token');
      expect(loadedSecrets.accessToken, 'access-token');
      expect(loadedSecrets.headers, 'CF-Access-Client-Id: id');
    });

    test('a second save replaces in place; SSH hosts are untouched', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      final ssh = SshHostConfig(id: 'ssh-1', name: '电脑', host: '10.0.0.2', user: 'me');
      await hosts.saveSsh(ssh);
      await hosts.saveUrl(config, secrets: secretsFor);
      await hosts.saveUrl(config.copyWith(name: '新名字'));

      expect(c.read(hostsProvider).url.single.name, '新名字');
      expect(c.read(hostsProvider).ssh.single, ssh);
      final raw = (await SharedPreferences.getInstance()).getString(HostsController.prefsKey)!;
      expect(raw, contains('10.0.0.2'));
    });

    test('clearing a secret removes it from secure storage', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveUrl(config, secrets: secretsFor);
      await hosts.saveUrl(config, secrets: const UrlHostSecrets(launchToken: 'only'));
      expect(secrets.values.containsKey(UrlHostSecrets.accessTokenKey(config.id)), isFalse);
      expect(secrets.values[UrlHostSecrets.launchTokenKey(config.id)], 'only');
    });

    test('the session cookie is kept and forgotten separately', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveUrl(config, secrets: secretsFor);
      await hosts.saveUrlCookie(config.id, '{"name":"dsh-auth-x","value":"v1.a.b","authority":"dsh.example.com"}');
      expect((await hosts.loadUrlSecrets(config.id)).cookie, contains('dsh-auth-x'));
      // Editing the host never clears the cookie.
      await hosts.saveUrl(config.copyWith(name: '改名'), secrets: secretsFor);
      expect((await hosts.loadUrlSecrets(config.id)).cookie, isNotNull);
      await hosts.saveUrlCookie(config.id, null);
      expect((await hosts.loadUrlSecrets(config.id)).cookie, isNull);
    });

    test('the pocket PIN and gate cookie are stored apart from the launch token', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveUrl(config, secrets: const UrlHostSecrets(pocketPin: '12345678'));
      expect(secrets.values[UrlHostSecrets.pocketPinKey(config.id)], '12345678');
      await hosts.saveUrlPocketCookie(config.id, 'dsh_pocket_token=abc');
      expect((await hosts.loadUrlSecrets(config.id)).pocketCookie, 'dsh_pocket_token=abc');

      // A rename, and a save that keeps the PIN, leave the live gate cookie.
      await hosts.saveUrl(
        config.copyWith(name: '改名'),
        secrets: const UrlHostSecrets(pocketPin: '12345678'),
      );
      expect((await hosts.loadUrlSecrets(config.id)).pocketCookie, 'dsh_pocket_token=abc');

      // A new PIN invalidates the old gate cookie; the link signs in again.
      await hosts.saveUrl(
        config.copyWith(name: '再改'),
        secrets: const UrlHostSecrets(pocketPin: '87654321'),
      );
      expect((await hosts.loadUrlSecrets(config.id)).pocketPin, '87654321');
      expect((await hosts.loadUrlSecrets(config.id)).pocketCookie, isNull);

      // Clearing the PIN clears both.
      await hosts.saveUrl(config, secrets: const UrlHostSecrets(launchToken: 'only'));
      expect(secrets.values.containsKey(UrlHostSecrets.pocketPinKey(config.id)), isFalse);
      expect((await hosts.loadUrlSecrets(config.id)).pocketPin, isNull);
      expect((await hosts.loadUrlSecrets(config.id)).pocketCookie, isNull);
    });

    test('removing the host deletes every secret and leaves it if active', () async {
      final c = container();
      await loaded(c);
      final hosts = c.read(hostsProvider.notifier);
      await hosts.saveUrl(config, secrets: const UrlHostSecrets(pocketPin: '12345678'));
      await hosts.saveUrlCookie(config.id, '{"name":"n","value":"v","authority":"dsh.example.com"}');
      await hosts.saveUrlPocketCookie(config.id, 'dsh_pocket_token=abc');
      c.read(activeHostProvider.notifier).select(HostRef.url(config.id));
      expect(c.read(activeHostProvider), HostRef.url(config.id));

      await hosts.removeUrl(config.id);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(hostsProvider).url, isEmpty);
      expect(secrets.values, isEmpty);
      expect(c.read(activeHostProvider), HostRef.local);
    });

    test('HostRef.url round-trips through the saved active host', () {
      final ref = HostRef.url('url-0123456789abcdef');
      expect(HostRef.decode(ref.encode()), ref);
      expect(ref.kind, HostKind.url);
      expect(hostLabel(HostKind.url, '家里的 Mac'), '家里的 Mac · URL');
      expect(hostLabel(HostKind.url, null), contains('URL'));
    });
  });
}
