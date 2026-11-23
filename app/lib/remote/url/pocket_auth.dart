import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The access-PIN gate dsh-pocket puts in front of the DSH web routes.
///
/// It is a separate sign-in from the engine's own `?token=` exchange: the
/// proxy answers `POST {base}/pocket-login` (form field `token`) with
/// `Set-Cookie: dsh_pocket_token=…`, and every later request needs that
/// cookie. A proxy without the POST route takes the documented
/// `GET /?token=<PIN>` fallback instead. A wrong PIN answers the login page
/// again (200, or 401/429 when locked); the cookie dies when `dsh web`
/// restarts, because the proxy's session key changes.
class PocketAuth {
  PocketAuth._();

  /// The only cookie this flow reads or stores.
  static const cookieName = 'dsh_pocket_token';

  /// `POST /pocket-login` with `token=<pin>`. Returns the full `name=value`
  /// pair to send as `Cookie`.
  ///
  /// If the proxy does not answer the POST route (404/405/501), the documented
  /// fallback seeds the same cookie through `GET /?token=<pin>`.
  static Future<String> login(
    Uri baseUri,
    String pin, {
    Map<String, String> headers = const {},
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final value = pin.trim();
    if (value.isEmpty) throw const PocketLoginException(PocketLoginReason.rejected);
    final http = httpClient ?? (HttpClient()..connectionTimeout = timeout);
    final ownsClient = httpClient == null;
    try {
      final posted = await _post(http, baseUri, value, timeout, headers);
      if (posted != null) return '$cookieName=$posted';
      final seeded = await _seed(http, baseUri, value, timeout, headers);
      return '$cookieName=$seeded';
    } on PocketLoginException {
      rethrow;
    } on SocketException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } on TimeoutException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: '$error');
    } on HttpException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } on HandshakeException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  /// Whether the address sits behind a pocket PIN gate.
  ///
  /// An unauthenticated request for `/` answers the gate's login form (it
  /// posts to `/pocket-login`). A host whose LAN PIN is switched off answers
  /// the app itself, and a plain `dsh web` answers its own sign-in page, so
  /// neither asks the person for a pocket PIN.
  static Future<bool> needsPin(
    Uri baseUri, {
    Map<String, String> headers = const {},
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final http = httpClient ?? (HttpClient()..connectionTimeout = timeout);
    final ownsClient = httpClient == null;
    try {
      final request = await http.getUrl(_path(baseUri, ''));
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final text = await response.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(timeout);
      return text.contains('pocket-login');
    } on SocketException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } on TimeoutException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: '$error');
    } on HttpException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } on HandshakeException catch (error) {
      throw PocketLoginException(PocketLoginReason.unreachable, detail: error.message);
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  /// Null when the proxy does not know the POST route (fallback is allowed).
  static Future<String?> _post(
    HttpClient http,
    Uri baseUri,
    String pin,
    Duration timeout,
    Map<String, String> headers,
  ) async {
    final request = await http.postUrl(_path(baseUri, 'pocket-login'));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    final body = utf8.encode('token=${Uri.encodeQueryComponent(pin)}');
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(timeout);
    final cookie = _readCookie(response);
    final status = response.statusCode;
    await response.drain<void>().timeout(timeout);
    if (cookie != null) return cookie;
    if (status == 401) throw PocketLoginException(PocketLoginReason.rejected, statusCode: status);
    if (status == 429) throw PocketLoginException(PocketLoginReason.locked, statusCode: status);
    if (status == 404 || status == 405 || status == 501) return null;
    // 200 with the login page: the PIN was not accepted.
    throw PocketLoginException(PocketLoginReason.rejected, statusCode: status);
  }

  static Future<String> _seed(
    HttpClient http,
    Uri baseUri,
    String pin,
    Duration timeout,
    Map<String, String> headers,
  ) async {
    final request = await http.getUrl(_path(baseUri, '').replace(queryParameters: {'token': pin}));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final cookie = _readCookie(response);
    final status = response.statusCode;
    await response.drain<void>().timeout(timeout);
    if (cookie != null) return cookie;
    if (status == 401) throw PocketLoginException(PocketLoginReason.rejected, statusCode: status);
    if (status == 429) throw PocketLoginException(PocketLoginReason.locked, statusCode: status);
    throw PocketLoginException(PocketLoginReason.rejected, statusCode: status);
  }

  static Uri _path(Uri baseUri, String route) {
    final path = baseUri.path.isEmpty ? '/' : '${baseUri.path}/';
    return baseUri.replace(path: '$path$route');
  }

  static String? _readCookie(HttpClientResponse response) {
    for (final raw in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final at = raw.indexOf(';');
      final pair = (at < 0 ? raw : raw.substring(0, at)).trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      if (pair.substring(0, eq).trim() != cookieName) continue;
      final value = pair.substring(eq + 1).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}

enum PocketLoginReason { rejected, locked, unreachable, malformed }

/// One failed pocket sign-in. [detail] is transport text, never the PIN.
class PocketLoginException implements Exception {
  const PocketLoginException(this.reason, {this.statusCode, this.detail});

  final PocketLoginReason reason;
  final int? statusCode;
  final String? detail;

  bool get retryable => reason == PocketLoginReason.unreachable;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', status $statusCode';
    final extra = detail == null ? '' : ': $detail';
    return 'PocketLoginException(${reason.name}$status)$extra';
  }
}

/// The stored pocket cookie no longer opens the gate (wrong PIN, or `dsh web`
/// restarted and changed its session key). [UrlHostLink] clears the cookie and
/// signs in with the PIN once more; it never loops.
class PocketGateRefused implements Exception {
  const PocketGateRefused(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'PocketGateRefused($statusCode)';
}
