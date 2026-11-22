import 'dart:convert';
import 'dart:math' as math;

/// Why a typed direct URL or header block cannot be used.
enum UrlHostProblem { missing, invalid, insecure, query, headers }

/// A direct-URL value the person has to fix, with the field it came from.
class UrlHostFormatException implements Exception {
  const UrlHostFormatException(this.problem);

  final UrlHostProblem problem;

  @override
  String toString() => 'UrlHostFormatException(${problem.name})';
}

/// One accepted direct URL: the engine origin to dial, plus the launch token
/// the pasted URL carried (as `?token=…`), if any.
class ParsedUrlHost {
  const ParsedUrlHost(this.baseUri, {this.launchToken});

  final Uri baseUri;
  final String? launchToken;
}

final _urlPattern = RegExp(r'https?://\S+');
final _headerName = RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$");

/// `https://dsh.example.com` from what a person typed.
///
/// `dsh web: https://…/?token=…` is accepted whole: its token is returned
/// separately and never becomes part of the stored origin. A bare host gets
/// `https`, except loopback (this phone's engine speaks `http`). The path is
/// kept (a reverse proxy may mount DSH below the root) minus trailing `/`.
///
/// Plain `http` is refused off loopback: the launch token and session cookie
/// are bearer credentials.
ParsedUrlHost parseUrlHost(String raw) {
  final text = raw.trim();
  if (text.isEmpty) throw const UrlHostFormatException(UrlHostProblem.missing);
  final printed = _urlPattern.firstMatch(text)?.group(0);
  var candidate = printed ?? text;
  final schemeGiven = candidate.contains('://');
  if (!schemeGiven) {
    candidate = '${_isLoopbackName(_bareHost(candidate)) ? 'http' : 'https'}://$candidate';
  }
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) throw const UrlHostFormatException(UrlHostProblem.invalid);
  if (uri.scheme != 'http' && uri.scheme != 'https') throw const UrlHostFormatException(UrlHostProblem.invalid);
  if (uri.userInfo.isNotEmpty || uri.hasFragment) throw const UrlHostFormatException(UrlHostProblem.invalid);
  final tokens = uri.queryParametersAll['token'] ?? const <String>[];
  if (uri.hasQuery && (uri.queryParametersAll.length != 1 || tokens.length != 1)) {
    throw const UrlHostFormatException(UrlHostProblem.query);
  }
  final token = tokens.isEmpty ? null : tokens.single;
  if (token != null && token.isEmpty) throw const UrlHostFormatException(UrlHostProblem.query);
  if (uri.scheme == 'http' && !_isLoopbackName(uri.host)) {
    throw const UrlHostFormatException(UrlHostProblem.insecure);
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return ParsedUrlHost(
    Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path),
    launchToken: token,
  );
}

String _bareHost(String candidate) {
  final authority = candidate.split('/').first;
  final hostPort = authority.split('@').last;
  if (hostPort.startsWith('[')) return hostPort.substring(0, hostPort.indexOf(']') + 1);
  return hostPort.split(':').first;
}

bool _isLoopbackName(String host) {
  final name = host.toLowerCase();
  return name == 'localhost' || name == '127.0.0.1' || name == '::1' || name == '[::1]';
}

/// The request headers a direct URL host sends on every call: the pasted
/// `Name: value` lines, plus `Authorization: Bearer …` from [accessToken]
/// unless those lines already set one.
Map<String, String> urlRequestHeaders(String? accessToken, String? rawHeaders) {
  final headers = parseUrlHeaders(rawHeaders);
  final token = accessToken?.trim() ?? '';
  if (token.isNotEmpty && !headers.keys.any((name) => name.toLowerCase() == 'authorization')) {
    headers['Authorization'] = 'Bearer $token';
  }
  return headers;
}

/// `Name: value` lines (blank lines ignored) for Cloudflare Access service
/// tokens or another proxy's headers.
Map<String, String> parseUrlHeaders(String? raw) {
  final headers = <String, String>{};
  if (raw == null || raw.trim().isEmpty) return headers;
  for (final line in const LineSplitter().convert(raw)) {
    final text = line.trim();
    if (text.isEmpty) continue;
    final at = text.indexOf(':');
    if (at <= 0) throw const UrlHostFormatException(UrlHostProblem.headers);
    final name = text.substring(0, at).trim();
    final value = text.substring(at + 1).trim();
    if (!_headerName.hasMatch(name) || value.isEmpty || value.contains('\n')) {
      throw const UrlHostFormatException(UrlHostProblem.headers);
    }
    // The carrier owns these; an override would break the Host fence or the
    // session cookie instead of reaching the engine.
    if (const {'host', 'cookie', 'content-length'}.contains(name.toLowerCase())) {
      throw const UrlHostFormatException(UrlHostProblem.headers);
    }
    headers[name] = value;
  }
  return headers;
}

/// One saved direct URL host. Persisted as JSON in SharedPreferences; the
/// launch token, access token, extra headers and session cookie live in the
/// [SecretStore] under [UrlHostSecrets] keys.
class UrlHostConfig {
  const UrlHostConfig({required this.id, required this.name, required this.baseUri});

  /// Stable id (`url-<hex>`); also the secret-store namespace.
  final String id;

  /// What the person calls it ("家里的 Mac").
  final String name;

  /// Normalized origin, no trailing `/` and no token.
  final Uri baseUri;

  String get address => baseUri.toString();

  /// A new address needs a new connection; a rename does not.
  String get connectionKey => baseUri.toString();

  UrlHostConfig copyWith({String? name}) => UrlHostConfig(id: id, name: name ?? this.name, baseUri: baseUri);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': baseUri.toString()};

  static UrlHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final url = raw['url'];
    if (id is! String || id.isEmpty || url is! String) return null;
    final ParsedUrlHost parsed;
    try {
      parsed = parseUrlHost(url);
    } on UrlHostFormatException {
      return null;
    }
    // A stored origin never carries a token; refuse one that claims to.
    if (parsed.launchToken != null) return null;
    final name = raw['name'];
    return UrlHostConfig(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : parsed.baseUri.host,
      baseUri: parsed.baseUri,
    );
  }

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'url-$hex';
  }

  @override
  bool operator ==(Object other) =>
      other is UrlHostConfig && other.id == id && other.name == name && other.baseUri == baseUri;

  @override
  int get hashCode => Object.hash(id, name, baseUri);
}

/// The secret material for one direct URL host.
class UrlHostSecrets {
  const UrlHostSecrets({this.launchToken, this.accessToken, this.headers, this.cookie});

  /// The engine's process launch token (`?token=…`), exchanged for the session
  /// cookie. It changes every engine start; the cookie outlives it.
  final String? launchToken;

  /// Reverse-proxy credential, sent as `Authorization: Bearer …`.
  final String? accessToken;

  /// Extra `Name: value` request headers (Cloudflare Access service tokens).
  final String? headers;

  /// `DshCookie.toJson()` as JSON text, kept so a restart does not need the
  /// launch token. Engine restarts that keep the same DSH_HOME keep it valid.
  final String? cookie;

  Map<String, String> requestHeaders() => urlRequestHeaders(accessToken, headers);

  static String launchTokenKey(String hostId) => 'url.$hostId.launchToken';
  static String accessTokenKey(String hostId) => 'url.$hostId.accessToken';
  static String headersKey(String hostId) => 'url.$hostId.headers';
  static String cookieKey(String hostId) => 'url.$hostId.cookie';

  bool get isEmpty =>
      (launchToken?.trim().isEmpty ?? true) &&
      (accessToken?.trim().isEmpty ?? true) &&
      (headers?.trim().isEmpty ?? true) &&
      (cookie?.trim().isEmpty ?? true);
}
