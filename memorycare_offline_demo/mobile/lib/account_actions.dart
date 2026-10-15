import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'auth_strings.dart';

Future<void> showPasswordChange(BuildContext context, AuthClient auth, String language,
    Future<void> Function() onChanged) async {
  await showDialog<void>(context: context, builder: (_) => _ChangePasswordDialog(
    auth: auth, language: language, onChanged: onChanged));
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.auth, required this.language, required this.onChanged});
  final AuthClient auth;
  final String language;
  final Future<void> Function() onChanged;
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(), _next = TextEditingController(), _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  String t(String key) => authText(widget.language, key);
  @override
  void dispose() { _current.dispose(); _next.dispose(); _confirm.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('change')),
    content: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextFormField(controller: _current, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: InputDecoration(labelText: t('current')), validator: (v) => v == null || v.isEmpty ? t('required') : null),
      const SizedBox(height: 12),
      TextFormField(controller: _next, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: InputDecoration(labelText: t('passphrase')), maxLength: 128,
        validator: (v) => (v?.length ?? 0) < 15 ? t('short') : null),
      TextFormField(controller: _confirm, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: InputDecoration(labelText: t('confirm')), validator: (v) => v != _next.text ? t('match') : null),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
    ]))),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : () async {
        if (!_form.currentState!.validate()) return;
        setState(() { _busy = true; _error = null; });
        try {
          await widget.auth.post('/auth/change-password', {'current_password': _current.text, 'new_password': _next.text});
          await widget.auth.clear();
          if (context.mounted) Navigator.pop(context);
          await widget.onChanged();
        } catch (error) {
          if (mounted) setState(() => _error = error is AuthException ? error.message : 'Unable to reach the server.');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }, child: Text(_busy ? '…' : t('save'))),
    ],
  );
}
