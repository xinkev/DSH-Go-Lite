import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'pocket_auth.dart';
import 'url_host_config.dart';

/// Loads the saved secrets for one direct URL host.
typedef UrlHostSecretsLoader = Future<UrlHostSecrets> Function();

/// Persists the session cookie [DshConnection.login] minted (null clears it).
typedef UrlHostCookieSaver = Future<void> Function(String? cookieJson);

/// Persists the dsh-pocket gate cookie (null clears it).
typedef UrlHostPocketCookieSaver = Future<void> Function(String? cookie);

/// Signs in to the dsh-pocket gate once; overridable so tests need no server.
/// [headers] are the host's saved proxy headers (Cloudflare Access, bearer).
typedef UrlPocketLogin = Future<String> Function(Uri baseUri, String pin, Map<String, String> headers);

/// Opens a [DshClient] against one direct URL. Overridable so tests can drive
/// the link without a server.
typedef UrlClientConnector = Future<DshClient> Function({
  required Uri baseUri,
  required Map<String, String> headers,
  String? token,
  DshCookie? cookie,
  String? pocketCookie,
  required Duration readyTimeout,
});

/// The local engine's carrier, pointed at a public origin: same
/// [DshHttpCarrier] (REST + /api/remote.mux) and the same health check, plus
/// optional headers for a reverse proxy in front of it.
///
/// [pocketCookie] is dsh-pocket's gate cookie; it rides the same `Cookie`
/// header as the engine session cookie.
Future<DshClient> connectUrlHost({
  required Uri baseUri,
  required Map<String, String> headers,
  String? token,
  DshCookie? cookie,
  String? pocketCookie,
  required Duration readyTimeout,
}) async {
  final connection = DshConnection(baseUri, headers: headers, cookie: cookie, pocketCookie: pocketCookie);
  final client = DshClient(connection);
  try {
    final launch = token?.trim() ?? '';
    if (launch.isNotEmpty) {
      try {
        await connection.login(launch);
      } on DshHttpException catch (error) {
        // Behind a stale pocket cookie the engine's own ?token= request is
        // answered by the gate, not by the engine.
        if (pocketCookie != null && _pocketRefusal(error)) {
          throw PocketGateRefused(error.statusCode);
        }
        rethrow;
      }
    }
    // A stale gate answers a plain GET with its login page (200 HTML). A
    // 401/403 here is ambiguous (gate or engine), so the mux refusal below
    // owns that recovery instead.
    // A dsh-pocket host with its LAN PIN switched off hands out no cookie:
    // the proxy still only adds the launch token to `GET /`, so the exchange
    // has to happen even without a gate cookie.
    if (pocketCookie != null || launch.isEmpty) {
      // No saved engine session (or a refused one): force the handshake the
      // browser does after signing in, rather than letting a cookie the gate
      // considers present skip the launch-token exchange.
      final path = cookie == null ? '/?dsh-pocket-auth=1' : '/';
      final response = await connection.get(path, followRedirects: false);
      if (_isPocketLoginPage(response.statusCode, response.text)) {
        throw const PocketGateRefused(200);
      }
      // The gate adds the engine's launch token to this GET on the way out, and
      // the response mints the `dsh-auth-*` cookie every /api call and the
      // WebSocket need. A client that only speaks /api never gets one itself.
      connection.adoptSessionCookie(response);
    }
    // Same readiness the local engine uses: the WebSocket route exists only
    // after application readiness, and its first frame is ready.
    await client.mux.ready(timeout: readyTimeout);
    return client;
  } catch (_) {
    await client.close().catchError((_) {});
    rethrow;
  }
}

bool _pocketRefusal(DshHttpException error) =>
    error.statusCode == 401 || error.statusCode == 403 || _isPocketLoginPage(error.statusCode, error.body);

bool _isPocketLoginPage(int status, String body) => status == 200 && body.toLowerCase().contains('pocket-login');

/// [HostLink] over HTTP + WebSocket at a saved direct URL.
///
/// The mux owns reconnects inside one client. This link owns the client's
/// lifetime, a re-login when the cookie expires, and the visible status.
class UrlHostLink implements HostLink {
  UrlHostLink({
    required this._config,
    required this._loadSecrets,
    this._saveCookie,
    UrlHostPocketCookieSaver? savePocketCookie,
    UrlPocketLogin? pocketLogin,
    UrlClientConnector? connect,
    Stream<void>? kicks,
    Backoff? backoff,
    this._retryFirstOpen = true,
    this.readyTimeout = const Duration(seconds: 20),
  }) : _savePocketCookie = savePocketCookie,
       _pocketLogin = pocketLogin ?? ((baseUri, pin, headers) => PocketAuth.login(baseUri, pin, headers: headers)),
       _connect = connect ?? connectUrlHost,
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  UrlHostConfig _config;
  final UrlHostSecretsLoader _loadSecrets;
  final UrlHostCookieSaver? _saveCookie;
  final UrlHostPocketCookieSaver? _savePocketCookie;
  final UrlPocketLogin _pocketLogin;
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
    final pin = secrets.pocketPin?.trim() ?? '';
    final cookie = _decodeCookie(secrets.cookie);
    final launch = secrets.launchToken?.trim() ?? '';
    _launchToken = launch.isEmpty ? null : launch;
    var pocket = _cleanPocketCookie(secrets.pocketCookie);
    if (pin.isNotEmpty && pocket == null) {
      pocket = await _signInPocket(pin, secrets.requestHeaders());
      await _persistPocketCookie(pocket);
    }
    try {
      return await _openOnce(secrets, pocket, cookie);
    } on PocketGateRefused {
      return _recoverPocket(pin, secrets, cookie);
    } on DshHttpException catch (error) {
      // A 401/403 while a gate cookie is in play may be the gate rather than
      // the engine; recover once, then report whichever refusal remains.
      if (!_isAuthRefusal(error.statusCode) || pocket == null) rethrow;
      return _recoverPocket(pin, secrets, cookie);
    } on Object catch (error) {
      throw _mapError(error);
    }
  }

  /// The gate cookie died (`dsh web` restarted, PIN changed): forget it, sign
  /// in once more with the saved PIN, and reopen once. Never loops.
  Future<DshClient> _recoverPocket(String pin, UrlHostSecrets secrets, DshCookie? cookie) async {
    await _persistPocketCookie(null);
    if (pin.isEmpty) throw _pocketError();
    final pocket = await _signInPocket(pin, secrets.requestHeaders());
    await _persistPocketCookie(pocket);
    try {
      // The old engine session is what was refused: hand it back after the
      // forced handshake mints a new one.
      return await _openOnce(secrets, pocket, null);
    } on PocketGateRefused {
      throw _pocketError();
    } on DshHttpException catch (error) {
      // The fresh PIN opened the gate, so a remaining refusal is the engine's.
      if (_isAuthRefusal(error.statusCode)) throw _mapError(error);
      rethrow;
    } on Object catch (error) {
      throw _mapError(error);
    }
  }

  Future<DshClient> _openOnce(UrlHostSecrets secrets, String? pocket, DshCookie? cookie) async {
    _emit(_status.withStep(HostLinkStep.login));
    final client = await _connect(
      baseUri: _config.baseUri,
      headers: secrets.requestHeaders(),
      token: secrets.launchToken,
      cookie: cookie,
      pocketCookie: pocket,
      readyTimeout: readyTimeout,
    );
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

  Future<String> _signInPocket(String pin, Map<String, String> headers) async {
    _emit(_status.withStep(HostLinkStep.login));
    try {
      final cookie = (await _pocketLogin(_config.baseUri, pin, headers)).trim();
      if (cookie.isEmpty) throw const PocketLoginException(PocketLoginReason.malformed);
      return cookie;
    } on PocketLoginException catch (error) {
      throw _mapPocketError(error);
    } on Object catch (error) {
      throw _mapError(error);
    }
  }

  Future<void> _persistPocketCookie(String? cookie) async {
    final saver = _savePocketCookie;
    if (saver == null) return;
    try {
      await saver(cookie);
    } catch (_) {
      // A gate cookie that cannot be stored only costs one PIN sign-in later.
    }
  }

  static String? _cleanPocketCookie(String? raw) {
    final text = raw?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static bool _isAuthRefusal(int status) => status == 401 || status == 403;

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

  /// The engine (or the pocket gate) forgot this session: sign in to the gate
  /// again if one is configured, then exchange the saved launch token for a
  /// fresh engine cookie.
  Future<void> _reauth(DshClient client) async {
    if (_closed || _reauthing || !identical(client, _client)) return;
    _reauthing = true;
    try {
      final secrets = await _loadSecrets();
      final token = secrets.launchToken?.trim() ?? '';
      final pin = secrets.pocketPin?.trim() ?? '';
      final carrier = client.carrier;
      if (carrier is! DshHttpCarrier) {
        _fail(_tokenRejectedError());
        return;
      }
      final connection = carrier.connection;
      if (connection.pocketCookie != null) {
        if (pin.isEmpty) {
          // The gate cookie is dead and no PIN can renew it.
          connection.pocketCookie = null;
          await _persistPocketCookie(null);
          _fail(_pocketError());
          return;
        }
        connection.pocketCookie = null;
        await _persistPocketCookie(null);
        try {
          final pocket = await _signInPocket(pin, secrets.requestHeaders());
          connection.pocketCookie = pocket;
          await _persistPocketCookie(pocket);
        } on HostLinkError catch (error) {
          _fail(error);
          return;
        }
      }
      if (token.isEmpty) {
        // No engine token saved: only a health check can say whether the fresh
        // gate cookie was enough. Never reconnect blind: an expired engine
        // cookie without a token would loop through this method.
        if (pin.isNotEmpty) {
          connection.adoptSessionCookie(await connection.get('/', followRedirects: false));
        }
        final health = await connection.checkHealth();
        if (health == DshHealth.ok) {
          client.mux.reconnect();
          return;
        }
        _fail(
          health == DshHealth.unauthorized
              ? _tokenRejectedError()
              : HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteUrlErrUnreachable, retryable: true),
        );
        return;
      }
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

  HostLinkError _tokenRejectedError() => HostLinkError(
    HostLinkErrorKind.loginFailed,
    appL10n.remoteUrlErrTokenRejected,
    detail: appL10n.remoteUrlErrTokenRejectedDetail,
  );

  HostLinkError _pocketError() => HostLinkError(
    HostLinkErrorKind.loginFailed,
    appL10n.remoteUrlErrPocketPin,
    detail: appL10n.remoteUrlErrPocketPinDetail,
  );

  HostLinkError _mapPocketError(PocketLoginException error) {
    if (error.retryable) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteUrlErrUnreachable,
        detail: error.toString(),
        retryable: true,
      );
    }
    return _pocketError();
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
