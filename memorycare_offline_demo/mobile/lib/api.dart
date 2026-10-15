import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'local_store.dart';
import 'auth_service.dart';

class SyncResult {
  const SyncResult({required this.operations, required this.media});

  final int operations;
  final int media;

  int get total => operations + media;
}

class ServerApi {
  ServerApi(this.baseUrl, this.auth);

  final String baseUrl;
  final AuthClient auth;

  /// The server acknowledges operation IDs only after committing a complete
  /// transaction. Local outbox rows are removed only after that acknowledgement.
  Future<SyncResult> sync(LocalStore local) async {
    var uploadedOperations = 0;
    var uploadedMedia = 0;
    while (true) {
      final rows = await local.pending();
      if (rows.isEmpty) break;
      final sentIds = rows.map((row) => row['op_id'] as String).toSet();
      final operations = rows
          .map(
            (row) => {
              'id': row['op_id'],
              'kind': row['kind'],
              'payload': jsonDecode(row['payload_json'] as String),
            },
          )
          .toList();
      final data = await auth.post('/sync', {'operations': operations});
      final acknowledged = (data['acknowledged'] as List<dynamic>).cast<String>();
      final acknowledgedIds = acknowledged.toSet();
      if (acknowledged.length != rows.length ||
          acknowledgedIds.length != sentIds.length ||
          !acknowledgedIds.containsAll(sentIds)) {
        throw Exception('Server did not acknowledge the complete batch.');
      }
      await local.acknowledge(acknowledged);
      uploadedOperations += acknowledged.length;
    }

    // Media is uploaded only after the parent memory mutation is committed.
    for (final row in await local.pendingMedia()) {
      final path = row['local_path'] as String;
      if (!await File(path).exists()) {
        throw Exception('A local media file is missing. The upload remains pending.');
      }
      final memoryId = row['memory_id'] as String;
      final mediaType = row['media_type'] as String;
      Future<http.Response> upload() async {
        final token = await auth.freshAccessToken();
        final request = http.MultipartRequest('POST',
          Uri.parse('$baseUrl/memories/${Uri.encodeComponent(memoryId)}/media/$mediaType'));
        request.headers['Authorization'] = 'Bearer $token';
        request.files.add(await http.MultipartFile.fromPath('file', path));
        final streamed = await request.send().timeout(const Duration(seconds: 30));
        return http.Response.fromStream(streamed).timeout(const Duration(seconds: 30));
      }
      var response = await upload();
      if (response.statusCode == 401) { await auth.refresh(); response = await upload(); }
      checkedJson(response);
      await local.acknowledgeMedia(row['id'] as String);
      uploadedMedia++;
    }

    return SyncResult(operations: uploadedOperations, media: uploadedMedia);
  }
}
