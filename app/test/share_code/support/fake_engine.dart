// A small fake DSH Host for share-code tests: settings and presets answered
// from in-memory state, every call recorded.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_client/dsh_client.dart';

class FakeEngine extends DshCarrier {
  FakeEngine();

  final calls = <(String, Map<String, Object?>)>[];

  /// ns → {value, user, base, revision}.
  final settings = <String, Map<String, Object?>>{};
  final presets = <Map<String, Object?>>[];

  bool describeFails = false;

  List<Map<String, Object?>> argsOf(String endpoint) => [
    for (final (e, a) in calls)
      if (e == endpoint) a,
  ];

  void addSettings(String ns, {Map<String, Object?> base = const {}, Map<String, Object?> user = const {}}) {
    settings[ns] = {
      'base': {...base},
      'user': {...user},
      'revision': 1,
    };
  }

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  Map<String, Object?> _view(String ns) {
    final s = settings[ns]!;
    final base = s['base'] as Map<String, Object?>;
    final user = s['user'] as Map<String, Object?>;
    return {
      'ns': ns,
      'schema': s['schema'],
      'secrets': s['secrets'],
      'value': {...base, ...user},
      'base': base,
      'user': user,
      'revision': s['revision'],
    };
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    switch (endpoint) {
      case 'settings/describe':
        if (describeFails) return RpcError(DshRemoteException('INTERNAL', 'describe failed'));
        return RpcOk({
          'writable': true,
          'namespaces': [for (final ns in settings.keys) _view(ns)],
        });
      case 'settings/mutate':
        final ns = args['ns'] as String;
        final s = settings[ns];
        if (s == null) return RpcError(DshRemoteException('settings/rejected', 'No configurable plugin entry "$ns"'));
        if (args['expectedRevision'] != null && args['expectedRevision'] != s['revision']) {
          return RpcError(DshRemoteException('settings/conflict', 'stale'));
        }
        final user = Map<String, Object?>.of(s['user'] as Map<String, Object?>);
        for (final op in args['ops'] as List) {
          final m = op as Map;
          final path = (m['path'] as List).cast<String>();
          if (m['op'] == 'set') user[path.first] = m['value'];
        }
        s['user'] = user;
        s['revision'] = (s['revision'] as int) + 1;
        return RpcOk(_view(ns));
      case 'agentPresets/list':
        return RpcOk({'presets': presets});
      default:
        return RpcError(DshRemoteException('gateway/method-not-found', endpoint));
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => Completer<DshMuxLink>().future;

  @override
  Future<void> close() async {}
}

class FakeShareNet implements ShareNet {
  final npm = <String, NpmFacts>{};
  final gists = <String, String>{};
  final created = <(String token, String name, String content)>[];

  @override
  Future<NpmFacts?> npmFacts(String name, String version) async => npm['$name@$version'];

  @override
  Future<String> createGist({required String token, required String fileName, required String content}) async {
    if (token != 'good') throw const GistException('GitHub 令牌无效或没有 Gist 权限', unauthorized: true);
    created.add((token, fileName, content));
    const id = 'aa5a315d61ae9438b18d';
    gists[id] = content;
    return id;
  }

  @override
  Future<String> fetchGist(String id) async => gists[id] ?? (throw const GistException('找不到这个 Gist'));
}

/// A throwaway rootfs with DSH home in it.
GuestFs tempGuest() {
  final runtime = Directory.systemTemp.createTempSync('share-guest-');
  final root = Directory('${runtime.path}/rootfs')..createSync();
  Directory('${root.path}/root/.dsh').createSync(recursive: true);
  return GuestFs(root);
}

void writeGuest(GuestFs fs, String path, String text) {
  final f = fs.file(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}
