import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Offline-first store. Every visible mutation and its outbox entry are written
/// in the same SQLite transaction, so a crash cannot lose a pending sync event.
class LocalStore {
  late final Database db;

  Future<void> open() async {
    db = await openDatabase(
      path.join(await getDatabasesPath(), 'memorycare.db'),
      version: 3,
      onCreate: (database, _) => _createSchema(database),
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addColumn(database, 'reminders', "reminder_type TEXT NOT NULL DEFAULT 'general'");
          await _addColumn(database, 'reminders', "language_code TEXT NOT NULL DEFAULT 'en'");
          await _addColumn(database, 'reminders', "voice_text TEXT NOT NULL DEFAULT ''");
          await _addColumn(database, 'memories', 'photo_path TEXT');
          await _addColumn(database, 'memories', 'audio_path TEXT');
          await _addColumn(database, 'memories', "language_code TEXT NOT NULL DEFAULT 'en'");
          await _addColumn(database, 'games', "level TEXT NOT NULL DEFAULT 'easy'");
        }
        if (oldVersion < 3) {
          await database.execute(
            'CREATE TABLE IF NOT EXISTS media_outbox ('
            'id TEXT PRIMARY KEY, memory_id TEXT NOT NULL, media_type TEXT NOT NULL, '
            'local_path TEXT NOT NULL)',
          );
        }
      },
    );
  }

  Future<void> _createSchema(Database database) async {
    await database.execute(
      'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await database.execute(
      'CREATE TABLE reminders (id TEXT PRIMARY KEY, title TEXT NOT NULL, '
      'due_at TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, '
      "reminder_type TEXT NOT NULL DEFAULT 'general', "
      "language_code TEXT NOT NULL DEFAULT 'en', voice_text TEXT NOT NULL DEFAULT '')",
    );
    await database.execute(
      'CREATE TABLE memories (id TEXT PRIMARY KEY, person_name TEXT NOT NULL, '
      'relationship TEXT NOT NULL, note TEXT NOT NULL, photo_path TEXT, '
      "audio_path TEXT, language_code TEXT NOT NULL DEFAULT 'en')",
    );
    await database.execute(
      'CREATE TABLE games (id TEXT PRIMARY KEY, game_type TEXT NOT NULL, '
      'correct INTEGER NOT NULL, total INTEGER NOT NULL, seconds INTEGER NOT NULL, '
      "played_at TEXT NOT NULL, level TEXT NOT NULL DEFAULT 'easy')",
    );
    await database.execute(
      'CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, '
      'op_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, payload_json TEXT NOT NULL)',
    );
    await database.execute(
      'CREATE TABLE media_outbox (id TEXT PRIMARY KEY, memory_id TEXT NOT NULL, '
      'media_type TEXT NOT NULL, local_path TEXT NOT NULL)',
    );
  }

  Future<void> _addColumn(Database database, String table, String definition) async {
    try {
      await database.execute('ALTER TABLE $table ADD COLUMN $definition');
    } on DatabaseException catch (error) {
      if (!error.toString().toLowerCase().contains('duplicate column')) rethrow;
    }
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> removeSetting(String key) async {
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<String> addReminder({
    required String title,
    required String dueAt,
    required String type,
    required String languageCode,
    required String voiceText,
  }) async {
    final id = _uuid.v4();
    final data = _reminderPayload(
      id: id,
      title: title,
      dueAt: dueAt,
      done: false,
      type: type,
      languageCode: languageCode,
      voiceText: voiceText,
    );
    await db.transaction((tx) async {
      await tx.insert('reminders', _localReminder(data));
      await _queue(tx, 'reminder', data);
    });
    return id;
  }

  Future<void> updateReminder({
    required String id,
    required String title,
    required String dueAt,
    required String type,
    required String languageCode,
    required String voiceText,
  }) async {
    await db.transaction((tx) async {
      final current = await tx.query('reminders', where: 'id = ?', whereArgs: [id], limit: 1);
      if (current.isEmpty) return;
      final data = _reminderPayload(
        id: id,
        title: title,
        dueAt: dueAt,
        done: current.first['done'] == 1,
        type: type,
        languageCode: languageCode,
        voiceText: voiceText,
      );
      await tx.update('reminders', _localReminder(data), where: 'id = ?', whereArgs: [id]);
      await _queue(tx, 'reminder', data);
    });
  }

  Future<void> markReminderDone(String id, {bool done = true}) async {
    await db.transaction((tx) async {
      await tx.update('reminders', {'done': done ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
      final rows = await tx.query('reminders', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      await _queue(tx, 'reminder', _serverReminder(rows.first));
    });
  }

  Future<void> deleteReminder(String id) async {
    await db.transaction((tx) async {
      await tx.delete('reminders', where: 'id = ?', whereArgs: [id]);
      await _queue(tx, 'delete_reminder', {'id': id});
    });
  }

  Future<String> addMemory({
    required String name,
    required String relationship,
    required String note,
    required String languageCode,
    String? photoPath,
    String? audioPath,
  }) async {
    final id = _uuid.v4();
    final local = <String, Object?>{
      'id': id,
      'person_name': name.trim(),
      'relationship': relationship.trim(),
      'note': note.trim(),
      'photo_path': photoPath,
      'audio_path': audioPath,
      'language_code': languageCode,
    };
    await db.transaction((tx) async {
      await tx.insert('memories', local);
      await _queue(tx, 'memory', _serverMemory(local));
      await _queueMedia(tx, id, 'photo', photoPath);
      await _queueMedia(tx, id, 'audio', audioPath);
    });
    return id;
  }

  Future<void> updateMemory({
    required String id,
    required String name,
    required String relationship,
    required String note,
    required String languageCode,
    String? photoPath,
    String? audioPath,
  }) async {
    final local = <String, Object?>{
      'id': id,
      'person_name': name.trim(),
      'relationship': relationship.trim(),
      'note': note.trim(),
      'photo_path': photoPath,
      'audio_path': audioPath,
      'language_code': languageCode,
    };
    await db.transaction((tx) async {
      final current = await tx.query('memories', where: 'id = ?', whereArgs: [id], limit: 1);
      final previousPhoto = current.isEmpty ? null : current.first['photo_path'] as String?;
      final previousAudio = current.isEmpty ? null : current.first['audio_path'] as String?;
      await tx.update('memories', local, where: 'id = ?', whereArgs: [id]);
      await _queue(tx, 'memory', _serverMemory(local));
      if (photoPath != previousPhoto) await _queueMedia(tx, id, 'photo', photoPath);
      if (audioPath != previousAudio) await _queueMedia(tx, id, 'audio', audioPath);
    });
  }

  Future<void> deleteMemory(String id) async {
    await db.transaction((tx) async {
      await tx.delete('memories', where: 'id = ?', whereArgs: [id]);
      await tx.delete('media_outbox', where: 'memory_id = ?', whereArgs: [id]);
      await _queue(tx, 'delete_memory', {'id': id});
    });
  }

  Future<void> addGameResult(
    String type,
    int correct,
    int total,
    int seconds,
    String level,
  ) async {
    final data = <String, Object?>{
      'id': _uuid.v4(),
      'game_type': type,
      'correct': correct,
      'total': total,
      'seconds': seconds,
      'played_at': DateTime.now().toUtc().toIso8601String(),
      'level': level,
    };
    await db.transaction((tx) async {
      await tx.insert('games', data);
      await _queue(tx, 'game', data);
    });
  }

  Map<String, Object?> _reminderPayload({
    required String id,
    required String title,
    required String dueAt,
    required bool done,
    required String type,
    required String languageCode,
    required String voiceText,
  }) =>
      {
        'id': id,
        'title': title.trim(),
        'due_at': dueAt.trim(),
        'done': done,
        'reminder_type': type,
        'language_code': languageCode,
        'voice_text': voiceText.trim(),
      };

  Map<String, Object?> _localReminder(Map<String, Object?> data) => {
        ...data,
        'done': data['done'] == true ? 1 : 0,
      };

  Map<String, Object?> _serverReminder(Map<String, Object?> row) => {
        'id': row['id'],
        'title': row['title'],
        'due_at': row['due_at'],
        'done': row['done'] == 1 || row['done'] == true,
        'reminder_type': row['reminder_type'] ?? 'general',
        'language_code': row['language_code'] ?? 'en',
        'voice_text': row['voice_text'] ?? '',
      };

  Map<String, Object?> _serverMemory(Map<String, Object?> row) => {
        'id': row['id'],
        'person_name': row['person_name'],
        'relationship': row['relationship'],
        'note': row['note'],
        'language_code': row['language_code'] ?? 'en',
      };

  Future<void> _queue(Transaction tx, String kind, Map<String, Object?> data) async {
    await tx.insert('outbox', {
      'op_id': _uuid.v4(),
      'kind': kind,
      'payload_json': jsonEncode(data),
    });
  }

  Future<void> _queueMedia(
    Transaction tx,
    String memoryId,
    String mediaType,
    String? localPath,
  ) async {
    if (localPath == null || localPath.isEmpty) return;
    await tx.insert(
      'media_outbox',
      {
        'id': '$memoryId:$mediaType',
        'memory_id': memoryId,
        'media_type': mediaType,
        'local_path': localPath,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> pending({int limit = 25}) =>
      db.query('outbox', orderBy: 'seq ASC', limit: limit);

  Future<List<Map<String, Object?>>> pendingMedia() => db.query('media_outbox');

  Future<void> acknowledge(List<String> ids) async {
    await db.transaction((tx) async {
      for (final id in ids) {
        await tx.delete('outbox', where: 'op_id = ?', whereArgs: [id]);
      }
    });
  }

  Future<void> acknowledgeMedia(String id) =>
      db.delete('media_outbox', where: 'id = ?', whereArgs: [id]);

  Future<int> pendingCount() async {
    final operations = await db.rawQuery('SELECT COUNT(*) AS amount FROM outbox');
    final media = await db.rawQuery('SELECT COUNT(*) AS amount FROM media_outbox');
    return (operations.first['amount'] as int) + (media.first['amount'] as int);
  }

  Future<List<Map<String, Object?>>> reminders() =>
      db.query('reminders', orderBy: 'done ASC, due_at ASC');

  Future<List<Map<String, Object?>>> memories() =>
      db.query('memories', orderBy: 'rowid DESC');

  Future<List<Map<String, Object?>>> games() =>
      db.query('games', orderBy: 'played_at DESC');

  Future<Map<String, num>> statistics() async {
    final gameRows = await db.rawQuery(
      'SELECT COUNT(*) AS played, COALESCE(SUM(correct), 0) AS correct, '
      'COALESCE(SUM(total), 0) AS total FROM games',
    );
    final reminderRows = await db.rawQuery(
      'SELECT COUNT(*) AS total, COALESCE(SUM(done), 0) AS done FROM reminders',
    );
    final memoryRows = await db.rawQuery('SELECT COUNT(*) AS total FROM memories');
    final game = gameRows.first;
    final reminder = reminderRows.first;
    final totalAnswers = game['total'] as int;
    final correctAnswers = game['correct'] as int;
    return {
      'games': game['played'] as int,
      'accuracy': totalAnswers == 0 ? 0 : (correctAnswers * 100 / totalAnswers),
      'remindersDone': reminder['done'] as int,
      'remindersTotal': reminder['total'] as int,
      'memories': memoryRows.first['total'] as int,
    };
  }

  Future<String> recommendedLevel() async {
    final rows = await db.query('games', orderBy: 'played_at DESC', limit: 8);
    if (rows.length < 3) return 'easy';
    final correct = rows.fold<int>(0, (sum, row) => sum + (row['correct'] as int));
    final total = rows.fold<int>(0, (sum, row) => sum + (row['total'] as int));
    final accuracy = total == 0 ? 0 : correct / total;
    final averageSeconds =
        rows.fold<int>(0, (sum, row) => sum + (row['seconds'] as int)) / rows.length;
    if (accuracy >= 0.85 && averageSeconds <= 18) return 'hard';
    if (accuracy >= 0.60) return 'medium';
    return 'easy';
  }
}
