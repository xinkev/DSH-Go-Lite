import 'package:flutter/material.dart';

/// What a widget that threw during build shows, in place of Flutter's blank
/// grey box.
///
/// Release builds painted an unlabelled grey rectangle for a failed subtree,
/// which reads as "the screen is empty and scrolls forever" and names no cause.
/// This keeps the failure on screen with the exception's first line, so a
/// screenshot is a bug report. The full error is still in the diagnostics log
/// (diagnostics/app_error_log.dart).
class BuildFailureView extends StatelessWidget {
  const BuildFailureView({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final reason = details.exceptionAsString();
    return ColoredBox(
      color: const Color(0xFF2A2A2A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: SelectableText(
              'This part of the page failed to build.\n\n$reason',
              style: const TextStyle(color: Color(0xFFEDEDED), fontSize: 12, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}
