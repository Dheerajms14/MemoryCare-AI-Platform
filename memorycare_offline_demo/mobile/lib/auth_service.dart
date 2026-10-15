import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// HTTP is an explicit debug-only opt-in. Release apps must use HTTPS.
const allowLocalHttp = kDebugMode && bool.fromEnvironment('MEMORYCARE_ALLOW_HTTP', defaultValue: false);

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

String checkedServerUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty ||
      uri.hasQuery || uri.hasFragment || (uri.path.isNotEmpty && uri.path != '/')) {
    throw const AuthException('Enter a server origin such as https://memorycare.example.');
  }
  if (uri.scheme != 'https' && !(allowLocalHttp && uri.scheme == 'http')) {
    throw const AuthException('HTTPS is required. Local HTTP needs the explicit demo build flag.');
  }
  return input.trim().replaceAll(RegExp(r'/$'), '');
}

Map<String, dynamic> checkedJson(http.Response response) {
  dynamic value;
  try {
    value = jsonDecode(response.body);
  } catch (_) {
    throw AuthException('Server returned an unexpected response (${response.statusCode}).');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final detail = value is Map ? value['detail'] : null;
    final message = detail is String
        ? detail
        : detail is List
            ? detail.map((e) => e is Map ? e['msg'] : 'Invalid form field').join('\n')
            : 'Request failed (${response.statusCode}).';
    throw AuthException(message);
  }
  return Map<String, dynamic>.from(value as Map);
}

class AuthSessionData {
  const AuthSessionData({required this.server, required this.data});
  final String server;
  final Map<String, dynamic> data;
  String get userId => data['user_id'] as String;
  String get role => data['role'] as String;
  String get username => data['username'] as String;
  String get name => data['display_name'] as String;
  String get accessToken => data['access_token'] as String;
  String get refreshToken => data['refresh_token'] as String;
  int get accessExpiresAt => data['access_expires_at'] as int;
  int get refreshExpiresAt => data['refresh_expires_at'] as int;

  factory AuthSessionData.fromReply(String server, Map<String, dynamic> value) => AuthSessionData(
        server: server,
        data: {...value, 'access_expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + (value['expires_in'] as int)},
      );
}

class AuthClient {
  final FlutterSecureStorage _storage = FlutterSecureStorage();
  static const _key = 'memorycare_session_v21';
  AuthSessionData? session;
  Future<void>? _refreshing;

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return;
    try {
      final record = jsonDecode(raw) as Map<String, dynamic>;
      final restored = AuthSessionData(server: checkedServerUrl(record['server'] as String),
          data: Map<String, dynamic>.from(record['data'] as Map));
      if (restored.refreshExpiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        await clear();
      } else {
        session = restored;
      }
    } catch (_) {
      await clear();
    }
  }

  Future<Map<String, dynamic>> publicPost(String server, String route, Map<String, dynamic> body) async {
    final response = await http.post(Uri.parse('${checkedServerUrl(server)}$route'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 15));
    return checkedJson(response);
  }

  Future<AuthSessionData> signIn(String server, String username, String password, String role) async {
    final origin = checkedServerUrl(server);
    final reply = await publicPost(origin, '/auth/login', {
      'username': username, 'password': password, 'role': role,
    });
    return AuthSessionData.fromReply(origin, reply);
  }

  Future<void> save(AuthSessionData value) async {
    // One encrypted record avoids partially storing an access/refresh-token pair.
    await _storage.write(key: _key, value: jsonEncode({'server': value.server, 'data': value.data}));
    session = value;
  }

  Future<void> revokeCandidate(AuthSessionData value) async {
    try {
      await http.post(Uri.parse('${value.server}/auth/logout'),
          headers: {'Authorization': 'Bearer ${value.accessToken}'}).timeout(const Duration(seconds: 10));
    } catch (_) { /* Do not bind another account to the local patient records. */ }
  }

  Future<void> clear() async {
    session = null;
    await _storage.delete(key: _key);
  }

  Future<void> refresh() async {
    final existing = _refreshing;
    if (existing != null) return existing;
    final future = _rotate();
    _refreshing = future;
    try {
      await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _rotate() async {
    final current = session;
    if (current == null) throw const AuthException('Sign in again.');
    final response = await http.post(Uri.parse('${current.server}/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': current.refreshToken})).timeout(const Duration(seconds: 15));
    if (response.statusCode == 401) await clear();
    final reply = checkedJson(response);
    if (session?.userId == current.userId && session?.refreshToken == current.refreshToken) {
      await save(AuthSessionData.fromReply(current.server, reply));
    }
  }

  Future<String> freshAccessToken() async {
    if (session == null) throw const AuthException('Sign in again.');
    if (session!.accessExpiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) await refresh();
    final current = session;
    if (current == null) throw const AuthException('Sign in again.');
    return current.accessToken;
  }

  Future<http.Response> authorized(String method, String route, {Map<String, dynamic>? body}) async {
    if (!route.startsWith('/')) throw const AuthException('Invalid API route.');
    Future<http.Response> send() async {
      final token = await freshAccessToken();
      final current = session;
      if (current == null) throw const AuthException('Sign in again.');
      final request = http.Request(method, Uri.parse('${current.server}$route'));
      request.headers.addAll({'Content-Type': 'application/json', 'Authorization': 'Bearer $token'});
      if (body != null) request.body = jsonEncode(body);
      final streamed = await request.send().timeout(const Duration(seconds: 15));
      return http.Response.fromStream(streamed).timeout(const Duration(seconds: 15));
    }
    var reply = await send();
    if (reply.statusCode == 401) {
      await refresh();
      reply = await send();
    }
    return reply;
  }

  Future<Map<String, dynamic>> get(String route) async => checkedJson(await authorized('GET', route));
  Future<Map<String, dynamic>> post(String route, Map<String, dynamic> body) async =>
      checkedJson(await authorized('POST', route, body: body));

  Future<bool> logout() async {
    var revoked = false;
    try {
      final reply = await authorized('POST', '/auth/logout');
      revoked = reply.statusCode == 200;
    } catch (_) {
      // Without connectivity, only device logout is possible; report that honestly.
    } finally {
      await clear();
    }
    return revoked;
  }
}
