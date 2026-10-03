import '../services/matching.dart' show ComponentRow;

class Component {
  final String componentId;
  final String componentName;
  final String partNumber;
  final String chipNumber;
  final String manufacturer;
  final String countryOfOrigin;
  final String isChinese; // YES | NO | UNKNOWN
  final String category;
  final String droneSubsystem;
  final String criticality;
  final String criticalityPolicy;
  final String alternativeManufacturer;
  final String militaryGrade;
  final String barcode;
  final String qrCode;
  final String function;
  final String remarks;
  final String datasheetUrl;
  final String supplier;
  final String verifiedBy;
  final String verificationSource;
  final double confidenceScore;

  Component({
    required this.componentId,
    required this.componentName,
    this.partNumber = '',
    this.chipNumber = '',
    this.manufacturer = '',
    this.countryOfOrigin = '',
    this.isChinese = 'UNKNOWN',
    this.category = '',
    this.droneSubsystem = '',
    this.criticality = 'REVIEW',
    this.criticalityPolicy = '',
    this.alternativeManufacturer = '',
    this.militaryGrade = 'NO',
    this.barcode = '',
    this.qrCode = '',
    this.function = '',
    this.remarks = '',
    this.datasheetUrl = '',
    this.supplier = '',
    this.verifiedBy = '',
    this.verificationSource = '',
    this.confidenceScore = 100,
  });

  factory Component.fromMap(Map<String, dynamic> m) => Component(
        componentId: m['component_id']?.toString() ?? '',
        componentName: m['component_name']?.toString() ?? '',
        partNumber: m['part_number']?.toString() ?? '',
        chipNumber: m['chip_number']?.toString() ?? '',
        manufacturer: m['manufacturer']?.toString() ?? '',
        countryOfOrigin: m['country_of_origin']?.toString() ?? '',
        isChinese: m['is_chinese']?.toString() ?? 'UNKNOWN',
        category: m['category']?.toString() ?? '',
        droneSubsystem: m['drone_subsystem']?.toString() ?? '',
        criticality: m['criticality']?.toString() ?? 'REVIEW',
        criticalityPolicy: m['criticality_policy']?.toString() ?? '',
        alternativeManufacturer: m['alternative_manufacturer']?.toString() ?? '',
        militaryGrade: m['military_grade']?.toString() ?? 'NO',
        barcode: m['barcode']?.toString() ?? '',
        qrCode: m['qr_code']?.toString() ?? '',
        function: m['function']?.toString() ?? '',
        remarks: m['remarks']?.toString() ?? '',
        datasheetUrl: m['datasheet_url']?.toString() ?? '',
        supplier: m['supplier']?.toString() ?? '',
        verifiedBy: m['verified_by']?.toString() ?? '',
        verificationSource: m['verification_source']?.toString() ?? '',
        confidenceScore: double.tryParse(m['confidence_score']?.toString() ?? '100') ?? 100,
      );

  ComponentRow toRow() => {
        'component_id': componentId, 'component_name': componentName,
        'part_number': partNumber, 'chip_number': chipNumber,
        'manufacturer': manufacturer, 'country_of_origin': countryOfOrigin,
        'is_chinese': isChinese, 'category': category,
        'drone_subsystem': droneSubsystem, 'criticality': criticality,
        'criticality_policy': criticalityPolicy,
        'alternative_manufacturer': alternativeManufacturer,
        'military_grade': militaryGrade, 'barcode': barcode, 'qr_code': qrCode,
        'function': function, 'remarks': remarks, 'datasheet_url': datasheetUrl,
        'supplier': supplier, 'verified_by': verifiedBy,
        'verification_source': verificationSource, 'confidence_score': confidenceScore,
      };

  List<String> get alternatives =>
      alternativeManufacturer.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

class HistoryEntry {
  final DateTime at;
  final String raw;
  final String normalized;
  final String result;
  final String method;
  final double score;
  final String componentId;
  final String componentName;
  final String mode; // manual | barcode | qr | ocr
  final bool synced;
  /// Idempotency key shared with the server record (ScanRecord.client_uuid).
  final String clientUuid;
  /// Server ScanRecord id once recorded centrally; empty until then.
  final String scanId;
  /// online_verified | pending_sync | local_only (not signed in)
  final String status;
  final String banner;
  final String operator;

  HistoryEntry({
    required this.at, required this.raw, required this.normalized,
    required this.result, required this.method, required this.score,
    this.componentId = '', this.componentName = '', this.mode = 'manual',
    this.synced = false, this.clientUuid = '', this.scanId = '',
    this.status = 'local_only', this.banner = '', this.operator = '',
  });

  HistoryEntry copyWith({bool? synced, String? scanId, String? status, String? result,
      String? banner}) => HistoryEntry(
        at: at, raw: raw, normalized: normalized, result: result ?? this.result,
        method: method, score: score, componentId: componentId,
        componentName: componentName, mode: mode, synced: synced ?? this.synced,
        clientUuid: clientUuid, scanId: scanId ?? this.scanId,
        status: status ?? this.status, banner: banner ?? this.banner, operator: operator,
      );

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(), 'raw': raw, 'normalized': normalized,
        'result': result, 'method': method, 'score': score,
        'component_id': componentId, 'component_name': componentName,
        'mode': mode, 'synced': synced, 'client_uuid': clientUuid,
        'scan_id': scanId, 'status': status, 'banner': banner, 'operator': operator,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        at: DateTime.parse(j['at'] as String), raw: j['raw'] as String,
        normalized: j['normalized'] as String, result: j['result'] as String,
        method: j['method'] as String,
        score: double.tryParse(j['score'].toString()) ?? 0,
        componentId: j['component_id'] as String? ?? '',
        componentName: j['component_name'] as String? ?? '',
        mode: j['mode'] as String? ?? 'manual',
        synced: j['synced'] as bool? ?? false,
        clientUuid: j['client_uuid'] as String? ?? '',
        scanId: j['scan_id'] as String? ?? '',
        status: j['status'] as String? ??
            ((j['synced'] as bool? ?? false) ? 'online_verified' : 'local_only'),
        banner: j['banner'] as String? ?? '',
        operator: j['operator'] as String? ?? '',
      );
}

/// In-app notification center entries. Deliberately in-app only, not push -
/// see docs/ROADMAP.md's Phase 3 note on why push (FCM/APNs, a backend
/// component to trigger it) is a separate, larger project than this.
/// `level` drives the icon/color in NotificationsScreen; `route` is an
/// optional hint for "tap to go there" (e.g. 'inspections', 'import') -
/// interpreted by home_shell.dart's navigation, not by this model.
class AppNotification {
  final String id;
  final DateTime at;
  final String level; // info | warning | error
  final String title;
  final String body;
  final String route;
  bool read;

  AppNotification({
    required this.id, required this.at, required this.level,
    required this.title, this.body = '', this.route = '', this.read = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id, 'at': at.toIso8601String(), 'level': level,
        'title': title, 'body': body, 'route': route, 'read': read,
      };

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String, at: DateTime.parse(j['at'] as String),
        level: j['level'] as String? ?? 'info', title: j['title'] as String,
        body: j['body'] as String? ?? '', route: j['route'] as String? ?? '',
        read: j['read'] as bool? ?? false,
      );
}

class Session {
  final String userId;
  final String username;
  final String role;
  final String accessToken;
  final String refreshToken;
  /// When the *access* token expires. The refresh token lasts days longer;
  /// an expired access token is renewed with it, not treated as a sign-out.
  final DateTime expiresAt;
  final bool mustChangePassword;
  Session({
    required this.userId, required this.username, required this.role,
    required this.accessToken, required this.refreshToken, required this.expiresAt,
    this.mustChangePassword = false,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'user_id': userId, 'username': username, 'role': role,
        'access_token': accessToken, 'refresh_token': refreshToken,
        'expires_at': expiresAt.toIso8601String(),
        'must_change_password': mustChangePassword,
      };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        userId: j['user_id'] as String, username: j['username'] as String,
        role: j['role'] as String, accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresAt: DateTime.parse(j['expires_at'] as String),
        mustChangePassword: j['must_change_password'] as bool? ?? false,
      );
}
