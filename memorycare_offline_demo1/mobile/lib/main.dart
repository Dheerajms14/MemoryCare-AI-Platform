import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'local_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MemoryCareApp());
}

class MemoryCareApp extends StatelessWidget {
  const MemoryCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MemoryCare Offline Demo',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF195B87)),
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 17)),
      ),
      home: const HomeScreen(),
    );
  }
}

class _GameQuestion {
  const _GameQuestion(this.type, this.title, this.prompt, this.options, this.answer);
  final String type;
  final String title;
  final String prompt;
  final List<String> options;
  final int answer;
}

const _questions = [
  _GameQuestion('memory', 'Memory', 'Remember: rice, mango, soap. Which item was named?',
      ['Rice', 'Shoes', 'Book'], 0),
  _GameQuestion('attention', 'Attention', 'Count the red circles: 🔴 🔵 🔴 🔴',
      ['2', '3', '4'], 1),
  _GameQuestion('pattern', 'Pattern', 'What comes next? 2, 4, 6, ...',
      ['8', '7', '9'], 0),
  _GameQuestion('routine', 'Daily routine', 'After breakfast, which task may need checking?',
      ['Morning reminders', 'Go to bed', 'Switch off all lights'], 0),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = LocalStore();
  final _url = TextEditingController(text: 'http://10.0.2.2:8000');
  final _username = TextEditingController(text: 'patient');
  final _password = TextEditingController(text: 'demo1234');
  final _reminder = TextEditingController();
  final _due = TextEditingController(
      text: DateTime.now().add(const Duration(hours: 1)).toIso8601String().substring(0, 16));
  final _name = TextEditingController();
  final _relation = TextEditingController();
  final _note = TextEditingController();
  String? _token;
  bool _loading = true;
  bool _offlineMode = false;
  bool _syncing = false;
  int _pending = 0;
  List<Map<String, Object?>> _reminders = [];
  List<Map<String, Object?>> _memories = [];
  List<Map<String, Object?>> _games = [];
  Timer? _timer;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _store.open();
      final savedToken = await _store.getSetting('access_token');
      _token = savedToken == null || savedToken.isEmpty ? null : savedToken;
      _url.text = await _store.getSetting('api_url') ?? _url.text;
      await _refresh();
      _timer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!_offlineMode && _token != null && !_syncing) _sync(silent: true);
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Unable to open local database: $error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refresh() async {
    final pending = await _store.pendingCount();
    final reminders = await _store.reminders();
    final memories = await _store.memories();
    final games = await _store.games();
    if (mounted) {
      setState(() {
        _pending = pending;
        _reminders = reminders;
        _memories = memories;
        _games = games;
      });
    }
  }

  Future<void> _login() async {
    try {
      final baseUrl = _url.text.trim().replaceAll(RegExp(r'/$'), '');
      final reply = await ServerApi(baseUrl).login(_username.text.trim(), _password.text);
      if (reply['role'] != 'patient') throw Exception('Sign in with the patient account.');
      final previousUser = await _store.getSetting('user_id');
      if (previousUser != null && previousUser != reply['user_id']) {
        throw Exception('Local data belongs to another patient on this device.');
      }
      await _store.setSetting('access_token', reply['access_token'] as String);
      await _store.setSetting('user_id', reply['user_id'] as String);
      await _store.setSetting('api_url', baseUrl);
      _token = reply['access_token'] as String;
      if (mounted) setState(() => _message = 'Signed in. Offline mode is available.');
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _message = 'Connect to your local server to sign in: $error');
    }
  }

  Future<void> _renewLogin() async {
    var newPassword = '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reconnect account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'Server URL'),
            ),
            TextField(
              onChanged: (value) => newPassword = value,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Patient password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, newPassword),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    _password.text = value;
    // Keep the previous cached login and outbox if reconnection fails.
    await _login();
  }

  Future<void> _sync({bool silent = false}) async {
    if (_offlineMode || _token == null || _syncing) return;
    _syncing = true;
    try {
      final uploaded = await ServerApi(_url.text.trim().replaceAll(RegExp(r'/$'), ''))
          .sync(_store, _token!);
      await _refresh();
      if (mounted && !silent) {
        setState(() => _message = 'Synchronized $uploaded change(s).');
      }
    } catch (error) {
      // A failed request never deletes pending operations; users can retry later.
      if (mounted && !silent) {
        setState(() => _message = 'Server unavailable; $_pending change(s) kept on device. $error');
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _saveReminder() async {
    if (_reminder.text.trim().isEmpty || DateTime.tryParse(_due.text.trim()) == null) {
      setState(() => _message = 'Enter a reminder and a date like 2026-09-22 16:30.');
      return;
    }
    await _store.addReminder(
        _reminder.text, DateTime.parse(_due.text.trim()).toIso8601String());
    _reminder.clear();
    await _refresh();
    if (mounted) setState(() => _message = 'Reminder saved on device.');
  }

  Future<void> _markDone(String id) async {
    await _store.markReminderDone(id);
    await _refresh();
    if (mounted) setState(() => _message = 'Reminder completed on device.');
  }

  Future<void> _saveMemory() async {
    if (_name.text.trim().isEmpty || _relation.text.trim().isEmpty) {
      setState(() => _message = 'Enter a name and relationship.');
      return;
    }
    await _store.addMemory(_name.text, _relation.text, _note.text);
    _name.clear();
    _relation.clear();
    _note.clear();
    await _refresh();
    if (mounted) setState(() => _message = 'Memory note saved on device.');
  }

  Future<void> _play(_GameQuestion question) async {
    final started = DateTime.now();
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(question.prompt, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 14),
            for (var index = 0; index < question.options.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, index),
                  child: Text(question.options[index], style: const TextStyle(fontSize: 20)),
                ),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final correct = chosen == question.answer ? 1 : 0;
    final seconds = DateTime.now().difference(started).inSeconds;
    await _store.addGameResult(question.type, correct, 1, seconds);
    await _refresh();
    if (mounted) {
      setState(() => _message =
          correct == 1 ? 'Well done! Result saved on device.' : 'Good try. Result saved on device.');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [
      _url, _username, _password, _reminder, _due, _name, _relation, _note
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController controller, String label, {int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        maxLines: lines,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('MemoryCare · offline demo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(_message, style: const TextStyle(fontSize: 16)),
              ),
            if (_token == null)
              _section('First sign in while online', [
                _field(_url, 'Server URL (emulator: http://10.0.2.2:8000)'),
                _field(_username, 'Username'),
                TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Password', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                FilledButton(onPressed: _login, child: const Text('Sign in')),
                const Text('Then use the app without any network connection.'),
              ])
            else ...[
              _section('Connection and sync', [
                SwitchListTile(
                  title: Text(_offlineMode ? 'Offline demo mode ON' : 'Offline demo mode OFF'),
                  subtitle: const Text('Switch ON to prevent all network uploads.'),
                  value: _offlineMode,
                  onChanged: (value) => setState(() => _offlineMode = value),
                ),
                Text('Pending uploads: $_pending'),
                Text('Status: ' + (_offlineMode ? 'offline' : 'online / will retry')),
                FilledButton(
                  onPressed: _offlineMode || _syncing ? null : () => _sync(),
                  child: const Text('Sync now'),
                ),
                TextButton(
                  onPressed: _offlineMode ? null : _renewLogin,
                  child: const Text('Renew login if token expired'),
                ),
              ]),
              _section('Reminders stored offline', [
                _field(_reminder, 'Reminder, e.g. Take morning medicine'),
                _field(_due, 'Date and time: YYYY-MM-DD HH:mm'),
                FilledButton(onPressed: _saveReminder, child: const Text('Save reminder')),
                for (final row in _reminders)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(row['title'] as String),
                    subtitle: Text((row['due_at'] as String).replaceFirst('T', ' ')),
                    trailing: row['done'] == 1
                        ? const Icon(Icons.check_circle, semanticLabel: 'Completed')
                        : TextButton(
                            onPressed: () => _markDone(row['id'] as String),
                            child: const Text('Done')),
                  ),
              ]),
              _section('Memory Vault notes stored offline', [
                _field(_name, 'Person name'),
                _field(_relation, 'Relationship'),
                _field(_note, 'A helpful memory', lines: 2),
                FilledButton(onPressed: _saveMemory, child: const Text('Save memory note')),
                for (final row in _memories)
                  ListTile(
                    title: Text((row['person_name'] as String) +
                        ' · ' + (row['relationship'] as String)),
                    subtitle: Text(row['note'] as String),
                  ),
              ]),
              _section('Four example games', [
                const Text('Answers and completion times are recorded locally.'),
                for (final question in _questions)
                  OutlinedButton(
                    onPressed: () => _play(question),
                    child: Text('Play ' + question.title),
                  ),
                Text('Locally saved game results: ' + _games.length.toString()),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
