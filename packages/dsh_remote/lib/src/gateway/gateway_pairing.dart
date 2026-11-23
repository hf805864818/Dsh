/// Mobile Gateway pairing payload (`dsh-mobile-v1`, payload version 2).
///
/// The gateway hands out a Base64URL (no padding) string that decodes to a
/// small JSON object. The client must decode it strictly: only
/// `A-Z a-z 0-9 - _` are allowed, `=` padding, plain Base64 and raw JSON are
/// rejected, and both `version` and `expiresAt` are checked before use.
///
/// Protocol reference: `dsh-plugin-mobile-gateway` `PROTOCOL.md`
/// § "设备配对与鉴权 / 首次配对".
library;

import 'dart:convert';

/// Why a pairing string was rejected.
enum GatewayPairingErrorCode {
  /// Nothing to parse.
  empty,

  /// Characters outside `A-Z a-z 0-9 - _`, or an impossible length.
  notBase64Url,

  /// Base64URL decoded, but the bytes are not a JSON object.
  notJson,

  /// `version` is missing or not the supported version (2).
  unsupportedVersion,

  /// `publicUrl`, `pairingCode` or `expiresAt` is missing or malformed.
  missingField,

  /// The payload is well formed but past `expiresAt`.
  expired,
}

/// A rejected pairing string.
class GatewayPairingException implements Exception {
  const GatewayPairingException(this.code, this.message);

  final GatewayPairingErrorCode code;
  final String message;

  @override
  String toString() => 'GatewayPairingException(${code.name}): $message';
}

/// Decoded pairing payload.
///
/// [endpoints] is the gateway's advertised entry list (public URL first, at
/// most 16 entries). It never contains relay/TURN/WebRTC addresses: every
/// entry points at the same gateway's `/ws/mobile`.
class GatewayPairing {
  const GatewayPairing({
    required this.publicUrl,
    required this.pairingCode,
    required this.expiresAt,
    this.gatewayId,
    this.gatewayName,
    this.endpoints = const <Uri>[],
  });

  /// Supported payload version.
  static const int version = 2;

  /// The first entry the client should try.
  final Uri publicUrl;

  /// One-time pairing code (256-bit, Base64URL alphabet).
  final String pairingCode;

  /// Expiry as milliseconds since the Unix epoch.
  final int expiresAt;

  /// Stable gateway identity (UUID v4). Absent on payloads from older hosts.
  final String? gatewayId;

  /// Display name; never use it as an identity.
  final String? gatewayName;

  /// Every advertised entry, `publicUrl` first.
  final List<Uri> endpoints;

  /// When the code stops working.
  DateTime get expiresAtTime =>
      DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true).toLocal();

  /// Whether [now] is past [expiresAt].
  bool isExpired([DateTime? now]) =>
      (now ?? DateTime.now()).millisecondsSinceEpoch >= expiresAt;

  /// Entries worth trying, `publicUrl` first, de-duplicated, capped at 16.
  ///
  /// Plaintext `ws://` entries are kept: the caller decides whether a plaintext
  /// address is acceptable (gateway rules allow it for private/Tailscale
  /// addresses only).
  List<Uri> get candidates {
    final seen = <String>{};
    final out = <Uri>[];
    for (final uri in <Uri>[publicUrl, ...endpoints]) {
      if (out.length >= 16) break;
      final key = uri.toString();
      if (seen.add(key)) out.add(uri);
    }
    return List<Uri>.unmodifiable(out);
  }

  /// Human-readable host label for the UI (gateway name, else URL host).
  String get label {
    final name = gatewayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return publicUrl.host;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'publicUrl': publicUrl.toString(),
    'pairingCode': pairingCode,
    'expiresAt': expiresAt,
    if (gatewayId != null) 'gatewayId': gatewayId,
    if (gatewayName != null) 'gatewayName': gatewayName,
    if (endpoints.isNotEmpty)
      'endpoints': <String>[for (final uri in endpoints) uri.toString()],
  };

  /// Encodes to the exact string the QR code carries (Base64URL, no padding).
  String encode() => base64Url.encode(utf8.encode(jsonEncode(toJson()))).replaceAll('=', '');

  /// Parses a scanned / pasted pairing string.
  ///
  /// Throws [GatewayPairingException] on any problem, including expiry when
  /// [now] is past `expiresAt`.
  static GatewayPairing parse(String text, {DateTime? now}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.empty,
        'The pairing string is empty.',
      );
    }

    final bytes = _decodeStrict(trimmed);

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.notJson,
        'The pairing string does not contain JSON.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.notJson,
        'The pairing payload is not a JSON object.',
      );
    }

    final version = _intOf(decoded['version']);
    if (version != GatewayPairing.version) {
      throw GatewayPairingException(
        GatewayPairingErrorCode.unsupportedVersion,
        'Unsupported pairing payload version: ${decoded['version']}.',
      );
    }

    final publicUrl = _uriOf(decoded['publicUrl']);
    final pairingCode = _stringOf(decoded['pairingCode']);
    final expiresAt = _intOf(decoded['expiresAt']);
    if (publicUrl == null || pairingCode == null || pairingCode.isEmpty || expiresAt == null) {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.missingField,
        'The pairing payload is missing publicUrl, pairingCode or expiresAt.',
      );
    }
    if (publicUrl.scheme != 'wss' && publicUrl.scheme != 'ws') {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.missingField,
        'The pairing address must be a ws:// or wss:// URL.',
      );
    }

    final endpoints = <Uri>[];
    final rawEndpoints = decoded['endpoints'];
    if (rawEndpoints is List) {
      for (final entry in rawEndpoints) {
        final uri = _uriOf(entry);
        if (uri != null && (uri.scheme == 'wss' || uri.scheme == 'ws')) {
          endpoints.add(uri);
          if (endpoints.length >= 16) break;
        }
      }
    }

    final result = GatewayPairing(
      publicUrl: publicUrl,
      pairingCode: pairingCode,
      expiresAt: expiresAt,
      gatewayId: _stringOf(decoded['gatewayId']),
      gatewayName: _stringOf(decoded['gatewayName']),
      endpoints: List<Uri>.unmodifiable(endpoints),
    );

    if (result.isExpired(now)) {
      throw GatewayPairingException(
        GatewayPairingErrorCode.expired,
        'The pairing code expired at ${result.expiresAtTime}.',
      );
    }
    return result;
  }

  /// Strict Base64URL decoding: no padding, no `+`/`/`, no whitespace.
  static List<int> _decodeStrict(String text) {
    if (!_base64Url.hasMatch(text)) {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.notBase64Url,
        'The pairing string is not unpadded Base64URL.',
      );
    }
    final remainder = text.length % 4;
    if (remainder == 1) {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.notBase64Url,
        'The pairing string has an invalid length.',
      );
    }
    final padded = remainder == 0 ? text : text.padRight(text.length + (4 - remainder), '=');
    try {
      return base64Url.decode(padded);
    } on Object {
      throw const GatewayPairingException(
        GatewayPairingErrorCode.notBase64Url,
        'The pairing string could not be decoded.',
      );
    }
  }

  static final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');

  static String? _stringOf(Object? value) => value is String ? value : null;

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Uri? _uriOf(Object? value) {
    if (value is String) return Uri.tryParse(value);
    return null;
  }
}
