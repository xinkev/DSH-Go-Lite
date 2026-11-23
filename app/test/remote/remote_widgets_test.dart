// Interaction: switching hosts from the sheet (with the first-use host-key
// check), saving an SSH host, and going back to 本机.
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_ssh.dart';

const _unpinned = SshHostConfig(id: 'ssh-lab', name: '实验室服务器', host: 'lab.example.com', user: 'root');

void main() {
  late MemorySecretStore secrets;
  late FakeSshServer server;
  HostLinkStatus linkStatus = HostLinkStatus.idle;

  setUp(() {
    linkStatus = HostLinkStatus.idle;
    secrets = MemorySecretStore();
    server = FakeSshServer();
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sampleSsh.toJson(), _unpinned.toJson()]),
    });
  });

  List<Override> overrides() => [
    secretStoreProvider.overrideWithValue(secrets),
    networkKicksProvider.overrideWithValue(const Stream.empty()),
    sshTransportFactoryProvider.overrideWithValue(server.connect),
    // Keep links idle: these tests are about the UI, not connecting.
    hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(linkStatus)),
    localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  ];

  Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  Future<void> frames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('host switcher exposes the active row as selected', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, const _Launcher());
    await openSheet(tester);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('host-row-local-local'))).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('picking a host with a pinned key switches right away', (tester) async {
    final c = await pump(tester, const _Launcher());
    await openSheet(tester);
    await tester.tap(find.text('电脑'));
    await frames(tester);
    expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
    expect(find.text('切换主机'), findsNothing, reason: 'sheet closed');
  });

  testWidgets('first use of an SSH host asks to trust its key, then pins it', (tester) async {
    final c = await pump(tester, const _Launcher());
    await openSheet(tester);
    await tester.tap(find.text('实验室服务器'));
    await frames(tester);
    expect(find.text('信任这台主机？'), findsOneWidget);
    expect(find.text(server.hostKey.fingerprint), findsOneWidget);
    await tester.tap(find.text('信任并连接'));
    await frames(tester);
    expect(c.read(hostsProvider).sshById('ssh-lab')!.hostKeyFingerprint, server.hostKey.fingerprint);
    expect(c.read(activeHostProvider), const HostRef.ssh('ssh-lab'));
  });

  testWidgets('declining the key keeps the current host', (tester) async {
    final c = await pump(tester, const _Launcher());
    await openSheet(tester);
    await tester.tap(find.text('实验室服务器'));
    await frames(tester);
    await tester.tap(find.text('取消'));
    await frames(tester);
    expect(c.read(activeHostProvider), HostRef.local);
    expect(c.read(hostsProvider).sshById('ssh-lab')!.hostKeyFingerprint, isNull);
  });

  group('where the password is kept', () {
    final zh = lookupL10n(AppLocale.zhCN);
    Future<void> form(WidgetTester tester, String os) async {
      usePhoneSurface(tester);
      tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
      await tester.pumpWidget(
        goldenApp(
          home: const SshHostFormPage(),
          brightness: Brightness.light,
          overrides: [...overrides(), operatingSystemProvider.overrideWithValue(os)],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('on HarmonyOS names no Android', (tester) async {
      await form(tester, 'ohos');
      expect(find.text(zh.harmonyPasswordStorageHelp), findsOneWidget);
      expect(find.textContaining('Android'), findsNothing);
    });

    testWidgets('on Android as ever', (tester) async {
      await form(tester, 'android');
      expect(find.text(zh.remotePasswordStorageHelp), findsOneWidget);
    });
  });

  testWidgets('saving a new SSH host keeps the password out of preferences', (tester) async {
    final c = await pump(tester, const SshHostFormPage());
    await tester.enterText(find.byType(TextField).at(0), '书房电脑');
    await tester.enterText(find.byType(TextField).at(1), '10.0.0.8');
    await tester.enterText(find.byType(TextField).at(2), 'me');
    await tester.enterText(find.byType(TextField).at(4), 's3cret');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await frames(tester);
    await tester.tap(find.text('保存'));
    await frames(tester);
    final saved = c.read(hostsProvider).ssh.firstWhere((h) => h.name == '书房电脑');
    expect(saved.host, '10.0.0.8');
    expect(saved.user, 'me');
    expect(saved.launchCommand, 'dsh web');
    expect(secrets.values[SshSecrets.passwordKey(saved.id)], 's3cret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(HostsController.prefsKey), isNot(contains('s3cret')));
  });

  testWidgets('moving a host to another address drops its pinned key', (tester) async {
    secrets.values[SshSecrets.passwordKey(sampleSsh.id)] = 'pw';
    final c = await pump(tester, const SshHostFormPage(existing: sampleSsh));
    await frames(tester, 3);
    await tester.enterText(find.byType(TextField).at(1), '10.0.0.99');
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await frames(tester);
    expect(find.text(sampleSsh.hostKeyFingerprint!), findsNothing);
    expect(find.textContaining('还没有确认'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await frames(tester);
    final saved = c.read(hostsProvider).sshById(sampleSsh.id)!;
    expect(saved.host, '10.0.0.99');
    expect(saved.hostKeyFingerprint, isNull);
    expect(secrets.values[SshSecrets.passwordKey(sampleSsh.id)], 'pw', reason: 'stored secret loaded and kept');
  });

  testWidgets('the form keys sit on a solid bar: nothing scrolls through', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(home: const SshHostFormPage(), brightness: Brightness.dark, overrides: overrides()),
    );
    await frames(tester);
    for (final label in ['测试连接', '保存']) {
      final key = tester.getRect(
        find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
      );
      final solid = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color.a == 1),
      );
      expect(
        solid
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .where((r) => r.contains(key.topLeft) && r.contains(key.bottomRight)),
        isNotEmpty,
        reason: label,
      );
    }
  });

  testWidgets('the form explains what is missing', (tester) async {
    await pump(tester, const SshHostFormPage());
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await frames(tester);
    await tester.tap(find.text('保存'));
    await frames(tester);
    expect(find.text('填写主机地址（IP 或域名）'), findsOneWidget, reason: 'shown under the field it is about');
  });

  testWidgets('切回本机 from the remote page', (tester) async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      ActiveHostController.prefsKey: HostRef.ssh(sampleSsh.id).encode(),
    });
    final c = await pump(tester, const RemoteScreen());
    await frames(tester, 3);
    expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
    await tester.tap(find.text('切回本机'));
    await tester.pump();
    expect(c.read(activeHostProvider), HostRef.local);
  });
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHostSheet(context, onManage: () {}),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}
