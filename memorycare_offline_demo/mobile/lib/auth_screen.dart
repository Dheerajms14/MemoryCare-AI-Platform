import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'auth_strings.dart';
import 'translations.dart';

class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({super.key, required this.languageCode, required this.server,
    required this.onLanguageChanged, required this.onSubmit});
  final String languageCode;
  final TextEditingController server;
  final Future<void> Function(String) onLanguageChanged;
  final Future<void> Function(String role, String username, String password, String? name) onSubmit;
  @override
  State<AuthenticationScreen> createState() => _AuthenticationScreenState();
}

class _AuthenticationScreenState extends State<AuthenticationScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String _role = 'patient';
  bool _create = false, _busy = false, _visible = false;
  String? _error;
  String t(String key) => authText(widget.languageCode, key);

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.onSubmit(_role, _username.text.trim(), _password.text, _create ? _name.text.trim() : null);
    } catch (error) {
      if (mounted) setState(() => _error = error is AuthException ? error.message : 'Unable to connect. Check the server and try again.');
    } finally {
      if (mounted) { _password.clear(); _confirm.clear(); setState(() => _busy = false); }
    }
  }

  @override
  void dispose() { _name.dispose(); _username.dispose(); _password.dispose(); _confirm.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.languageCode);
    return Scaffold(body: SafeArea(child: ListView(padding: const EdgeInsets.all(22), children: [
      const SizedBox(height: 20),
      const Icon(Icons.health_and_safety_rounded, size: 76, color: Color(0xFF1B7F79)),
      Text('MemoryCare', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
      Text(strings.t('tagline'), textAlign: TextAlign.center),
      const SizedBox(height: 20),
      Wrap(alignment: WrapAlignment.center, spacing: 8, children: supportedLanguages.map((language) => ChoiceChip(
        label: Text(language.nativeLabel), selected: widget.languageCode == language.code,
        onSelected: _busy ? null : (_) => widget.onLanguageChanged(language.code),
      )).toList()),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(20), child: AutofillGroup(child: Form(key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_create ? t('create') : t('login'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          SegmentedButton<String>(segments: [
            ButtonSegment(value: 'patient', label: Text(t('patient')), icon: const Icon(Icons.person_outline)),
            ButtonSegment(value: 'caregiver', label: Text(t('caregiver')), icon: const Icon(Icons.diversity_1)),
          ], selected: {_role}, onSelectionChanged: _busy ? null : (values) => setState(() => _role = values.first)),
          const SizedBox(height: 16),
          if (_create) ...[
            TextFormField(controller: _name, enabled: !_busy, autofillHints: const [AutofillHints.name],
              decoration: InputDecoration(labelText: t('name')), maxLength: 120,
              validator: (value) => (value?.trim().length ?? 0) < 2 ? t('required') : null),
            const SizedBox(height: 12),
          ],
          TextFormField(controller: _username, enabled: !_busy, autocorrect: false,
            autofillHints: const [AutofillHints.username], textCapitalization: TextCapitalization.none,
            textInputAction: TextInputAction.next, maxLength: 40,
            decoration: InputDecoration(labelText: strings.t('username'), prefixIcon: const Icon(Icons.person)),
            validator: (value) => value == null || !RegExp(r'^[a-zA-Z0-9_.-]{3,40}$').hasMatch(value.trim())
                ? 'Use 3–40 letters, numbers, dots, hyphens or underscores.' : null),
          const SizedBox(height: 12),
          TextFormField(controller: _password, enabled: !_busy, obscureText: !_visible,
            enableSuggestions: false, autocorrect: false, maxLength: 128,
            autofillHints: [_create ? AutofillHints.newPassword : AutofillHints.password],
            onFieldSubmitted: (_) { if (!_create) _submit(); },
            decoration: InputDecoration(labelText: t('passphrase'), prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(onPressed: () => setState(() => _visible = !_visible),
                  icon: Icon(_visible ? Icons.visibility_off : Icons.visibility))),
            validator: (value) => value == null || value.isEmpty ? t('required')
                : _create && value.length < 15 ? t('short') : null),
          if (_create) ...[
            Text(t('hint'), style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            TextFormField(controller: _confirm, enabled: !_busy, obscureText: true,
              autocorrect: false, enableSuggestions: false, maxLength: 128,
              decoration: InputDecoration(labelText: t('confirm')),
              validator: (value) => value != _password.text ? t('match') : null),
          ],
          const SizedBox(height: 12),
          TextFormField(controller: widget.server, enabled: !_busy, keyboardType: TextInputType.url,
            autocorrect: false, decoration: InputDecoration(labelText: strings.t('server_url'), prefixIcon: const Icon(Icons.dns)),
            validator: (value) { try { checkedServerUrl(value ?? ''); return null; } catch (error) { return error.toString(); } }),
          if (allowLocalHttp) const Padding(padding: EdgeInsets.only(top: 10), child: Text(
            'Local HTTP demo mode: use test data only. Production must use HTTPS.', style: TextStyle(fontSize: 13, color: Colors.deepOrange))),
          if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!, style: const TextStyle(color: Colors.red), semanticsLabel: _error)),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: _busy ? null : _submit,
            icon: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.lock),
            label: Text(_create ? t('create') : t('login'))),
          TextButton(onPressed: _busy ? null : () => setState(() { _create = !_create; _error = null; }),
            child: Text(_create ? t('existing') : t('new'))),
        ]))))),
      const SizedBox(height: 18),
      Text(t('security'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
    ])));
  }
}
