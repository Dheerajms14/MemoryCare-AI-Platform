import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_store.dart';

class ServerApi {
  ServerApi(this.baseUrl);
  final String baseUrl;

  Future<Map<String, dynamic>> login(String username, String password) async {
    final response = await http
        .post(Uri.parse(baseUrl + '/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Login failed (' + response.statusCode.toString() + ')');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Server confirms IDs after committing the whole batch; only then delete them.
  Future<int> sync(LocalStore local, String token) async {
    var uploaded = 0;
    while (true) {
      final rows = await local.pending();
      if (rows.isEmpty) return uploaded;
      final sentIds = rows.map((row) => row['op_id'] as String).toSet();
      final operations = rows
          .map((row) => {
                'id': row['op_id'],
                'kind': row['kind'],
                'payload': jsonDecode(row['payload_json'] as String),
              })
          .toList();
      final response = await http
          .post(Uri.parse(baseUrl + '/sync'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + token,
              },
              body: jsonEncode({'operations': operations}))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('Sync failed (' + response.statusCode.toString() + '): ' +
            response.body);
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ack = (data['acknowledged'] as List<dynamic>).cast<String>();
      if (ack.length != rows.length || ack.toSet().length != sentIds.length ||
          !ack.toSet().containsAll(sentIds)) {
        throw Exception('Server did not acknowledge the full batch.');
      }
      await local.acknowledge(ack);
      uploaded += ack.length;
    }
  }
}
