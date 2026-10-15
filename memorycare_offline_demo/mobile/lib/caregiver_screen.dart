import 'package:flutter/material.dart';

import 'account_actions.dart';
import 'auth_service.dart';
import 'auth_strings.dart';

/// The caregiver view loads only authorized server data, never the patient SQLite cache.
class CaregiverScreen extends StatefulWidget {
  const CaregiverScreen({super.key, required this.auth, required this.language, required this.onLogout, required this.onPasswordChanged, required this.onSessionExpired});
  final AuthClient auth;
  final String language;
  final Future<void> Function() onLogout;
  final Future<void> Function() onPasswordChanged;
  final Future<void> Function() onSessionExpired;
  @override
  State<CaregiverScreen> createState() => _CaregiverScreenState();
}

class _CaregiverScreenState extends State<CaregiverScreen> {
  final _code = TextEditingController();
  List<Map<String, dynamic>> _patients = [];
  Map<String, dynamic>? _summary;
  String? _selected, _error;
  bool _busy = false;
  String t(String key) => authText(widget.language, key);
  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  Future<void> _load() async {
    if (_busy) return;
    setState(() { _busy = true; _summary = null; _error = null; });
    try {
      final data = await widget.auth.get('/caregiver/patients');
      _patients = (data['patients'] as List).map((row) => Map<String, dynamic>.from(row as Map)).toList();
      if (!_patients.any((row) => row['user_id'] == _selected)) _selected = _patients.isEmpty ? null : _patients.first['user_id'] as String;
      if (_selected != null) _summary = await widget.auth.get('/caregiver/summary?patient_id=${Uri.encodeComponent(_selected!)}');
    } catch (error) {
      _error = error is AuthException ? error.message : 'Server unavailable. Caregiver information requires an online connection.';
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted && widget.auth.session == null) await widget.onSessionExpired();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _summary?['stats'] as Map?;
    return Scaffold(
      appBar: AppBar(title: Text('MemoryCare · ${t('caregiver')}'), actions: [
        IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(onSelected: (value) async {
          if (value == 'logout') { await widget.onLogout(); }
          else { await showPasswordChange(context, widget.auth, widget.language, widget.onPasswordChanged); }
        }, itemBuilder: (_) => [PopupMenuItem(value: 'password', child: Text(t('change'))),
            PopupMenuItem(value: 'logout', child: Text(t('logout')))]),
      ]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Welcome, ${widget.auth.session?.name ?? ''}', style: Theme.of(context).textTheme.titleLarge),
        const Text('Only patients who grant access are shown here. This view does not perform diagnosis.'),
        const SizedBox(height: 18),
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Link a patient using their one-time code'),
          TextField(controller: _code, autocorrect: false, maxLength: 24,
            decoration: const InputDecoration(labelText: '24-character linking code')),
          FilledButton(onPressed: _busy ? null : () async {
            if (_code.text.trim().length != 24) { setState(() => _error = 'Enter the complete linking code.'); return; }
            setState(() => _busy = true);
            var linked = false;
            try {
              await widget.auth.post('/caregiver/link', {'code': _code.text.trim()});
              _code.clear();
              linked = true;
            } catch (error) {
              if (mounted) setState(() => _error = error.toString());
            } finally {
              if (mounted) setState(() => _busy = false);
            }
            if (mounted && linked) await _load();
          }, child: const Text('Link patient')),
        ]))),
        if (_busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
        if (!_busy && _patients.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No patient linked yet.')),
        if (_patients.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: DropdownButtonFormField<String>(
          key: ValueKey(_selected), initialValue: _selected,
          isExpanded: true,
          items: _patients.map((p) => DropdownMenuItem(value: p['user_id'] as String, child: Text(p['display_name'] as String))).toList(),
          onChanged: _busy ? null : (value) { _selected = value; _load(); },
          decoration: const InputDecoration(labelText: 'Linked patient'),
        )),
        if (stats != null) Wrap(spacing: 12, runSpacing: 12, children: [
          _stat('Pending reminders', '${stats['pending_reminders']}'), _stat('Memories', '${stats['memories']}'),
          _stat('Games played', '${stats['games']}'), _stat('Game accuracy', '${stats['accuracy']}%'),
        ]),
        if (_summary != null) ...[
          const SizedBox(height: 22), Text('Reminders', style: Theme.of(context).textTheme.titleLarge),
          for (final row in _summary!['reminders'] as List) Card(child: ListTile(
            leading: Icon(row['done'] == true ? Icons.check_circle : Icons.notifications),
            title: Text(row['title'] as String), subtitle: Text(row['due_at'] as String))),
          const SizedBox(height: 18), Text('Memory Vault', style: Theme.of(context).textTheme.titleLarge),
          for (final row in _summary!['memories'] as List) Card(child: ListTile(
            leading: row['photo_url'] == null ? const Icon(Icons.photo) : SizedBox(width: 52, height: 52,
              child: Image.network('${widget.auth.session!.server}${row['photo_url']}', fit: BoxFit.cover,
                headers: {'Authorization': 'Bearer ${widget.auth.session!.accessToken}'},
                errorBuilder: (_, error, trace) => const Icon(Icons.broken_image))),
            title: Text(row['person_name'] as String), subtitle: Text('${row['relationship']}\n${row['note']}'))),
          const SizedBox(height: 16), const Text('Open the caregiver web dashboard for audio playback and detailed game history.'),
        ],
      ])),
    );
  }

  Widget _stat(String label, String value) => SizedBox(width: 150, child: Card(child: Padding(
    padding: const EdgeInsets.all(16), child: Column(children: [Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)), Text(label)]))));
}
