import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'url_host_config.dart';

/// Loads the saved secrets for one direct URL host.
typedef UrlHostSecretsLoader = Future<UrlHostSecrets> Function();

/// Persists the session cookie [DshConnection.login] minted (null clears it).
typedef UrlHostCookieSaver = Future<void> Function(String? cookieJson);

/// Opens a [DshClient] against one direct URL. Overridable so tests can drive
/// the link without a server.
typedef UrlClientConnector = Future<DshClient> Function({
  required Uri baseUri,
  required Map<String, String> headers,
  String? token,
  DshCookie? cookie,
  required Duration readyTimeout,
});

/// The local engine's carrier, pointed at a public origin: same
/// [DshHttpCarrier] (REST + /api/remote.mux) and the same health check, plus
/// optional headers for a reverse proxy in front of it.
Future<DshClient> connectUrlHost({
  required Uri baseUri,
  required Map<String, String> headers,
  String? token,
  DshCookie? cookie,
  required Duration readyTimeout,
}) async {
  final connection = DshConnection(baseUri, headers: headers, cookie: cookie);
  final client = DshClient(connection);
  try {
    final launch = token?.trim() ?? '';
    if (launch.isNotEmpty) await connection.login(launch);
    // Same readiness the local engine uses: the WebSocket route exists only
    // after application readiness, and its first frame is ready.
    await client.mux.ready(timeout: readyTimeout);
    return client;
  } catch (_) {
    await client.close().catchError((_) {});
    rethrow;
  }
}

/// [HostLink] over HTTP + WebSocket at a saved direct URL.
///
/// The mux owns reconnects inside one client. This link owns the client's
/// lifetime, a re-login when the cookie expires, and the visible status.
class UrlHostLink implements HostLink {
  UrlHostLink({
    required this._config,
    required this._loadSecrets,
    this._saveCookie,
    UrlClientConnector? connect,
    Stream<void>? kicks,
    Backoff? backoff,
    this._retryFirstOpen = true,
    this.readyTimeout = const Duration(seconds: 20),
  }) : _connect = connect ?? connectUrlHost,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  UrlHostConfig _config;
  final UrlHostSecretsLoader _loadSecrets;
  final UrlHostCookieSaver? _saveCookie;
  final UrlClientConnector _connect;
  final Backoff _backoff;
  final bool _retryFirstOpen;
  final Duration readyTimeout;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _reauthing = false;
  int _reconnects = 0;
  String? _launchToken;

  UrlHostConfig get config => _config;

  /// The engine launch token last used (for the WebView's own sign-in). Null
  /// when the saved session cookie was enough.
  String? get launchToken => _launchToken;

  /// A rename applies in place; a new address makes a new link.
  void updateConfig(UrlHostConfig next) => _config = _config.copyWith(name: next.name);

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = currentClient;
    if (client != null) return Future.value(client);
    return _opening ??= _run().whenComplete(() => _opening = null);
  }

  Future<DshClient> _run() async {
    _backoff.reset();
    var last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
    while (!_closed) {
      try {
        return await _connectOnce();
      } on HostLinkError catch (e) {
        last = e;
      } catch (e) {
        last = _mapError(e);
      }
      if (_closed || !last.retryable || !_retryFirstOpen || _backoff.exhausted) break;
      final delay = _backoff.next();
      _emit(
        HostLinkStatus(
          HostLinkPhase.reconnecting,
          attempt: _backoff.attempt,
          error: last,
          nextRetryAt: DateTime.now().add(delay),
        ),
      );
      await _delay.wait(delay);
    }
    _emit(HostLinkStatus(HostLinkPhase.failed, error: last));
    throw last;
  }

  Future<DshClient> _connectOnce() async {
    _emit(_status.withStep(HostLinkStep.connect));
    final secrets = await _loadSecrets();
    if (_closed) throw StateError('link closed');
    final DshCookie? cookie = _decodeCookie(secrets.cookie);
    final launch = secrets.launchToken?.trim() ?? '';
    _launchToken = launch.isEmpty ? null : launch;
    _emit(_status.withStep(HostLinkStep.login));
    final DshClient client;
    try {
      client = await _connect(
        baseUri: _config.baseUri,
        headers: secrets.requestHeaders(),
        token: secrets.launchToken,
        cookie: cookie,
        readyTimeout: readyTimeout,
      );
    } on Object catch (error) {
      throw _mapError(error);
    }
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    final existing = _client;
    _client = client;
    _watchMux(client);
    _reconnects = 0;
    _emit(
      HostLinkStatus(
        HostLinkPhase.connected,
        completed: HostLinkStep.values.toSet(),
        detail: _config.baseUri.toString(),
      ),
    );
    unawaited(_persistCookie(client));
    if (existing != null) unawaited(existing.close().catchError((_) {}));
    return client;
  }

  static DshCookie? _decodeCookie(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final cookie = DshCookie.fromJson(decoded.cast<String, Object?>());
      return cookie.name.isEmpty || cookie.value.isEmpty ? null : cookie;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistCookie(DshClient client) async {
    final saver = _saveCookie;
    if (saver == null) return;
    try {
      final carrier = client.carrier;
      if (carrier is! DshHttpCarrier) return;
      final cookie = carrier.connection.cookie;
      await saver(cookie == null ? null : jsonEncode(cookie.toJson()));
    } catch (_) {
      // A cookie that cannot be stored only costs one launch-token login later.
    }
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _muxSub = client.mux.states.listen((state) {
      if (_closed || !identical(client, _client)) return;
      switch (state) {
        case DshConnectionState.connected:
          _reconnects = 0;
          _emit(HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet()));
        case DshConnectionState.reconnecting:
          _reconnects++;
          _emit(
            HostLinkStatus(
              HostLinkPhase.reconnecting,
              attempt: _reconnects,
              error: HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteUrlErrUnreachable, retryable: true),
            ),
          );
        case DshConnectionState.unauthorized:
          unawaited(_reauth(client));
        case DshConnectionState.idle || DshConnectionState.connecting || DshConnectionState.closed:
          break;
      }
    });
  }

  /// The engine forgot this session (cookie expired, or it restarted with a
  /// new signing secret): exchange the saved launch token for a fresh cookie.
  Future<void> _reauth(DshClient client) async {
    if (_closed || _reauthing || !identical(client, _client)) return;
    _reauthing = true;
    try {
      final token = (await _loadSecrets()).launchToken?.trim() ?? '';
      final carrier = client.carrier;
      if (token.isEmpty || carrier is! DshHttpCarrier) {
        _fail(
          HostLinkError(
            HostLinkErrorKind.loginFailed,
            appL10n.remoteUrlErrTokenRejected,
            detail: appL10n.remoteUrlErrTokenRejectedDetail,
          ),
        );
        return;
      }
      final connection = carrier.connection;
      connection.cookie = null;
      await connection.login(token);
      await _persistCookie(client);
      client.mux.reconnect();
    } catch (error) {
      _fail(_mapError(error));
    } finally {
      _reauthing = false;
    }
  }

  HostLinkError _mapError(Object error) {
    if (error is DshHttpException) {
      final status = error.statusCode;
      if (status == 401) {
        return HostLinkError(
          HostLinkErrorKind.loginFailed,
          appL10n.remoteUrlErrTokenRejected,
          detail: appL10n.remoteUrlErrTokenRejectedDetail,
        );
      }
      if (status == 403) {
        return HostLinkError(
          HostLinkErrorKind.authFailed,
          appL10n.remoteUrlErrNotTrusted(_config.baseUri.authority),
          detail: error.message,
        );
      }
      if (status == 404) {
        return HostLinkError(HostLinkErrorKind.other, appL10n.remoteUrlErrNotFound, detail: error.message);
      }
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteUrlErrUnreachable,
        detail: error.message,
        retryable: true,
      );
    }
    if (error is TimeoutException) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteUrlErrUnreachable,
        detail: '$error',
        retryable: true,
      );
    }
    if (error is DshException) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteUrlErrUnreachable,
        detail: error.message,
        retryable: true,
      );
    }
    if (error is HostLinkError) return error;
    return HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, detail: '$error', retryable: true);
  }

  void _fail(HostLinkError error) {
    _emit(HostLinkStatus(HostLinkPhase.failed, error: error));
  }

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        unawaited(_probe());
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
        _client?.mux.reconnect();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  /// A network change / resume: the socket may be dead without having told us.
  Future<void> _probe() async {
    final client = _client;
    if (client == null) return;
    final carrier = client.carrier;
    if (carrier is! DshHttpCarrier) return;
    final health = await carrier.connection.checkHealth(timeout: const Duration(seconds: 5));
    if (_closed || !identical(client, _client)) return;
    switch (health) {
      case DshHealth.ok:
        break;
      case DshHealth.unauthorized:
        await _reauth(client);
      case DshHealth.unreachable:
        client.mux.reconnect();
    }
  }

  @override
  void retry() {
    if (_closed) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      _backoff.reset();
      _delay.skip();
      _client?.mux.reconnect();
      return;
    }
    if (_status.isBusy || _opening != null) return;
    final client = _client;
    if (client != null) {
      _backoff.reset();
      _reconnects = 1;
      _emit(HostLinkStatus(HostLinkPhase.reconnecting, attempt: 1));
      client.mux.reconnect();
      return;
    }
    unawaited(open().then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
