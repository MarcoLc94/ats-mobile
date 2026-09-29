import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apiBaseUrl = String.fromEnvironment('ATS_API_BASE_URL',
    defaultValue: 'https://api.productos-ats.com.mx/api/mobile/v1');

class ApiException implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic>? body;
  ApiException(this.status, this.message, [this.body]);
  @override
  String toString() => message;
}

Map<String, dynamic> asMap(dynamic value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

class AtsSession extends ChangeNotifier {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final _client = http.Client();
  final _auth = LocalAuthentication();
  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessExpiresAt;
  Future<void>? _refreshing;
  Map<String, dynamic>? user;
  bool biometricEnabled = false;
  bool unlocked = false;
  bool initialized = false;

  bool get signedIn => unlocked && user != null && _refreshToken != null;
  bool get canUnlock => biometricEnabled && _refreshToken != null;
  bool get canRestore => _refreshToken != null && !biometricEnabled;
  String get displayName {
    final first = user?['first_name']?.toString() ?? '';
    final last = user?['last_name']?.toString() ?? '';
    return '$first $last'.trim().isEmpty
        ? (user?['email']?.toString() ?? '')
        : '$first $last'.trim();
  }

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      biometricEnabled = prefs.getBool('biometric_enabled') ?? false;
      _refreshToken = await _storage.read(key: 'refresh_token');
      final storedUser = await _storage.read(key: 'user');
      if (storedUser != null) user = asMap(jsonDecode(storedUser));
      if (_refreshToken != null && !biometricEnabled) {
        await refresh();
        unlocked = true;
      }
    } on ApiException catch (error) {
      if (error.status == 401) await clearLocal();
    } catch (_) {
      // Keep credentials and drafts if the network is temporarily unavailable.
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<bool> unlockBiometric() async {
    if (!biometricEnabled || _refreshToken == null) return false;
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final verified = await _auth.authenticate(
        localizedReason: 'Desbloquea tu sesión de ATS',
        options:
            const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
      if (!verified) return false;
      await refresh();
      unlocked = true;
      notifyListeners();
      return signedIn;
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometrics(bool enabled) async {
    if (enabled) {
      final available = await _auth.canCheckBiometrics;
      if (!available ||
          !await _auth.authenticate(
            localizedReason: 'Confirma la activación de acceso biométrico',
            options: const AuthenticationOptions(biometricOnly: true),
          )) {
        throw ApiException(
            0, 'Configura la biometría en Android para activarla.');
      }
    }
    biometricEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', enabled);
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    final result = await request('POST', '/session', auth: false, body: {
      'email': email.trim().toLowerCase(),
      'password': password,
      'device_name': 'ATS Android',
    });
    await _saveTokens(asMap(result));
    unlocked = true;
    notifyListeners();
  }

  Future<void> restore() async {
    await refresh();
    unlocked = true;
    notifyListeners();
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    final newRefreshToken = data['refresh_token']?.toString();
    if (newRefreshToken == null || newRefreshToken.isEmpty) {
      throw ApiException(0, 'La respuesta de sesión está incompleta.');
    }
    // Persist the rotated token before any concurrent request can use it.
    await _storage.write(key: 'refresh_token', value: newRefreshToken);
    _refreshToken = newRefreshToken;
    _accessToken = data['access_token']?.toString();
    _accessExpiresAt = DateTime.now()
        .add(Duration(seconds: (data['expires_in'] as num?)?.toInt() ?? 900));
    user = asMap(data['user']);
    await _storage.write(key: 'user', value: jsonEncode(user));
  }

  Future<void> refresh() async {
    final active = _refreshing;
    if (active != null) return active;
    final operation = _doRefresh();
    _refreshing = operation;
    try {
      await operation;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _doRefresh() async {
    final token = _refreshToken;
    if (token == null) throw ApiException(401, 'Inicia sesión de nuevo.');
    try {
      final result = await request('POST', '/session/refresh',
          auth: false, body: {'refresh_token': token});
      await _saveTokens(asMap(result));
      notifyListeners();
    } on ApiException catch (error) {
      if (error.status == 401) await clearLocal();
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      if (_refreshToken != null && _accessToken == null) await refresh();
      await request('DELETE', '/session',
          body: {'refresh_token': _refreshToken});
    } catch (_) {
      // Local logout always wins, including when the device is offline.
    } finally {
      await clearLocal();
    }
  }

  Future<void> clearLocal() async {
    _accessToken = null;
    _refreshToken = null;
    _accessExpiresAt = null;
    user = null;
    unlocked = false;
    biometricEnabled = false;
    await _storage.deleteAll();
    final support = await getApplicationSupportDirectory();
    final draftFiles = Directory('${support.path}/ats-order-drafts');
    if (await draftFiles.exists()) await draftFiles.delete(recursive: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('biometric_enabled');
    notifyListeners();
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(apiBaseUrl);
    if (base.scheme != 'https') {
      throw ApiException(0, 'La API debe usar HTTPS.');
    }
    return base.replace(
        path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
        queryParameters: query);
  }

  Future<dynamic> request(String method, String path,
      {Map<String, String>? query,
      Object? body,
      bool auth = true,
      bool retry = true}) async {
    if (auth &&
        (_accessToken == null ||
            (_accessExpiresAt?.isBefore(
                    DateTime.now().add(const Duration(seconds: 30))) ??
                true))) {
      await refresh();
    }
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (auth) headers['Authorization'] = 'Bearer $_accessToken';
    http.Response response;
    try {
      final req = http.Request(method, _uri(path, query))
        ..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      response = await http.Response.fromStream(
          await _client.send(req).timeout(const Duration(seconds: 25)));
    } on SocketException {
      throw ApiException(
          0, 'Sin conexión. Conservamos tu borrador en el dispositivo.');
    } on TimeoutException {
      throw ApiException(0, 'La conexión tardó demasiado. Inténtalo de nuevo.');
    }
    if (response.statusCode == 401 && auth && retry) {
      await refresh();
      return request(method, path,
          query: query, body: body, auth: auth, retry: false);
    }
    if (response.statusCode == 204) return null;
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      data = null;
    }
    if (response.statusCode >= 400) {
      final parsed = asMap(data);
      throw ApiException(
          response.statusCode,
          parsed['error']?.toString() ??
              parsed['errors']?.toString() ??
              'Error ${response.statusCode}',
          parsed);
    }
    return data;
  }

  Future<dynamic> uploadOrder(int id, Map<String, String> fields,
      {File? technicianSignature,
      File? clientSignature,
      List<File> photos = const []}) async {
    if (_accessToken == null ||
        (_accessExpiresAt
                ?.isBefore(DateTime.now().add(const Duration(seconds: 30))) ??
            true)) {
      await refresh();
    }
    final request = http.MultipartRequest('PATCH', _uri('/service_orders/$id'))
      ..headers['Authorization'] = 'Bearer $_accessToken'
      ..headers['Accept'] = 'application/json';
    for (final entry in fields.entries) {
      request.fields['service_order[${entry.key}]'] = entry.value;
    }
    if (technicianSignature != null) {
      request.files.add(await http.MultipartFile.fromPath(
          'service_order[technician_signature]', technicianSignature.path,
          contentType: MediaType('image', 'png')));
    }
    if (clientSignature != null) {
      request.files.add(await http.MultipartFile.fromPath(
          'service_order[client_signature]', clientSignature.path,
          contentType: MediaType('image', 'png')));
    }
    for (final photo in photos) {
      final extension = photo.path.split('.').last.toLowerCase();
      final subtype = extension == 'png'
          ? 'png'
          : extension == 'webp'
              ? 'webp'
              : 'jpeg';
      request.files.add(await http.MultipartFile.fromPath(
          'service_order[service_photos][]', photo.path,
          contentType: MediaType('image', subtype)));
    }
    final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 90)));
    final data = asMap(jsonDecode(response.body));
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode,
          data['error']?.toString() ?? 'No se pudo guardar la orden.', data);
    }
    return data;
  }

  Future<void> saveCache(String key, Object value) =>
      _storage.write(key: 'cache:$key', value: jsonEncode(value));
  Future<dynamic> readCache(String key) async {
    final raw = await _storage.read(key: 'cache:$key');
    return raw == null ? null : jsonDecode(raw);
  }
}
