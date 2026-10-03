import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import '../models/models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin, explicit wrapper over the DCOV REST API. Every method maps to one
/// endpoint in backend/app/api/*.py; see docs there for the authoritative
/// contract (also served live at `<baseUrl>/api/docs`).
class DcovApiClient {
  String baseUrl;
  String? accessToken;
  final http.Client _http;
  final Duration timeout;

  DcovApiClient({required this.baseUrl, this.accessToken, http.Client? client,
      this.timeout = const Duration(seconds: 15)})
      : _http = client ?? http.Client();

  Uri _u(String path, [Map<String, dynamic>? query]) {
    if (baseUrl.trim().isEmpty) {
      throw ApiException(0, 'No server address set. Open Settings and enter the address '
          'of the DCOV server (for example http://192.168.1.20:8000).');
    }
    final clean = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    // Real bug caught by `flutter analyze`, not just a lint: the old version
    // was `query?.map(...)..removeWhere(...)` - the `..removeWhere` cascade
    // does not inherit the `?.`'s null-safety, so a null `query` would have
    // thrown at runtime the first time any endpoint was called with no
    // query parameters. Written out explicitly instead of clever-cascaded.
    Map<String, String>? qp;
    if (query != null) {
      qp = query.map((k, v) => MapEntry(k, v?.toString() ?? ''));
      qp.removeWhere((k, v) => v.isEmpty);
    }
    return Uri.parse('$clean/api/v1$path').replace(queryParameters: qp?.isEmpty == true ? null : qp);
  }

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      };

  Future<dynamic> _decode(http.Response r) async {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.bodyBytes.isEmpty) return null;
      return jsonDecode(utf8.decode(r.bodyBytes));
    }
    String message = 'HTTP ${r.statusCode}';
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      message = body['detail']?.toString() ?? message;
    } catch (_) {/* non-JSON error body */}
    throw ApiException(r.statusCode, message);
  }

  // ------------------------------------------------------------ health -- //
  String get _root => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// Unauthenticated liveness probe. Short timeout on purpose: this decides
  /// whether the app shows ONLINE or OFFLINE, and a field user should not wait
  /// 15 s to find out the server is unreachable.
  Future<Map<String, dynamic>> health({Duration? within}) async =>
      await _decode(await _http.get(Uri.parse('$_root/health'))
          .timeout(within ?? const Duration(seconds: 4))) as Map<String, dynamic>;

  // -------------------------------------------------------------- auth -- //
  Future<Session> login(String username, String password, String deviceId) async {
    final r = await _http
        .post(_u('/auth/login'), headers: _headers(),
            body: jsonEncode({'username': username, 'password': password, 'device_id': deviceId}))
        .timeout(timeout);
    final body = await _decode(r) as Map<String, dynamic>;
    accessToken = body['access_token'] as String;
    final me = await this.me();
    return Session(
      userId: me['id'] as String, username: me['username'] as String,
      role: body['role'] as String, accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: (body['expires_in'] as int?) ?? 1800)),
      mustChangePassword: body['must_change_password'] == true,
    );
  }

  Future<Session> loginPin(String username, String pin, String deviceId) async {
    final r = await _http
        .post(_u('/auth/login/pin'), headers: _headers(),
            body: jsonEncode({'username': username, 'pin': pin, 'device_id': deviceId}))
        .timeout(timeout);
    final body = await _decode(r) as Map<String, dynamic>;
    accessToken = body['access_token'] as String;
    final me = await this.me();
    return Session(
      userId: me['id'] as String, username: me['username'] as String,
      role: body['role'] as String, accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: (body['expires_in'] as int?) ?? 1800)),
    );
  }

  /// Enrolls a PIN for quick unlock on *this* device. Requires an existing
  /// password-authenticated session - the server only accepts PIN login
  /// afterward from a device_id that reached this endpoint via that session,
  /// see backend/app/api/auth.py's trusted_device_ids handling.
  Future<void> setPin(String pin) async {
    final r = await _http
        .post(_u('/auth/pin'), headers: _headers(), body: jsonEncode({'pin': pin}))
        .timeout(timeout);
    await _decode(r);
  }

  /// Exchanges the refresh token for a new pair (body form - see
  /// backend/app/api/auth.py refresh()). Keeps identity from [previous].
  Future<Session> refresh(Session previous) async {
    final r = await _http
        .post(_u('/auth/refresh'), headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': previous.refreshToken}))
        .timeout(timeout);
    final body = await _decode(r) as Map<String, dynamic>;
    accessToken = body['access_token'] as String;
    return Session(
      userId: previous.userId, username: previous.username,
      role: body['role'] as String? ?? previous.role,
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: (body['expires_in'] as int?) ?? 1800)),
      mustChangePassword: body['must_change_password'] == true,
    );
  }

  Future<void> changePassword(String current, String next) async {
    final r = await _http
        .post(_u('/auth/password'), headers: _headers(),
            body: jsonEncode({'current_password': current, 'new_password': next}))
        .timeout(timeout);
    await _decode(r);
  }

  Future<Map<String, dynamic>> me() async => await _decode(
      await _http.get(_u('/auth/me'), headers: _headers()).timeout(timeout))
      as Map<String, dynamic>;

  Future<void> logout() async {
    try {
      await _http.post(_u('/auth/logout'), headers: _headers()).timeout(timeout);
    } catch (_) {/* best effort - local session is cleared regardless */}
  }

  // -------------------------------------------------------------- scan -- //
  Future<Map<String, dynamic>> scan({
    required String clientUuid, required String inputMode, required String rawInput,
    String ocrText = '', String? inspectionId, String deviceId = '',
    double? latitude, double? longitude, String locationLabel = '',
    String imageRef = '', String barcodeSymbology = '', String? scannedAt,
    String appVersion = '',
  }) async {
    final r = await _http
        .post(_u('/scan'), headers: _headers(), body: jsonEncode({
          'client_uuid': clientUuid, 'input_mode': inputMode, 'raw_input': rawInput,
          'ocr_text': ocrText, if (inspectionId != null) 'inspection_id': inspectionId,
          'device_id': deviceId, if (latitude != null) 'latitude': latitude,
          if (longitude != null) 'longitude': longitude, 'location_label': locationLabel,
          if (imageRef.isNotEmpty) 'image_ref': imageRef,
          if (barcodeSymbology.isNotEmpty) 'barcode_symbology': barcodeSymbology,
          if (scannedAt != null) 'scanned_at': scannedAt,
          if (appVersion.isNotEmpty) 'app_version': appVersion,
        }))
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> scanImage({
    required String clientUuid, required Uint8List imageBytes, required String filename,
    bool multiChip = false, String deviceId = '', bool autoLookup = true,
    String? inspectionId,
  }) async {
    final req = http.MultipartRequest('POST', _u('/scan/ocr'));
    if (accessToken != null) req.headers['Authorization'] = 'Bearer $accessToken';
    req.fields['client_uuid'] = clientUuid;
    req.fields['multi_chip'] = multiChip.toString();
    req.fields['device_id'] = deviceId;
    // false = OCR only: the inspector confirms/corrects the marking and the
    // app then records ONE scan via /scan with image_ref. true made the
    // server record a scan for the raw OCR guess AND the app record a second
    // one for the confirmed marking - two audit records per photo.
    req.fields['auto_lookup'] = autoLookup.toString();
    if (inspectionId != null) req.fields['inspection_id'] = inspectionId;
    req.files.add(http.MultipartFile.fromBytes('image', imageBytes, filename: filename,
        contentType: MediaType('image', 'jpeg')));
    final streamed = await _http.send(req).timeout(const Duration(seconds: 90));
    final r = await http.Response.fromStream(streamed);
    return await _decode(r) as Map<String, dynamic>;
  }

  /// Uploads scans captured offline in one round trip. The server treats a
  /// client_uuid it has already stored as a duplicate (never re-inserted), so
  /// retrying after a dropped connection is safe.
  Future<Map<String, dynamic>> syncPush(String deviceId, List<Map<String, dynamic>> scans) async {
    final r = await _http
        .post(_u('/sync/push'), headers: _headers(),
            body: jsonEncode({'device_id': deviceId, 'scans': scans}))
        .timeout(const Duration(seconds: 60));
    return await _decode(r) as Map<String, dynamic>;
  }

  // --------------------------------------------------------- catalogue -- //
  /// Pulls the full live catalogue for the offline cache. Fine at hundreds
  /// to low thousands of rows; at real scale this should switch to the
  /// paginated /sync/pull delta endpoint instead of a full refetch.
  Future<List<Map<String, dynamic>>> fetchAllComponents() async {
    final r = await _http
        .get(_u('/components', {'page': '1', 'page_size': '100000'}), headers: _headers())
        .timeout(const Duration(seconds: 60));
    final body = await _decode(r) as Map<String, dynamic>;
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> dashboard() async => await _decode(
      await _http.get(_u('/dashboard'), headers: _headers()).timeout(timeout))
      as Map<String, dynamic>;

  /// Trends, leaderboards and heat-map source data behind the Analytics
  /// screen - a superset of dashboard(), which only has today's/7-day
  /// counters. See backend/app/api/insights.py's analytics() for the exact
  /// response shape (result_mix, trend_monthly, top_manufacturers,
  /// most_detected_chinese, unknown_components, heatmap, ...).
  Future<Map<String, dynamic>> analytics({int days = 90}) async => await _decode(
      await _http.get(_u('/analytics', {'days': '$days'}), headers: _headers())
          .timeout(timeout)) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> scanHistory({int days = 30, int pageSize = 100}) async {
    final r = await _http
        .get(_u('/scan/history', {'days': '$days', 'page_size': '$pageSize'}), headers: _headers())
        .timeout(timeout);
    final body = await _decode(r) as Map<String, dynamic>;
    return (body['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<Uint8List> report(String key, {String fmt = 'pdf', int days = 30,
      String? inspectionId}) async {
    final params = {'fmt': fmt, 'days': '$days',
      if (inspectionId != null) 'inspection_id': inspectionId};
    final r = await _http
        .get(_u('/reports/$key', params), headers: _headers())
        .timeout(const Duration(seconds: 30));
    if (r.statusCode >= 200 && r.statusCode < 300) return r.bodyBytes;
    // Same error-message extraction as _decode, but _decode assumes a JSON
    // body and this endpoint's happy path is raw bytes (a PDF/XLSX/CSV), so
    // it can't just call _decode(r) - only the failure path is JSON here.
    String message = 'Report generation failed (HTTP ${r.statusCode})';
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      message = body['detail']?.toString() ?? message;
    } catch (_) {/* non-JSON error body */}
    throw ApiException(r.statusCode, message);
  }

  // -------------------------------------------------------- inspections -- //
  Future<Map<String, dynamic>> createInspection({
    String title = '', String platform = '', String serialNumber = '',
    String location = '', double? latitude, double? longitude, String remarks = '',
  }) async {
    final r = await _http
        .post(_u('/inspections'), headers: _headers(), body: jsonEncode({
          'title': title, 'platform': platform, 'serial_number': serialNumber,
          'location': location, if (latitude != null) 'latitude': latitude,
          if (longitude != null) 'longitude': longitude, 'remarks': remarks,
        }))
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listInspections(
      {String? statusFilter, bool mine = false}) async {
    final params = {if (statusFilter != null) 'status_filter': statusFilter,
      if (mine) 'mine': 'true'};
    final r = await _http
        .get(_u('/inspections', params), headers: _headers()).timeout(timeout);
    return (await _decode(r) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getInspection(String id) async => await _decode(
      await _http.get(_u('/inspections/$id'), headers: _headers()).timeout(timeout))
      as Map<String, dynamic>;

  /// `confirm: true` mirrors the backend's InspectionSign schema, which
  /// requires it as a literal - a lightweight guard against a client
  /// accidentally firing a sign request with no deliberate user action
  /// behind it. Signing is final: the backend rejects a second sign attempt
  /// on the same inspection with a 409.
  Future<Map<String, dynamic>> signInspection(String id,
      {required String verdict, String remarks = ''}) async {
    final r = await _http
        .post(_u('/inspections/$id/sign'), headers: _headers(), body: jsonEncode({
          'verdict': verdict, 'remarks': remarks, 'confirm': true,
        }))
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  // ------------------------------------------------------ import wizard -- //
  /// Step 1 of 2: parses, maps, validates, diffs against the live catalogue.
  /// Writes nothing - see backend/app/api/catalog.py's stage_import. The
  /// returned preview's `warnings` field is where an origin-verdict flip
  /// gets surfaced; import_screen.dart is written to make that impossible
  /// to scroll past without seeing it.
  Future<Map<String, dynamic>> stageImport(Uint8List fileBytes, String filename,
      {String? sheet}) async {
    final req = http.MultipartRequest('POST', _u('/database/import/stage',
        sheet != null ? {'sheet': sheet} : null));
    if (accessToken != null) req.headers['Authorization'] = 'Bearer $accessToken';
    req.files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: filename));
    final streamed = await _http.send(req).timeout(const Duration(seconds: 60));
    final r = await http.Response.fromStream(streamed);
    return await _decode(r) as Map<String, dynamic>;
  }

  /// Step 2 of 2. `confirm: true` is required by the backend's ImportCommit
  /// schema for the same reason as signInspection's - see there.
  Future<Map<String, dynamic>> commitImport(String batchId, {
    bool applyNew = true, bool applyUpdates = true, bool softDeleteMissing = false,
  }) async {
    final r = await _http
        .post(_u('/database/import/commit'), headers: _headers(), body: jsonEncode({
          'batch_id': batchId, 'apply_new': applyNew, 'apply_updates': applyUpdates,
          'soft_delete_missing': softDeleteMissing, 'confirm': true,
        }))
        .timeout(const Duration(seconds: 60));
    return await _decode(r) as Map<String, dynamic>;
  }

  /// Undoes a committed batch by replaying its revision snapshots in
  /// reverse - rows it created are removed, rows it modified are restored.
  /// Only a committed batch can be rolled back; staged-but-never-committed
  /// batches need no undo, they were never applied.
  Future<Map<String, dynamic>> rollbackImport(String batchId, String reason) async {
    final r = await _http
        .post(_u('/database/import/$batchId/rollback', {'reason': reason}),
            headers: _headers())
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> importHistory() async {
    final r = await _http.get(_u('/database/imports'), headers: _headers()).timeout(timeout);
    return (await _decode(r) as List).cast<Map<String, dynamic>>();
  }

  // ------------------------------------------------------- user admin -- //
  Future<List<Map<String, dynamic>>> listUsers() async {
    final r = await _http.get(_u('/auth/users'), headers: _headers()).timeout(timeout);
    return (await _decode(r) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createUser({
    required String username, required String password,
    String fullName = '', String unit = '', String role = 'viewer',
  }) async {
    final r = await _http
        .post(_u('/auth/users'), headers: _headers(), body: jsonEncode({
          'username': username, 'password': password, 'full_name': fullName,
          'unit': unit, 'role': role,
        }))
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setUserRole(String userId, String role) async {
    final r = await _http
        .patch(_u('/auth/users/$userId/role', {'role': role}), headers: _headers())
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setUserActive(String userId, bool isActive) async {
    final r = await _http
        .patch(_u('/auth/users/$userId/active', {'is_active': '$isActive'}), headers: _headers())
        .timeout(timeout);
    return await _decode(r) as Map<String, dynamic>;
  }

  void close() => _http.close();
}
