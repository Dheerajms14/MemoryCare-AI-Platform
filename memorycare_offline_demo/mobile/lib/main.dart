import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'account_actions.dart';
import 'auth_screen.dart';
import 'auth_service.dart';
import 'auth_strings.dart';
import 'caregiver_screen.dart';
import 'local_store.dart';
import 'media_service.dart';
import 'translations.dart';
import 'voice_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MemoryCareApp());
}

const _navy = Color(0xFF15324B);
const _teal = Color(0xFF1B7F79);
const _cream = Color(0xFFF8F5EE);
const _gold = Color(0xFFE9A23B);
const _rose = Color(0xFFD96C75);

class MemoryCareApp extends StatefulWidget {
  const MemoryCareApp({super.key});

  @override
  State<MemoryCareApp> createState() => _MemoryCareAppState();
}

class _MemoryCareAppState extends State<MemoryCareApp> {
  final LocalStore _store = LocalStore();
  bool _loading = true;
  String? _error;
  String _languageCode = 'en';
  bool _voiceEnabled = true;
  double _voiceRate = 0.42;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _store.open();
      _languageCode = await _store.getSetting('language_code') ?? 'en';
      _voiceEnabled = (await _store.getSetting('voice_enabled') ?? 'true') == 'true';
      _voiceRate = double.tryParse(await _store.getSetting('voice_rate') ?? '') ?? 0.42;
    } catch (error) {
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _changeLanguage(String value) async {
    await _store.setSetting('language_code', value);
    if (mounted) setState(() => _languageCode = value);
  }

  Future<void> _changeVoiceEnabled(bool value) async {
    await _store.setSetting('voice_enabled', value.toString());
    if (mounted) setState(() => _voiceEnabled = value);
  }

  Future<void> _changeVoiceRate(double value) async {
    await _store.setSetting('voice_rate', value.toString());
    if (mounted) setState(() => _voiceRate = value);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(_languageCode);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: strings.t('app_name'),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _cream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _teal,
          primary: _teal,
          secondary: _gold,
          surface: Colors.white,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _navy),
          titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _navy),
          titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _navy),
          bodyLarge: TextStyle(fontSize: 18, height: 1.35, color: _navy),
          bodyMedium: TextStyle(fontSize: 16, height: 1.35, color: _navy),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: const Color(0xFFE3E8E7)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF4F7F6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
          labelStyle: const TextStyle(fontSize: 17),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      home: _loading
          ? const _SplashScreen()
          : _error != null
              ? _ErrorScreen(message: _error!)
              : MemoryCareRoot(
                  store: _store,
                  languageCode: _languageCode,
                  voiceEnabled: _voiceEnabled,
                  voiceRate: _voiceRate,
                  onLanguageChanged: _changeLanguage,
                  onVoiceEnabledChanged: _changeVoiceEnabled,
                  onVoiceRateChanged: _changeVoiceRate,
                ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BrandMark(size: 86),
              SizedBox(height: 20),
              Text('MemoryCare', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
              SizedBox(height: 18),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_rounded, size: 56, color: _rose),
                    const SizedBox(height: 16),
                    const Text('Unable to open local storage', style: TextStyle(fontSize: 22)),
                    const SizedBox(height: 8),
                    Text(message, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _GameQuestion {
  const _GameQuestion({
    required this.type,
    required this.icon,
    required this.color,
    required this.prompts,
    required this.options,
    required this.answer,
  });

  final String type;
  final IconData icon;
  final Color color;
  final Map<String, String> prompts;
  final Map<String, List<String>> options;
  final int answer;

  String prompt(String language) => prompts[language] ?? prompts['en']!;
  List<String> choices(String language) => options[language] ?? options['en']!;
}

const _questions = [
  _GameQuestion(
    type: 'memory',
    icon: Icons.psychology_alt_rounded,
    color: Color(0xFF6F62B5),
    prompts: {
      'en': 'Remember: rice, mango and soap. Which item was named?',
      'kn': 'ನೆನಪಿಡಿ: ಅಕ್ಕಿ, ಮಾವು ಮತ್ತು ಸಾಬೂನು. ಯಾವ ವಸ್ತುವನ್ನು ಹೇಳಲಾಯಿತು?',
      'hi': 'याद रखें: चावल, आम और साबुन। इनमें से कौन-सी वस्तु कही गई थी?',
    },
    options: {
      'en': ['Rice', 'Shoes', 'Book'],
      'kn': ['ಅಕ್ಕಿ', 'ಚಪ್ಪಲಿ', 'ಪುಸ್ತಕ'],
      'hi': ['चावल', 'जूते', 'किताब'],
    },
    answer: 0,
  ),
  _GameQuestion(
    type: 'attention',
    icon: Icons.center_focus_strong_rounded,
    color: Color(0xFFE07955),
    prompts: {
      'en': 'Count the red circles: 🔴  🔵  🔴  🔴',
      'kn': 'ಕೆಂಪು ವೃತ್ತಗಳನ್ನು ಎಣಿಸಿ: 🔴  🔵  🔴  🔴',
      'hi': 'लाल गोलों को गिनें: 🔴  🔵  🔴  🔴',
    },
    options: {
      'en': ['2', '3', '4'],
      'kn': ['2', '3', '4'],
      'hi': ['2', '3', '4'],
    },
    answer: 1,
  ),
  _GameQuestion(
    type: 'pattern',
    icon: Icons.extension_rounded,
    color: Color(0xFF3185A8),
    prompts: {
      'en': 'What comes next? 2, 4, 6, …',
      'kn': 'ಮುಂದೆ ಯಾವ ಸಂಖ್ಯೆ ಬರುತ್ತದೆ? 2, 4, 6, …',
      'hi': 'आगे कौन-सी संख्या आएगी? 2, 4, 6, …',
    },
    options: {
      'en': ['8', '7', '9'],
      'kn': ['8', '7', '9'],
      'hi': ['8', '7', '9'],
    },
    answer: 0,
  ),
  _GameQuestion(
    type: 'routine',
    icon: Icons.wb_sunny_rounded,
    color: Color(0xFFB68A25),
    prompts: {
      'en': 'After breakfast, which task may need checking?',
      'kn': 'ಬೆಳಗಿನ ಉಪಾಹಾರದ ನಂತರ ಯಾವ ಕೆಲಸವನ್ನು ಪರಿಶೀಲಿಸಬೇಕು?',
      'hi': 'नाश्ते के बाद किस काम को जाँचना चाहिए?',
    },
    options: {
      'en': ['Morning reminders', 'Go to bed', 'Switch off every light'],
      'kn': ['ಬೆಳಗಿನ ಜ್ಞಾಪನೆಗಳು', 'ಮಲಗುವುದು', 'ಎಲ್ಲಾ ದೀಪ ಆರಿಸುವುದು'],
      'hi': ['सुबह के रिमाइंडर', 'सोने जाना', 'सभी लाइट बंद करना'],
    },
    answer: 0,
  ),
];

class MemoryCareRoot extends StatefulWidget {
  const MemoryCareRoot({
    super.key,
    required this.store,
    required this.languageCode,
    required this.voiceEnabled,
    required this.voiceRate,
    required this.onLanguageChanged,
    required this.onVoiceEnabledChanged,
    required this.onVoiceRateChanged,
  });

  final LocalStore store;
  final String languageCode;
  final bool voiceEnabled;
  final double voiceRate;
  final Future<void> Function(String) onLanguageChanged;
  final Future<void> Function(bool) onVoiceEnabledChanged;
  final Future<void> Function(double) onVoiceRateChanged;

  @override
  State<MemoryCareRoot> createState() => _MemoryCareRootState();
}

class _MemoryCareRootState extends State<MemoryCareRoot> {
  final VoiceService _voice = VoiceService();
  final MediaService _media = MediaService();
  final AuthClient _auth = AuthClient();
  final _url = TextEditingController(text: 'http://127.0.0.1:8000');
  bool _loading = true;
  bool _offlineMode = false;
  String? _startupError;
  bool _syncing = false;
  int _pending = 0;
  int _page = 0;
  List<Map<String, Object?>> _reminders = [];
  List<Map<String, Object?>> _memories = [];
  List<Map<String, Object?>> _games = [];
  Map<String, num> _statistics = const {};
  String _recommendedLevel = 'easy';
  Timer? _timer;

  AppStrings get s => AppStrings(widget.languageCode);

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // Do not reuse the old shared-account token stored in plain SQLite.
    await widget.store.removeSetting('access_token');
    try { await _auth.load(); }
    catch (_) {
      if (mounted) setState(() { _startupError = 'Unable to open protected login storage. Unlock the phone and restart the app. Offline records have not been deleted.'; _loading = false; });
      return;
    }
    _url.text = await widget.store.getSetting('api_url') ?? _url.text;
    if (_auth.session != null) _url.text = _auth.session!.server;
    final owner = await widget.store.getSetting('user_id');
    if (_auth.session?.role == 'patient' && owner != _auth.session!.userId) await _auth.clear();
    _offlineMode = (await widget.store.getSetting('offline_mode') ?? 'false') == 'true';
    await _refresh();
    _timer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_auth.session != null && _auth.session!.refreshExpiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 && !_syncing) {
        unawaited(_auth.clear().then((_) { if (mounted) setState(() {}); }));
        return;
      }
      if (!_offlineMode && _auth.session?.role == 'patient' && !_syncing) _sync(silent: true);
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refresh() async {
    final values = await Future.wait([
      widget.store.pendingCount(),
      widget.store.reminders(),
      widget.store.memories(),
      widget.store.games(),
      widget.store.statistics(),
      widget.store.recommendedLevel(),
    ]);
    if (!mounted) return;
    setState(() {
      _pending = values[0] as int;
      _reminders = values[1] as List<Map<String, Object?>>;
      _memories = values[2] as List<Map<String, Object?>>;
      _games = values[3] as List<Map<String, Object?>>;
      _statistics = values[4] as Map<String, num>;
      _recommendedLevel = values[5] as String;
    });
  }

  void _notice(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 16)),
          backgroundColor: error ? const Color(0xFF9E3D48) : _navy,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _submitAuth(String role, String username, String password, String? name) async {
    final server = checkedServerUrl(_url.text);
    final previousUser = await widget.store.getSetting('user_id');
    if (role == 'patient' && name != null && previousUser != null) {
      throw const AuthException('This device already contains patient data. Sign in to the original account. See AUTH_UPGRADE.md to reset its old demo password without losing data.');
    }
    if (name != null) {
      await _auth.publicPost(server, '/auth/register', {
        'username': username, 'password': password, 'display_name': name, 'role': role,
      });
    }
    final candidate = await _auth.signIn(server, username, password, role);
    if (candidate.role == 'patient' && previousUser != null && previousUser != candidate.userId) {
      await _auth.revokeCandidate(candidate);
      throw const AuthException('This device contains data for another patient. Use the original account; do not delete pending offline data.');
    }
    if (candidate.role == 'patient') await widget.store.setSetting('user_id', candidate.userId);
    await _auth.save(candidate);
    await widget.store.setSetting('api_url', server);
    if (!mounted) return;
    setState(() => _page = 0);
    if (candidate.role == 'patient') {
      await _refresh();
      await _sync(silent: true);
    }
  }

  Future<void> _logout() async {
    if (_syncing) { _notice('Wait for synchronization to finish.'); return; }
    await _voice.stopAll();
    final revoked = await _auth.logout();
    if (mounted) setState(() => _page = 0);
    _notice(revoked ? 'Signed out. Offline records were preserved.' : authText(widget.languageCode, 'offline_logout'));
  }

  Future<void> _passwordChanged() async {
    await _voice.stopAll();
    if (mounted) setState(() => _page = 0);
    _notice('Password changed. Sign in again on each device.');
  }

  Future<void> _sync({bool silent = false}) async {
    if (_offlineMode || _auth.session?.role != 'patient' || _syncing) return;
    if (mounted) setState(() => _syncing = true);
    try {
      final result = await ServerApi(_auth.session!.server, _auth).sync(widget.store);
      await _refresh();
      if (!silent) _notice('${s.t('all_synced')} · ${result.total}');
    } on AuthException catch (error) {
      await _refresh();
      if (!silent) _notice(error.message, error: true);
    } catch (_) {
      await _refresh();
      if (!silent) _notice(s.t('server_unavailable'), error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _setOfflineMode(bool value) async {
    await widget.store.setSetting('offline_mode', value.toString());
    setState(() => _offlineMode = value);
    if (!value) await _sync(silent: true);
  }

  Future<void> _speak(String text, {String? language}) async {
    if (!widget.voiceEnabled) return;
    try {
      await _voice.speak(
        text,
        language ?? widget.languageCode,
        rate: widget.voiceRate,
      );
    } catch (_) {
      _notice(s.t('voice_unavailable'), error: true);
    }
  }

  Future<void> _startVoiceCommand() async {
    var handled = false;
    final available = await _voice.listen(
      languageCode: widget.languageCode,
      onWords: (words, finalResult) {
        if (!finalResult || handled || words.trim().isEmpty) return;
        handled = true;
        _handleVoiceCommand(words);
      },
    );
    if (!available) {
      _notice(s.t('voice_unavailable'), error: true);
      return;
    }
    _notice(s.t('listening'));
  }

  void _handleVoiceCommand(String words) {
    final command = words.toLowerCase();
    bool hasAny(List<String> values) => values.any(command.contains);
    if (hasAny(['reminder', 'medicine', 'ಜ್ಞಾಪ', 'ಔಷಧ', 'रिमाइंडर', 'दवा'])) {
      setState(() => _page = 1);
      _speak(s.t('reminders'));
    } else if (hasAny(['game', 'ಆಟ', 'खेल'])) {
      setState(() => _page = 2);
      _speak(s.t('games'));
    } else if (hasAny(['memory', 'photo', 'ನೆನಪು', 'ಚಿತ್ರ', 'याद', 'फोटो'])) {
      setState(() => _page = 3);
      _speak(s.t('vault'));
    } else if (hasAny(['progress', 'ಪ್ರಗತಿ', 'प्रगति'])) {
      setState(() => _page = 4);
      _speak(s.t('progress'));
    } else if (hasAny(['sync', 'ಸಿಂಕ್', 'सिंक'])) {
      _sync();
    } else if (hasAny(['help', 'ಸಹಾಯ', 'मदद', 'सहायता'])) {
      _speak(s.t('help_command'));
    } else {
      _speak(s.t('help_command'));
    }
  }

  Future<bool> _confirmDelete() async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.delete_outline_rounded, color: _rose, size: 42),
            title: Text(s.t('confirm_delete')),
            content: Text(s.t('delete_warning')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(s.t('cancel')),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(s.t('delete')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showReminderEditor([Map<String, Object?>? existing]) async {
    final title = TextEditingController(text: existing?['title'] as String? ?? '');
    final voiceText = TextEditingController(text: existing?['voice_text'] as String? ?? '');
    var type = existing?['reminder_type'] as String? ?? 'medicine';
    var due = DateTime.tryParse(existing?['due_at'] as String? ?? '') ??
        DateTime.now().add(const Duration(hours: 1));
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => _BottomSheetFrame(
          title: existing == null ? s.t('add_reminder') : s.t('edit'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(controller: title, decoration: InputDecoration(labelText: s.t('title'))),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: InputDecoration(labelText: s.t('type')),
                items: ['medicine', 'appointment', 'activity', 'general']
                    .map((value) => DropdownMenuItem(value: value, child: Text(s.t(value))))
                    .toList(),
                onChanged: (value) => setSheetState(() => type = value ?? type),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final date = await showDatePicker(
                    context: sheetContext,
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                    initialDate: due,
                  );
                  if (date == null || !sheetContext.mounted) return;
                  final time = await showTimePicker(
                    context: sheetContext,
                    initialTime: TimeOfDay.fromDateTime(due),
                  );
                  if (time == null) return;
                  setSheetState(() {
                    due = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                  });
                },
                icon: const Icon(Icons.event_rounded),
                label: Text('${s.t('date_time')}: ${_formatDate(due)}'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: voiceText,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: s.t('spoken_message'),
                  hintText: s.t('spoken_hint'),
                  suffixIcon: IconButton(
                    onPressed: () => _speak(voiceText.text.isEmpty ? title.text : voiceText.text),
                    icon: const Icon(Icons.volume_up_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  if (title.text.trim().isEmpty) return;
                  Navigator.pop(sheetContext, true);
                },
                icon: const Icon(Icons.save_rounded),
                label: Text(s.t('save')),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    if (existing == null) {
      await widget.store.addReminder(
        title: title.text,
        dueAt: due.toIso8601String(),
        type: type,
        languageCode: widget.languageCode,
        voiceText: voiceText.text.isEmpty ? title.text : voiceText.text,
      );
    } else {
      await widget.store.updateReminder(
        id: existing['id'] as String,
        title: title.text,
        dueAt: due.toIso8601String(),
        type: type,
        languageCode: widget.languageCode,
        voiceText: voiceText.text.isEmpty ? title.text : voiceText.text,
      );
    }
    await _refresh();
    _notice(s.t('reminder_saved'));
  }

  Future<void> _deleteReminder(Map<String, Object?> row) async {
    if (!await _confirmDelete()) return;
    await widget.store.deleteReminder(row['id'] as String);
    await _refresh();
    _notice(s.t('reminder_deleted'));
  }

  Future<void> _showMemoryEditor([Map<String, Object?>? existing]) async {
    final name = TextEditingController(text: existing?['person_name'] as String? ?? '');
    final relationship =
        TextEditingController(text: existing?['relationship'] as String? ?? '');
    final note = TextEditingController(text: existing?['note'] as String? ?? '');
    String? photoPath = existing?['photo_path'] as String?;
    String? audioPath = existing?['audio_path'] as String?;
    var recording = false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => _BottomSheetFrame(
          title: existing == null ? s.t('vault') : s.t('edit'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (photoPath != null && File(photoPath!).existsSync()) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.file(File(photoPath!), height: 180, fit: BoxFit.cover),
                ),
                const SizedBox(height: 12),
              ],
              TextField(controller: name, decoration: InputDecoration(labelText: s.t('person_name'))),
              const SizedBox(height: 12),
              TextField(
                controller: relationship,
                decoration: InputDecoration(labelText: s.t('relationship')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: s.t('memory_note'),
                  suffixIcon: IconButton(
                    onPressed: () => _speak(note.text),
                    icon: const Icon(Icons.volume_up_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final value = await _media.pickMemoryPhoto(source: ImageSource.gallery);
                      if (value != null) setSheetState(() => photoPath = value);
                    },
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                    label: Text(photoPath == null ? s.t('add_photo') : s.t('change_photo')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (!recording) {
                        final path = await _voice.startRecording();
                        if (path == null) {
                          _notice(s.t('permission_needed'), error: true);
                          return;
                        }
                        setSheetState(() => recording = true);
                      } else {
                        final path = await _voice.stopRecording();
                        setSheetState(() {
                          recording = false;
                          audioPath = path;
                        });
                      }
                    },
                    icon: Icon(recording ? Icons.stop_circle_rounded : Icons.mic_rounded),
                    label: Text(recording ? s.t('stop_recording') : s.t('record_voice')),
                  ),
                  if (audioPath != null)
                    OutlinedButton.icon(
                      onPressed: () => _voice.playRecording(audioPath!),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(s.t('play_voice')),
                    ),
                ],
              ),
              if (recording) ...[
                const SizedBox(height: 12),
                _StatusPill(icon: Icons.graphic_eq_rounded, text: s.t('recording'), color: _rose),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () async {
                  if (recording) {
                    final path = await _voice.stopRecording();
                    audioPath = path;
                    recording = false;
                  }
                  if (name.text.trim().isEmpty || relationship.text.trim().isEmpty) return;
                  if (sheetContext.mounted) Navigator.pop(sheetContext, true);
                },
                icon: const Icon(Icons.save_rounded),
                label: Text(s.t('save')),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) {
      if (recording) await _voice.stopRecording();
      return;
    }
    if (existing == null) {
      await widget.store.addMemory(
        name: name.text,
        relationship: relationship.text,
        note: note.text,
        languageCode: widget.languageCode,
        photoPath: photoPath,
        audioPath: audioPath,
      );
    } else {
      await widget.store.updateMemory(
        id: existing['id'] as String,
        name: name.text,
        relationship: relationship.text,
        note: note.text,
        languageCode: widget.languageCode,
        photoPath: photoPath,
        audioPath: audioPath,
      );
    }
    await _refresh();
    _notice(s.t('memory_saved'));
  }

  Future<void> _deleteMemory(Map<String, Object?> row) async {
    if (!await _confirmDelete()) return;
    await widget.store.deleteMemory(row['id'] as String);
    for (final key in ['photo_path', 'audio_path']) {
      final path = row[key] as String?;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // The database deletion must still succeed if Android already cleared a file.
        }
      }
    }
    await _refresh();
    _notice(s.t('memory_deleted'));
  }

  Future<void> _play(_GameQuestion question) async {
    final prompt = question.prompt(widget.languageCode);
    final options = question.choices(widget.languageCode);
    final started = DateTime.now();
    if (widget.voiceEnabled) unawaited(_speak(prompt));
    final chosen = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: CircleAvatar(
          radius: 30,
          backgroundColor: question.color.withValues(alpha: 0.14),
          child: Icon(question.icon, color: question.color, size: 34),
        ),
        title: Text(_gameName(question.type)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(prompt, style: const TextStyle(fontSize: 22, height: 1.35))),
                  IconButton(onPressed: () => _speak(prompt), icon: const Icon(Icons.volume_up_rounded)),
                ],
              ),
              const SizedBox(height: 18),
              for (var index = 0; index < options.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.pop(dialogContext, index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text(options[index], style: const TextStyle(fontSize: 20)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    final correct = chosen == question.answer ? 1 : 0;
    final seconds = DateTime.now().difference(started).inSeconds;
    await widget.store.addGameResult(question.type, correct, 1, seconds, _recommendedLevel);
    await _refresh();
    final feedback = correct == 1 ? s.t('correct') : s.t('try_again');
    _notice('$feedback! ${s.t('game_saved')}');
    await _speak(feedback);
  }

  String _gameName(String type) => switch (type) {
        'memory' => s.t('memory_game'),
        'attention' => s.t('attention_game'),
        'pattern' => s.t('pattern_game'),
        _ => s.t('routine_game'),
      };

  String _pageTitle() => [
        s.t('home'),
        s.t('reminders'),
        s.t('games'),
        s.t('vault'),
        s.t('progress'),
      ][_page];

  String _pageSummary() {
    switch (_page) {
      case 0:
        return '${_greeting()}. ${s.t('today_support')}. ${_pending == 0 ? s.t('all_synced') : s.t('pending_uploads', values: {'count': _pending})}.';
      case 1:
        return '${s.t('reminders')}. ${_reminders.length}.';
      case 2:
        return '${s.t('games')}. ${s.t('adaptive_level')}: ${s.t(_recommendedLevel)}.';
      case 3:
        return '${s.t('vault')}. ${_memories.length} ${s.t('memories_saved')}.';
      default:
        return '${s.t('progress')}. ${s.t('games_played')}: ${_statistics['games'] ?? 0}. ${s.t('accuracy')}: ${(_statistics['accuracy'] ?? 0).round()} percent.';
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return s.t('good_morning');
    if (hour < 17) return s.t('good_afternoon');
    return s.t('good_evening');
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => _BottomSheetFrame(
          title: s.t('settings'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.t('language'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: supportedLanguages
                    .map(
                      (language) => ChoiceChip(
                        label: Text(language.nativeLabel, style: const TextStyle(fontSize: 16)),
                        selected: widget.languageCode == language.code,
                        onSelected: (_) async {
                          await widget.onLanguageChanged(language.code);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 18),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.t('voice_guidance')),
                secondary: const Icon(Icons.record_voice_over_rounded),
                value: widget.voiceEnabled,
                onChanged: (value) async {
                  await widget.onVoiceEnabledChanged(value);
                  setSheetState(() {});
                },
              ),
              Text('${s.t('voice_speed')}: ${widget.voiceRate < 0.4 ? s.t('slow') : s.t('normal')}'),
              Slider(
                min: 0.28,
                max: 0.55,
                divisions: 9,
                value: widget.voiceRate.clamp(0.28, 0.55),
                onChanged: (value) async {
                  await widget.onVoiceRateChanged(value);
                  setSheetState(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.t('offline_mode')),
                subtitle: Text(s.t('offline_description')),
                secondary: const Icon(Icons.cloud_off_rounded),
                value: _offlineMode,
                onChanged: (value) async {
                  await _setOfflineMode(value);
                  setSheetState(() {});
                },
              ),
              const Divider(height: 28),
              Text('${s.t('server_url')}:\n${_url.text}', style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showReconnect();
                },
                icon: const Icon(Icons.login_rounded),
                label: Text(s.t('reconnect')),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _offlineMode || _syncing ? null : () => _sync(),
                icon: const Icon(Icons.sync_rounded),
                label: Text(_syncing ? s.t('syncing') : s.t('sync_now')),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _syncing ? null : () {
                  Navigator.pop(sheetContext);
                  _showCaregiverAccess();
                },
                icon: const Icon(Icons.supervisor_account_rounded),
                label: Text(authText(widget.languageCode, 'link')),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _syncing ? null : () {
                  Navigator.pop(sheetContext);
                  showPasswordChange(context, _auth, widget.languageCode, _passwordChanged);
                },
                icon: const Icon(Icons.password_rounded),
                label: Text(authText(widget.languageCode, 'change')),
              ),
              TextButton.icon(
                onPressed: _syncing ? null : () { Navigator.pop(sheetContext); _logout(); },
                icon: const Icon(Icons.logout_rounded),
                label: Text(authText(widget.languageCode, 'logout')),
              ),
              const SizedBox(height: 10),
              Text(s.t('privacy_note'), style: TextStyle(color: Colors.blueGrey.shade700)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showReconnect() async {
    // Re-authenticate through the full form when changing the server origin.
    await _logout();
  }

  Future<void> _showCaregiverAccess() async {
    try {
      var reply = await _auth.get('/patients/caregivers');
      String? code;
      var busy = false;
      String? error;
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: Text(authText(widget.languageCode, 'link')),
          content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Only a caregiver who redeems your code can see your synchronized information. Share it privately with someone you trust.'),
              const SizedBox(height: 12),
              if (code != null) ...[
                SelectableText(code!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const Text('Single use. Expires in 10 minutes. A new code cancels the previous unused code.'),
                TextButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: code!)),
                  icon: const Icon(Icons.copy), label: const Text('Copy code')),
              ],
              if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
              FilledButton(onPressed: busy ? null : () async {
                update(() { busy = true; error = null; });
                try {
                  final invite = await _auth.post('/patients/invite', {});
                  if (dialogContext.mounted) update(() => code = invite['code'] as String);
                } catch (e) {
                  if (dialogContext.mounted) update(() => error = e is AuthException ? e.message : 'Cannot reach the server.');
                } finally { if (dialogContext.mounted) update(() => busy = false); }
              }, child: Text(authText(widget.languageCode, 'code'))),
              const Divider(height: 28),
              const Text('Linked caregivers', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final person in reply['caregivers'] as List) ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(person['display_name'] as String), subtitle: Text(person['username'] as String),
                trailing: IconButton(tooltip: authText(widget.languageCode, 'remove'), icon: const Icon(Icons.person_remove),
                  onPressed: busy ? null : () async {
                    update(() { busy = true; error = null; });
                    try {
                      checkedJson(await _auth.authorized('DELETE', '/patients/caregivers/${Uri.encodeComponent(person['user_id'] as String)}'));
                      final next = await _auth.get('/patients/caregivers');
                      if (dialogContext.mounted) update(() => reply = next);
                    } catch (e) {
                      if (dialogContext.mounted) update(() => error = e is AuthException ? e.message : 'Cannot reach the server.');
                    } finally { if (dialogContext.mounted) update(() => busy = false); }
                  }),
              ),
            ],
          ))),
          actions: [TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: Text(s.t('close')))],
        ),
      ));
    } on AuthException catch (error) { _notice(error.message, error: true); }
    catch (_) { _notice(s.t('server_unavailable'), error: true); }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _url.dispose();
    unawaited(_voice.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _SplashScreen();
    if (_startupError != null) return _ErrorScreen(message: _startupError!);
    if (_auth.session == null) {
      return AuthenticationScreen(
        languageCode: widget.languageCode,
        server: _url,
        onLanguageChanged: widget.onLanguageChanged,
        onSubmit: _submitAuth,
      );
    }
    if (_auth.session!.role == 'caregiver') return CaregiverScreen(
      auth: _auth, language: widget.languageCode, onLogout: _logout, onPasswordChanged: _passwordChanged,
      onSessionExpired: () async { if (mounted) setState(() => _page = 0); },
    );
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _cream,
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            const _BrandMark(size: 38),
            const SizedBox(width: 10),
            Expanded(child: Text(_pageTitle(), style: const TextStyle(fontWeight: FontWeight.w800))),
          ],
        ),
        actions: [
          IconButton(
            tooltip: s.t('read_page'),
            onPressed: () => _speak(_pageSummary()),
            icon: const Icon(Icons.volume_up_rounded),
          ),
          IconButton(
            tooltip: s.t('settings'),
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _page,
          children: [
            _homePage(),
            _remindersPage(),
            _gamesPage(),
            _vaultPage(),
            _progressPage(),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.large(
        onPressed: _startVoiceCommand,
        backgroundColor: _teal,
        foregroundColor: Colors.white,
        tooltip: s.t('voice_assistant'),
        child: const Icon(Icons.mic_rounded, size: 34),
      ),
      bottomNavigationBar: NavigationBar(
        height: 74,
        selectedIndex: _page,
        onDestinationSelected: (value) => setState(() => _page = value),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: s.t('home')),
          NavigationDestination(icon: const Icon(Icons.notifications_rounded), label: s.t('reminders')),
          NavigationDestination(icon: const Icon(Icons.extension_rounded), label: s.t('games')),
          NavigationDestination(icon: const Icon(Icons.photo_library_rounded), label: s.t('vault')),
          NavigationDestination(icon: const Icon(Icons.insights_rounded), label: s.t('progress')),
        ],
      ),
    );
  }

  Widget _pagePadding(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 116),
        children: children,
      );

  Widget _homePage() {
    final next = _reminders.where((row) => row['done'] != 1).firstOrNull;
    return _pagePadding([
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [_navy, Color(0xFF245F66)]),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_greeting(), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(s.t('today_support'), style: const TextStyle(color: Color(0xFFDDEBE9), fontSize: 17)),
                ],
              ),
            ),
            const Icon(Icons.favorite_rounded, color: Color(0xFFFFD18A), size: 48),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: _StatusPill(
              icon: _offlineMode ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
              text: _offlineMode ? s.t('offline') : s.t('online'),
              color: _offlineMode ? _rose : _teal,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatusPill(
              icon: _pending == 0 ? Icons.check_circle_rounded : Icons.sync_problem_rounded,
              text: _pending == 0 ? s.t('all_synced') : s.t('pending_uploads', values: {'count': _pending}),
              color: _pending == 0 ? _teal : _gold,
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      _SectionHeading(title: s.t('next_reminder'), icon: Icons.notifications_active_rounded),
      const SizedBox(height: 10),
      if (next == null)
        _EmptyCard(icon: Icons.event_available_rounded, message: s.t('no_reminders'))
      else
        _ReminderCard(
          row: next,
          strings: s,
          onDone: () async {
            await widget.store.markReminderDone(next['id'] as String);
            await _refresh();
          },
          onSpeak: () => _speak(
            (next['voice_text'] as String?)?.isNotEmpty == true
                ? next['voice_text'] as String
                : next['title'] as String,
            language: next['language_code'] as String? ?? widget.languageCode,
          ),
          onEdit: () => _showReminderEditor(next),
          onDelete: () => _deleteReminder(next),
        ),
      const SizedBox(height: 22),
      _SectionHeading(title: s.t('quick_actions'), icon: Icons.auto_awesome_rounded),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.18,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        children: [
          _ActionTile(
            icon: Icons.add_alarm_rounded,
            color: _rose,
            label: s.t('add_reminder'),
            onTap: _showReminderEditor,
          ),
          _ActionTile(
            icon: Icons.psychology_rounded,
            color: const Color(0xFF6F62B5),
            label: s.t('start_game'),
            onTap: () => setState(() => _page = 2),
          ),
          _ActionTile(
            icon: Icons.photo_library_rounded,
            color: _teal,
            label: s.t('view_memories'),
            onTap: () => setState(() => _page = 3),
          ),
          _ActionTile(
            icon: Icons.sync_rounded,
            color: _gold,
            label: s.t('sync_now'),
            onTap: _sync,
          ),
        ],
      ),
      const SizedBox(height: 18),
      Card(
        color: const Color(0xFFEAF5F3),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.mic_rounded, color: _teal, size: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.t('voice_assistant'), style: Theme.of(context).textTheme.titleMedium),
                    Text(s.t('tap_and_speak')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _remindersPage() => _pagePadding([
        FilledButton.icon(
          onPressed: _showReminderEditor,
          icon: const Icon(Icons.add_alarm_rounded),
          label: Text(s.t('add_reminder')),
        ),
        const SizedBox(height: 16),
        if (_reminders.isEmpty)
          _EmptyCard(icon: Icons.notifications_none_rounded, message: s.t('no_reminders'))
        else
          for (final row in _reminders) ...[
            _ReminderCard(
              row: row,
              strings: s,
              onDone: () async {
                await widget.store.markReminderDone(
                  row['id'] as String,
                  done: row['done'] != 1,
                );
                await _refresh();
              },
              onSpeak: () => _speak(
                (row['voice_text'] as String?)?.isNotEmpty == true
                    ? row['voice_text'] as String
                    : row['title'] as String,
                language: row['language_code'] as String? ?? widget.languageCode,
              ),
              onEdit: () => _showReminderEditor(row),
              onDelete: () => _deleteReminder(row),
            ),
            const SizedBox(height: 12),
          ],
      ]);

  Widget _gamesPage() => _pagePadding([
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFEDE9FA),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 28,
                backgroundColor: Color(0xFF6F62B5),
                child: Icon(Icons.auto_graph_rounded, color: Colors.white, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.t('adaptive_level'), style: Theme.of(context).textTheme.titleMedium),
                    Text(s.t(_recommendedLevel), style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, color: Color(0xFF594A9B))),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (final question in _questions) ...[
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => _play(question),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 29,
                      backgroundColor: question.color.withValues(alpha: 0.14),
                      child: Icon(question.icon, color: question.color, size: 31),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_gameName(question.type), style: Theme.of(context).textTheme.titleMedium),
                          Text(question.prompt(widget.languageCode), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    const Icon(Icons.play_circle_fill_rounded, color: _teal, size: 38),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ]);

  Widget _vaultPage() => _pagePadding([
        FilledButton.icon(
          onPressed: _showMemoryEditor,
          icon: const Icon(Icons.add_photo_alternate_rounded),
          label: Text(s.t('add_memory')),
        ),
        const SizedBox(height: 16),
        if (_memories.isEmpty)
          _EmptyCard(icon: Icons.photo_library_outlined, message: s.t('no_memories'))
        else
          for (final row in _memories) ...[
            _MemoryCard(
              row: row,
              strings: s,
              onSpeak: () => _speak(
                '${row['person_name']}, ${row['relationship']}. ${row['note']}',
                language: row['language_code'] as String? ?? widget.languageCode,
              ),
              onPlayAudio: row['audio_path'] == null
                  ? null
                  : () => _voice.playRecording(row['audio_path'] as String),
              onEdit: () => _showMemoryEditor(row),
              onDelete: () => _deleteMemory(row),
            ),
            const SizedBox(height: 12),
          ],
      ]);

  Widget _progressPage() {
    final accuracy = (_statistics['accuracy'] ?? 0).toDouble();
    final done = (_statistics['remindersDone'] ?? 0).toInt();
    final total = (_statistics['remindersTotal'] ?? 0).toInt();
    return _pagePadding([
      _SectionHeading(title: s.t('weekly_activity'), icon: Icons.insights_rounded),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.05,
        children: [
          _MetricCard(icon: Icons.extension_rounded, value: '${_statistics['games'] ?? 0}', label: s.t('games_played'), color: const Color(0xFF6F62B5)),
          _MetricCard(icon: Icons.track_changes_rounded, value: '${accuracy.round()}%', label: s.t('accuracy'), color: _teal),
          _MetricCard(icon: Icons.task_alt_rounded, value: '$done/$total', label: s.t('reminders_done'), color: _gold),
          _MetricCard(icon: Icons.photo_library_rounded, value: '${_statistics['memories'] ?? 0}', label: s.t('memories_saved'), color: _rose),
        ],
      ),
      const SizedBox(height: 18),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('accuracy'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: (accuracy / 100).clamp(0, 1),
                  minHeight: 16,
                  backgroundColor: const Color(0xFFE5EBE9),
                ),
              ),
              const SizedBox(height: 18),
              Text('${s.t('adaptive_level')}: ${s.t(_recommendedLevel)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(s.t('privacy_note')),
            ],
          ),
        ),
      ),
      if (_games.isNotEmpty) ...[
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.t('games_played'), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final game in _games.take(5))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.check_circle_rounded, color: _teal),
                    title: Text(_gameName(game['game_type'] as String)),
                    subtitle: Text('${game['correct']}/${game['total']} · ${game['seconds']}s · ${s.t(game['level'] as String? ?? 'easy')}'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ]);
  }
}


class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_teal, _navy]),
          borderRadius: BorderRadius.circular(size * 0.31),
          boxShadow: [BoxShadow(color: _teal.withValues(alpha: 0.22), blurRadius: 22, offset: const Offset(0, 8))],
        ),
        child: Icon(Icons.psychology_alt_rounded, color: Colors.white, size: size * 0.60),
      );
}

class _BottomSheetFrame extends StatelessWidget {
  const _BottomSheetFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: _cream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.viewInsetsOf(context).bottom + 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(width: 48, height: 5, decoration: BoxDecoration(color: Colors.blueGrey.shade200, borderRadius: BorderRadius.circular(99))),
                ),
                const SizedBox(height: 18),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 18),
                child,
              ],
            ),
          ),
        ),
      );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: _teal),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        ],
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.11), borderRadius: BorderRadius.circular(16)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 21),
            const SizedBox(width: 7),
            Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13))),
          ],
        ),
      );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            children: [
              Icon(icon, size: 48, color: Colors.blueGrey.shade300),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(radius: 25, backgroundColor: color.withValues(alpha: 0.13), child: Icon(icon, color: color, size: 28)),
                const SizedBox(height: 10),
                Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      );
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.row,
    required this.strings,
    required this.onDone,
    required this.onSpeak,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, Object?> row;
  final AppStrings strings;
  final VoidCallback onDone;
  final VoidCallback onSpeak;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final type = row['reminder_type'] as String? ?? 'general';
    final done = row['done'] == 1;
    final color = switch (type) {
      'medicine' => _rose,
      'appointment' => const Color(0xFF6F62B5),
      'activity' => _teal,
      _ => _gold,
    };
    final icon = switch (type) {
      'medicine' => Icons.medication_rounded,
      'appointment' => Icons.event_rounded,
      'activity' => Icons.directions_walk_rounded,
      _ => Icons.notifications_rounded,
    };
    return Card(
      color: done ? const Color(0xFFF0F3F2) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(radius: 26, backgroundColor: color.withValues(alpha: 0.13), child: Icon(icon, color: color, size: 28)),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row['title'] as String, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, decoration: done ? TextDecoration.lineThrough : null)),
                      const SizedBox(height: 3),
                      Text('${strings.t(type)} · ${_formatDate(DateTime.parse(row['due_at'] as String))}', style: TextStyle(color: Colors.blueGrey.shade700)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit', child: Text(strings.t('edit'))),
                    PopupMenuItem(value: 'delete', child: Text(strings.t('delete'))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: OutlinedButton.icon(onPressed: onSpeak, icon: const Icon(Icons.volume_up_rounded), label: Text(strings.t('listen')))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton.tonalIcon(onPressed: onDone, icon: Icon(done ? Icons.undo_rounded : Icons.check_rounded), label: Text(done ? strings.t('completed') : strings.t('done')))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.row,
    required this.strings,
    required this.onSpeak,
    required this.onPlayAudio,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, Object?> row;
  final AppStrings strings;
  final VoidCallback onSpeak;
  final VoidCallback? onPlayAudio;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final photoPath = row['photo_path'] as String?;
    final hasPhoto = photoPath != null && File(photoPath).existsSync();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasPhoto)
            Image.file(File(photoPath), height: 190, fit: BoxFit.cover)
          else
            Container(height: 112, color: const Color(0xFFEAF5F3), child: const Icon(Icons.family_restroom_rounded, size: 55, color: _teal)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(row['person_name'] as String, style: Theme.of(context).textTheme.titleLarge)),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') onEdit();
                        if (value == 'delete') onDelete();
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(strings.t('edit'))),
                        PopupMenuItem(value: 'delete', child: Text(strings.t('delete'))),
                      ],
                    ),
                  ],
                ),
                Text(row['relationship'] as String, style: const TextStyle(color: _teal, fontWeight: FontWeight.w700)),
                if ((row['note'] as String).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(row['note'] as String),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(onPressed: onSpeak, icon: const Icon(Icons.volume_up_rounded), label: Text(strings.t('listen'))),
                    if (onPlayAudio != null)
                      FilledButton.tonalIcon(onPressed: onPlayAudio, icon: const Icon(Icons.play_arrow_rounded), label: Text(strings.t('play_voice'))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.icon, required this.value, required this.label, required this.color});
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 34),
              const SizedBox(height: 8),
              Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: color)),
              const SizedBox(height: 3),
              Text(label, textAlign: TextAlign.center, maxLines: 2),
            ],
          ),
        ),
      );
}

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} · ${two(value.hour)}:${two(value.minute)}';
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
