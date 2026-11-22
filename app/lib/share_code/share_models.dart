// What a share code carries (分享码, docs/design/share-codes.md): a profile
// bundle exported from an engine. Readers are strict about what may be applied
// from a link — settings namespaces, presets, skills, AGENTS.md — and lenient
// about display text.

import 'package:flutter/foundation.dart';

import 'settings_sanitizer.dart' show isShareableNamespace;

/// Body format version of plugins and profiles. A reader refuses bodies
/// newer than it knows.
const shareFormatVersion = 1;

/// Body kinds.
enum ShareKind {
  profile,

  /// A conversation to read and replay (`conversation_share.dart`): not a
  /// [SharePayload], nothing is installed from it.
  conversation;

  static ShareKind? parse(Object? value) => switch (value) {
    'profile' => profile,
    'conversation' => conversation,
    _ => null,
  };
}

/// Something in a share body is malformed or not allowed.
class ShareFormatException implements Exception {
  const ShareFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'ShareFormatException: $reason';
}

/// An agent preset a profile's plugins add.
@immutable
class SharedPreset {
  const SharedPreset({required this.id, this.name});

  factory SharedPreset.fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('preset is not an object');
    final id = _str(json['id']);
    if (id == null || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id)) throw const ShareFormatException('bad preset');
    return SharedPreset(id: id, name: _text(json['name'], 60));
  }

  final String id;
  final String? name;

  String get displayName => name ?? id;

  Map<String, Object?> toJson() => {'id': id, 'name': ?name};
}

/// A user skill: its folder's text files (`SKILL.md` first).
@immutable
class SharedSkill {
  const SharedSkill({required this.name, required this.files});

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  static final _path = RegExp(r'^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+){0,3}$');

  factory SharedSkill.fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('skill is not an object');
    final name = _str(json['name']);
    if (name == null || !_name.hasMatch(name)) throw const ShareFormatException('bad skill name');
    final files = json['files'];
    if (files is! Map || files.isEmpty || files.length > maxFiles) throw const ShareFormatException('bad skill files');
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in files.entries) {
      if (key is! String || !isSafePath(key) || value is! String) throw const ShareFormatException('bad skill file');
      if (value.length > maxFileChars) throw const ShareFormatException('skill file too large');
      out[key] = value;
    }
    if (!out.containsKey('SKILL.md')) throw const ShareFormatException('skill without SKILL.md');
    return SharedSkill(name: name, files: out);
  }

  static const maxFiles = 12;
  static const maxFileChars = 64 * 1024;

  /// A relative path inside the skill folder: no `..`, no hidden segments.
  static bool isSafePath(String path) =>
      _path.hasMatch(path) && !path.split('/').any((s) => s == '..' || s == '.' || s.startsWith('.'));

  final String name;

  /// Relative path → text.
  final Map<String, String> files;

  Map<String, Object?> toJson() => {'name': name, 'files': files};
}

/// A shared body.
@immutable
sealed class SharePayload {
  const SharePayload();

  ShareKind get kind;

  Map<String, Object?> toJson();

  /// Validates a decoded body.
  static SharePayload fromJson(Object? json) {
    if (json is! Map) throw const ShareFormatException('body is not an object');
    final v = json['v'];
    if (v is! int || v < 1) throw const ShareFormatException('no format version');
    if (v > shareFormatVersion) throw const ShareFormatException('newer format');
    return switch (ShareKind.parse(json['kind'])) {
      ShareKind.profile => ProfileShare.fromJson(json),
      // Read with ConversationShare.fromJson (the share-code host routes it).
      ShareKind.conversation => throw const ShareFormatException('conversation'),
      null => throw const ShareFormatException('unknown kind'),
    };
  }
}

final class ProfileShare extends SharePayload {
  const ProfileShare({
    this.name,
    this.created,
    this.settings = const {},
    this.presets = const [],
    this.skills = const [],
    this.agentsMd,
  });

  static final _ns = RegExp(r'^[A-Za-z0-9._:@/-]{1,80}$');
  static const maxAgentsMdChars = 64 * 1024;

  factory ProfileShare.fromJson(Map<Object?, Object?> json) {
    final settings = <String, Map<String, Object?>>{};
    final rawSettings = json['settings'];
    if (rawSettings != null) {
      if (rawSettings is! Map) throw const ShareFormatException('settings is not an object');
      for (final MapEntry(:key, :value) in rawSettings.entries) {
        if (key is! String || !_ns.hasMatch(key) || value is! Map) throw const ShareFormatException('bad settings');
        if (!isShareableNamespace(key)) continue;
        settings[key] = {
          for (final MapEntry(key: k, value: v) in value.entries)
            if (k is String) k: v,
        };
      }
    }
    List<T> list<T>(Object? raw, T Function(Object?) read, int max) {
      if (raw == null) return const [];
      if (raw is! List || raw.length > max) throw const ShareFormatException('bad list');
      return [for (final item in raw) read(item)];
    }

    final agentsMd = json['agentsMd'];
    if (agentsMd != null && (agentsMd is! String || agentsMd.length > maxAgentsMdChars)) {
      throw const ShareFormatException('bad AGENTS.md');
    }
    final created = _str(json['created']);
    return ProfileShare(
      name: _text(json['name'], 40),
      created: created == null ? null : DateTime.tryParse(created),
      settings: settings,
      presets: list(json['presets'], SharedPreset.fromJson, 64),
      skills: list(json['skills'], SharedSkill.fromJson, 32),
      agentsMd: agentsMd is String && agentsMd.trim().isNotEmpty ? agentsMd : null,
    );
  }

  final String? name;
  final DateTime? created;

  /// Namespace → the profile's own (user-layer) values.
  final Map<String, Map<String, Object?>> settings;
  final List<SharedPreset> presets;
  final List<SharedSkill> skills;
  final String? agentsMd;

  bool get isEmpty => settings.isEmpty && presets.isEmpty && skills.isEmpty && agentsMd == null;

  @override
  ShareKind get kind => ShareKind.profile;

  @override
  Map<String, Object?> toJson() => {
    'v': shareFormatVersion,
    'kind': 'profile',
    'name': ?name,
    if (created != null) 'created': created!.toUtc().toIso8601String(),
    if (settings.isNotEmpty) 'settings': settings,
    if (presets.isNotEmpty) 'presets': [for (final p in presets) p.toJson()],
    if (skills.isNotEmpty) 'skills': [for (final s in skills) s.toJson()],
    'agentsMd': ?agentsMd,
  };
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// Display text: trimmed, one line, at most [max] characters.
String? _text(Object? v, int max) {
  if (v is! String) return null;
  final t = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}
