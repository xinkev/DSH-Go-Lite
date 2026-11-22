// The chat page's pet layer, retired: it draws nothing and passes its child through.
// Kept as a named wrapper so the chat layout does not change.

import 'package:flutter/widgets.dart';

class PetStage extends StatelessWidget {
  const PetStage({super.key, this.sessionId, this.aside, required this.child});

  final String? sessionId;
  final Object? aside;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
