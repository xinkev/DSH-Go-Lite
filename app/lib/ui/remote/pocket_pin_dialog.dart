// The dsh-pocket access PIN: asked once when a host needs signing in (a new
// scan, or a PIN that was rotated after the gate refused the saved one).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Shows the PIN field and resolves to the typed PIN, or null when cancelled.
Future<String?> askPocketPin(BuildContext context, {String? error}) =>
    showDialog<String>(context: context, builder: (_) => PocketPinDialog(error: error));

class PocketPinDialog extends StatefulWidget {
  const PocketPinDialog({super.key, this.error});

  /// Why the last attempt failed, shown under the field.
  final String? error;

  @override
  State<PocketPinDialog> createState() => _PocketPinDialogState();
}

class _PocketPinDialogState extends State<PocketPinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.remoteScanPinTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.remoteScanPinHint),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(labelText: l10n.remoteUrlPocketPin, errorText: widget.error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l10n.remoteScanPinConnect)),
      ],
    );
  }
}
