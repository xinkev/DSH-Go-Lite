import 'dart:convert';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

const autoConnectKey = 'remote_auto_connect_on_startup';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

void main() {
  late FakeSshServer server;
  late FakeConnector connector;

  void seed(HostRef host, {bool? autoConnect}) {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      ActiveHostController.prefsKey: host.encode(),
      autoConnectKey: ?autoConnect,
    });
  }

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(MemorySecretStore()),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () async => const SshSecrets(password: 'pw'),
            transportFactory: server.connect,
            connectClient: connector.call,
            backoff: Backoff(initial: const Duration(milliseconds: 1), maxAttempts: 2),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(activeConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    return c;
  }

  Future<void> loaded(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).ready;
    await c.pump();
  }

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
    seed(HostRef.local);
  });

  for (final host in [HostRef.ssh(sampleSsh.id)]) {
    test('disabled startup restore stays local for ${host.kind.name}', () async {
      seed(host, autoConnect: false);
      final c = container();
      await loaded(c);
      expect(c.read(activeHostProvider), HostRef.local);
      expect(server.connects, isEmpty);
      expect(c.read(hostsProvider).ssh, [sampleSsh]);
      expect(HostRef.decode((await SharedPreferences.getInstance()).getString(ActiveHostController.prefsKey)), host);
    });
  }

  for (final enabled in [null, true]) {
    test('startup restore preserves existing behavior when preference is $enabled', () async {
      seed(HostRef.ssh(sampleSsh.id), autoConnect: enabled);
      final c = container();
      await until(c, activeConnectionProvider, (s) => s.value?.kind == HostKind.ssh, what: 'restored SSH connection');
      expect(server.connects, hasLength(1));
    });
  }

  test('disabled startup auto-connect still permits manual SSH, reconnect, and local', () async {
    seed(HostRef.local, autoConnect: false);
    final c = container();
    await loaded(c);
    c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
    await until(c, activeConnectionProvider, (s) => s.value?.kind == HostKind.ssh, what: 'manual SSH connection');
    final link = c.read(hostLinkProvider(HostRef.ssh(sampleSsh.id)))!;
    final reconnected = nextStatus(link, (s) => s.isConnected, what: 'manual connection recovers');
    server.last.drop();
    await reconnected;
    expect(server.connects, hasLength(2));

    c.read(activeHostProvider.notifier).select(HostRef.local);
    await loaded(c);
    expect(c.read(activeHostProvider), HostRef.local);
    expect(c.read(activeConnectionProvider).value, isNull);
  });

  test('manual selection before preferences restore wins over the remembered host', () async {
    seed(const HostRef.url('remembered'), autoConnect: false);
    final c = container();
    c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
    await until(c, activeConnectionProvider, (s) => s.value?.kind == HostKind.ssh, what: 'early manual connection');
    expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
  });

  test('a host deleted while the preference is off is not restored after turning it back on', () async {
    seed(HostRef.ssh(sampleSsh.id), autoConnect: false);
    final c = container();
    await loaded(c);
    await c.read(hostsProvider.notifier).removeSsh(sampleSsh.id);
    await c.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), HostRef.local);
    // Turned back on: the next launch has nothing stale to return to.
    await c.read(remoteAutoConnectProvider.notifier).set(true);
    final next = container();
    await loaded(next);
    expect(next.read(activeHostProvider), HostRef.local);
    expect(server.connects, isEmpty);
  });

  test('another saved host survives deleting an unrelated SSH host', () async {
    seed(const HostRef.url('kept'), autoConnect: false);
    final c = container();
    await loaded(c);
    await c.read(hostsProvider.notifier).removeSsh(sampleSsh.id);
    await c.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), const HostRef.url('kept'));
  });

  test('the preference is read at startup, before the remote hosts page asks', () async {
    seed(HostRef.local, autoConnect: false);
    final c = container();
    await loaded(c);
    expect(c.exists(remoteAutoConnectProvider), isTrue);
    expect(c.read(remoteAutoConnectProvider), isFalse);
  });
}
