import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Store every change and its pending upload in ONE local SQLite transaction.
class LocalStore {
  late final Database db;

  Future<void> open() async {
    db = await openDatabase(
      path.join(await getDatabasesPath(), 'memorycare.db'),
      version: 1,
      onCreate: (database, _) async {
        await database.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE reminders (id TEXT PRIMARY KEY, title TEXT NOT NULL, '
          'due_at TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)',
        );
        await database.execute(
          'CREATE TABLE memories (id TEXT PRIMARY KEY, person_name TEXT NOT NULL, '
          'relationship TEXT NOT NULL, note TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE games (id TEXT PRIMARY KEY, game_type TEXT NOT NULL, '
          'correct INTEGER NOT NULL, total INTEGER NOT NULL, seconds INTEGER NOT NULL, '
          'played_at TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, '
          'op_id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, payload_json TEXT NOT NULL)',
        );
      },
    );
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final rows = await db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> addReminder(String title, String dueAt) async {
    final data = {
      'id': _uuid.v4(),
      'title': title.trim(),
      'due_at': dueAt.trim(),
      'done': false,
    };
    await db.transaction((tx) async {
      await tx.insert('reminders', {...data, 'done': 0});
      await _queue(tx, 'reminder', data);
    });
  }

  Future<void> markReminderDone(String id) async {
    await db.transaction((tx) async {
      await tx.update('reminders', {'done': 1}, where: 'id = ?', whereArgs: [id]);
      final rows = await tx.query('reminders', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final row = rows.first;
      await _queue(tx, 'reminder', {
        'id': row['id'],
        'title': row['title'],
        'due_at': row['due_at'],
        'done': true,
      });
    });
  }

  Future<void> addMemory(String name, String relationship, String note) async {
    final data = {
      'id': _uuid.v4(),
      'person_name': name.trim(),
      'relationship': relationship.trim(),
      'note': note.trim(),
    };
    await db.transaction((tx) async {
      await tx.insert('memories', data);
      await _queue(tx, 'memory', data);
    });
  }

  Future<void> addGameResult(String type, int correct, int total, int seconds) async {
    final data = {
      'id': _uuid.v4(),
      'game_type': type,
      'correct': correct,
      'total': total,
      'seconds': seconds,
      'played_at': DateTime.now().toUtc().toIso8601String(),
    };
    await db.transaction((tx) async {
      await tx.insert('games', data);
      await _queue(tx, 'game', data);
    });
  }

  Future<void> _queue(Transaction tx, String kind, Map<String, dynamic> data) async {
    await tx.insert('outbox', {
      'op_id': _uuid.v4(),
      'kind': kind,
      'payload_json': jsonEncode(data),
    });
  }

  Future<List<Map<String, Object?>>> pending({int limit = 25}) {
    return db.query('outbox', orderBy: 'seq ASC', limit: limit);
  }

  Future<void> acknowledge(List<String> ids) async {
    await db.transaction((tx) async {
      for (final id in ids) {
        await tx.delete('outbox', where: 'op_id = ?', whereArgs: [id]);
      }
    });
  }

  Future<int> pendingCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS amount FROM outbox');
    return rows.first['amount'] as int;
  }

  Future<List<Map<String, Object?>>> reminders() =>
      db.query('reminders', orderBy: 'due_at ASC');

  Future<List<Map<String, Object?>>> memories() =>
      db.query('memories', orderBy: 'rowid DESC');

  Future<List<Map<String, Object?>>> games() =>
      db.query('games', orderBy: 'played_at DESC');
}
