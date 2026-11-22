// Text the media card and the media detail sheet derive from an engine's
// media meta. Kept here so both views read the same derivations.

import 'package:dsh_client/dsh_client.dart';

/// The card's aspect, as the grid asks for it: the request's if the host said
/// one, square otherwise.
double mediaAspectOf(MediaMeta meta) => double.tryParse(meta.request.aspect ?? '') ?? 1;

/// The failure line under a card: the host's own words, or nothing.
String mediaErrorShown(MediaMeta meta) => meta.error?.toString() ?? '';

/// A cost as the sheet shows it: the host's figure, or nothing.
String mediaCostText(MediaMeta meta) => meta.cost == null ? '' : '${meta.cost}';

/// A clip's length in the engine's seconds (fractions kept: 4.5).
String mediaDurationText(double seconds) => '${seconds.toStringAsFixed(1)}s';
