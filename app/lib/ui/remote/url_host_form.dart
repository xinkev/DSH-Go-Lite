import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/url/url_link.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/discard_guard.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/credential_recovery_dialog.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_form_frame.dart';
import 'link_progress.dart';

/// Add or edit a direct URL host: an HTTPS address that serves `dsh web`,
/// reached without an account or the relay. "测试连接" runs the real connect
/// flow (login with the engine token, then the mux ready handshake).
class UrlHostFormPage extends ConsumerStatefulWidget {
  const UrlHostFormPage({super.key, this.existing, this.initialStatus});

  /// Null to add a new host.
  final UrlHostConfig? existing;

  /// Pre-filled test progress (goldens).
  @visibleForTesting
  final HostLinkStatus? initialStatus;

  @override
  ConsumerState<UrlHostFormPage> createState() => _UrlHostFormPageState();
}

class _UrlHostFormPageState extends ConsumerState<UrlHostFormPage> {
  late final String _id = widget.existing?.id ?? UrlHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  final _token = TextEditingController();
  final _access = TextEditingController();
  final _headers = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _formError;
  Map<_F, String> _errors = const {};
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  UrlHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  late HostLinkStatus? _testStatus = widget.initialStatus;

  bool get _editing => widget.existing != null;

  /// The form as opened (with the saved secrets once they are read).
  late String _clean;
  late final Listenable _edits = Listenable.merge([_name, _address, _token, _access, _headers]);

  String _signature() => jsonEncode({
    'name': _name.text,
    'address': _address.text,
    'token': _token.text,
    'access': _access.text,
    'headers': _headers.text,
  });

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) unawaited(_loadSecrets());
  }

  Future<void> _loadSecrets() async {
    final clean = jsonDecode(_clean) as Map<String, dynamic>;
    final controllers = [_token, _access, _headers];
    final initial = {for (final controller in controllers) controller: controller.text};
    final edited = <TextEditingController>{};
    void trackEdits() {
      for (final controller in controllers) {
        if (controller.text != initial[controller]) edited.add(controller);
      }
    }

    for (final controller in controllers) {
      controller.addListener(trackEdits);
    }
    final UrlHostSecrets secrets;
    try {
      secrets = await ref.read(hostsProvider.notifier).loadUrlSecrets(_id);
    } finally {
      for (final controller in controllers) {
        controller.removeListener(trackEdits);
      }
    }
    if (!mounted) return;
    setState(() {
      // Text edits (including paste and an explicit clear) win over a late
      // storage read.
      if (!edited.contains(_token)) _token.text = secrets.launchToken ?? '';
      if (!edited.contains(_access)) _access.text = secrets.accessToken ?? '';
      if (!edited.contains(_headers)) _headers.text = secrets.headers ?? '';
      _clean = jsonEncode({
        ...clean,
        'token': secrets.launchToken ?? '',
        'access': secrets.accessToken ?? '',
        'headers': secrets.headers ?? '',
      });
    });
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _address, _token, _access, _headers]) {
      c.dispose();
    }
    super.dispose();
  }

  String _errorText(UrlHostProblem problem) => switch (problem) {
    UrlHostProblem.missing => context.l10n.remoteUrlErrRequired,
    UrlHostProblem.invalid => context.l10n.remoteUrlErrInvalid,
    UrlHostProblem.insecure => context.l10n.remoteUrlErrInsecure,
    UrlHostProblem.query => context.l10n.remoteUrlErrQuery,
    UrlHostProblem.headers => context.l10n.remoteUrlErrHeaders,
  };

  /// The config and secrets as typed; null (with [_errors] set) when wrong.
  (UrlHostConfig, UrlHostSecrets)? _draft() {
    final errors = <_F, String>{};
    ParsedUrlHost? parsed;
    try {
      parsed = parseUrlHost(_address.text);
    } on UrlHostFormatException catch (e) {
      errors[_F.address] = _errorText(e.problem);
    }
    if (parsed != null) {
      try {
        parseUrlHeaders(_headers.text);
      } on UrlHostFormatException catch (e) {
        errors[_F.headers] = _errorText(e.problem);
      }
    }
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (parsed == null || errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey, orElse: () => _F.address);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    // The whole `dsh web: https://…/?token=…` line pasted into the address
    // counts as the engine token too, unless that field was filled already.
    final typed = _token.text.trim();
    final token = typed.isNotEmpty ? typed : parsed.launchToken;
    final config = UrlHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? parsed.baseUri.host : _name.text.trim(),
      baseUri: parsed.baseUri,
    );
    return (config, UrlHostSecrets(launchToken: token, accessToken: _access.text, headers: _headers.text));
  }

  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  Future<void> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _draft();
    if (draft == null) return;
    await _testSub?.cancel();
    await _test?.close();
    final (config, secrets) = draft;
    final link = UrlHostLink(config: config, loadSecrets: () async => secrets, retryFirstOpen: false);
    _test = link;
    setState(() => _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    try {
      await link.open();
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) {
        _test = null;
        if (mounted) setState(() {});
      }
      await link.close();
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _draft();
    if (draft == null) return;
    setState(() => _saving = true);
    try {
      final (config, secrets) = draft;
      final saved = await ref.read(hostsProvider.notifier).saveUrl(config, secrets: secrets);
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      // New credentials must take effect on a live connection too: the link
      // only recreates itself when the address changes, not when the token
      // (never in the config) does.
      ref.invalidate(hostLinkProvider(HostRef.url(_id)));
      Navigator.of(context).pop(config);
    } catch (e) {
      if (mounted) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        await offerCredentialRecovery(context, ref, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDeleteHostTitle(name)),
        content: Text(context.l10n.remoteUrlDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeUrl(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final testing = _test != null;
    final mono = AppType.mono(size: 15, color: theme.colorScheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteEditHost : l10n.remoteAddUrlHost,
      subtitle: _editing ? null : Text(l10n.remoteUrlHostIntro),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.address],
                      error: _errors[_F.address],
                      label: l10n.remoteUrlAddress,
                      helper: l10n.remoteUrlLaunchTokenHint,
                      child: TextField(
                        controller: _address,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.address),
                        decoration: InputDecoration(
                          hintText: l10n.remoteUrlAddressHint,
                          error: _errors[_F.address] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.remoteAuthentication,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.remoteUrlLaunchToken,
                      helper: l10n.remoteUrlLaunchTokenHint,
                      child: TextField(
                        controller: _token,
                        obscureText: _obscure,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        onChanged: (_) => _edited(_F.token),
                        decoration: InputDecoration(
                          suffixIcon: IconButton(
                            tooltip: _obscure ? l10n.remoteShow : l10n.commonHide,
                            icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.remoteUrlAccessToken,
                      helper: l10n.remoteUrlAccessTokenHint,
                      child: TextField(
                        controller: _access,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.headers],
                      error: _errors[_F.headers],
                      label: l10n.remoteUrlHeaders,
                      helper: l10n.remoteUrlHeadersHint,
                      child: TextField(
                        controller: _headers,
                        minLines: 2,
                        maxLines: 5,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.multiline,
                        style: AppType.mono(size: 12, color: theme.colorScheme.onSurface, height: 1.45),
                        onChanged: (_) => _edited(_F.headers),
                        decoration: InputDecoration(
                          hintText: 'CF-Access-Client-Id: …',
                          hintStyle: AppType.mono(size: 12, color: colors.textTertiary, height: 1.45),
                          error: _errors[_F.headers] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            HostFormReveal(
              child: _testStatus == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: LinkProgressCard(status: _testStatus!, onRetry: testing ? null : _runTest),
                    ),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: HostFormBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: HostFormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The fields of the form that carry a message under them.
enum _F { address, token, headers }
