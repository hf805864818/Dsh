/// Mobile Gateway wire vocabulary: frame types, close codes and the error
/// frame the host sends instead of a reply.
///
/// Requests are `{"type": "<request>", ...params}`; replies and pushes are
/// `{"kind": "<kind>", ...}`. Everything is a UTF-8 JSON text frame.
///
/// Protocol reference: `dsh-plugin-mobile-gateway` `PROTOCOL.md` § 1.
library;

/// Sub-protocol negotiated with the gateway (`hello.protocol`).
const int kGatewayProtocol = 3;

/// The only sub-protocol the gateway echoes back.
const String kGatewaySubprotocol = 'dsh-mobile-v1';

/// Pairing sub-protocol prefix (`dsh-pair.<pairingCode>`).
const String kGatewayPairSubprotocolPrefix = 'dsh-pair.';

/// Long-lived device token sub-protocol prefix (`dsh-auth.<token>`).
const String kGatewayAuthSubprotocolPrefix = 'dsh-auth.';

/// Install-level device id sub-protocol prefix (`dsh-device.<clientDeviceId>`).
const String kGatewayDeviceSubprotocolPrefix = 'dsh-device.';

/// Device display name sub-protocol prefix (`dsh-device-name.<base64url>`).
const String kGatewayDeviceNameSubprotocolPrefix = 'dsh-device-name.';

/// WebSocket path every gateway endpoint serves.
const String kGatewayPath = '/ws/mobile';

/// Request frame types the client sends.
abstract final class GatewayRequest {
  static const String sessions = 'sessions';
  static const String history = 'history';
  static const String message = 'message';
  static const String subscribe = 'subscribe';
  static const String unsubscribe = 'unsubscribe';
  static const String ping = 'ping';
  static const String attachment = 'attachment';
  static const String search = 'search';
  static const String sessionArchive = 'session-archive';
  static const String sessionRename = 'session-rename';
  static const String sessionCancel = 'session-cancel';
  static const String tasks = 'tasks';
  static const String goal = 'goal';
  static const String sessionStats = 'session-stats';
  static const String contextUsage = 'context-usage';
  static const String commandsMenu = 'commands';
  static const String skillsMenu = 'skills';
  static const String approvalResponse = 'approval-response';
  static const String questionAnswer = 'question-answer';
  static const String questionCancel = 'question-cancel';
  static const String models = 'models';
  static const String selectModel = 'select-model';
  static const String providers = 'providers';
  static const String commands = 'commands';
  static const String commandExecute = 'command-execute';
  static const String permissionOptions = 'permission-options';
  static const String permission = 'permission';
  static const String tasksList = 'tasks';
  static const String goalInfo = 'goal';
  static const String fork = 'fork';
  static const String queueUpdate = 'queue-update';
  static const String workspaces = 'workspaces';
  static const String sessionCreate = 'session-create';
  static const String directories = 'directories';
  static const String workspaceCreate = 'workspace-create';
  static const String directoryCreate = 'directory-create';
  static const String fileUploadOpen = 'file-upload-open';
  static const String fileUploadChunk = 'file-upload-chunk';
  static const String fileUploadFinish = 'file-upload-finish';
  static const String fileResolve = 'file-resolve';
  static const String fileDownloadOpen = 'file-download-open';
  static const String fileDownloadRead = 'file-download-read';
  static const String fileDownloadCancel = 'file-download-cancel';
  static const String scheduleCatalog = 'schedule-catalog';
  static const String speechCatalog = 'speech-catalog';
  static const String speechTranscribe = 'speech-transcribe';
  static const String speechConfigure = 'speech-configure';
  static const String speechPrepare = 'speech-prepare';
  static const String speechCancelPreparation = 'speech-cancel-preparation';
}

/// Reply / push frame kinds the host sends.
abstract final class GatewayKind {
  static const String hello = 'hello';
  static const String paired = 'paired';
  static const String error = 'error';
  static const String pong = 'pong';
  static const String sessions = 'sessions';
  static const String history = 'history';
  static const String sent = 'sent';
  static const String subscribed = 'subscribed';
  static const String event = 'event';
  static const String sessionSnapshot = 'session-snapshot';
  static const String sessionArchived = 'session-archived';
  static const String sessionArchives = 'session-archives';
  static const String sessionRenamed = 'session-renamed';
  static const String sessionTitleChanged = 'session-title-changed';
  static const String sessionCancelled = 'session-cancelled';
  static const String questionRequested = 'question-requested';
  static const String questionResolved = 'question-resolved';
  static const String models = 'models';
  static const String selectModel = 'select-model';
  static const String providers = 'providers';
  static const String approvalRequested = 'approval-requested';
  static const String approvalResolved = 'approval-resolved';
  static const String questionResponse = 'question-response';
  static const String search = 'search';
  static const String fileUploadOpened = 'file-upload-opened';
  static const String fileUploadChunkAccepted = 'file-upload-chunk-accepted';
  static const String fileUploadCompleted = 'file-upload-completed';
  static const String fileDownloadOpened = 'file-download-opened';
  static const String fileDownloadChunk = 'file-download-chunk';
  static const String fileList = 'file-list';
  static const String fileResolved = 'file-resolved';
  static const String scheduleCatalog = 'schedule-catalog';
  static const String speechCatalog = 'speech-catalog';
  static const String speechTranscribe = 'speech-transcribe';
  static const String speechConfigure = 'speech-configure';
  static const String speechPrepare = 'speech-prepare';
  static const String speechCancelPreparation = 'speech-cancel-preparation';
}

/// Gateway close codes that need a specific reaction.
abstract final class GatewayClose {
  /// Normal close.
  static const int normal = 1000;

  /// Device authentication was turned back on: retry with the token, or pair
  /// again when the token is also refused.
  static const int authRequired = 4003;

  /// The mobile gateway was switched off: stop reconnecting automatically.
  static const int gatewayDisabled = 4004;
}

/// A gateway `error` frame, or an hoisted transport failure.
///
/// [code] mirrors the host vocabulary (`bad-request`, `session-not-found`,
/// `agent-busy`, `internal`, …) or a client-side code from
/// [GatewayFailureCode].
class GatewayError implements Exception {
  const GatewayError(this.code, this.message, {this.requestType, this.sessionId, this.details});

  final String code;
  final String message;

  /// The request type that failed, when the host reported one.
  final String? requestType;

  /// The session involved, when the host reported one.
  final String? sessionId;

  final Object? details;

  /// Whether retrying the same call could succeed.
  bool get retryable => switch (code) {
        'agent-busy' || 'internal' || 'unavailable' => true,
        GatewayFailureCode.timeout || GatewayFailureCode.disconnected => true,
        _ => false,
      };

  /// Builds from a decoded `kind == "error"` frame.
  factory GatewayError.fromFrame(Map<String, Object?> frame) => GatewayError(
        _str(frame['code']) ?? 'unknown',
        _str(frame['message']) ?? 'The gateway returned an error without a message.',
        requestType: _str(frame['requestType']),
        sessionId: _str(frame['sessionId']),
        details: frame['details'],
      );

  @override
  String toString() => 'GatewayError($code): $message';

  static String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;
}

/// Client-side failure codes that do not come from the host.
abstract final class GatewayFailureCode {
  /// The pair/connect handshake did not finish in time.
  static const String timeout = 'gateway/timeout';

  /// The socket dropped while a request was in flight.
  static const String disconnected = 'gateway/disconnected';

  /// `hello.protocol` is not [kGatewayProtocol].
  static const String protocolMismatch = 'gateway/protocol-mismatch';

  /// The gateway closed with [GatewayClose.gatewayDisabled].
  static const String gatewayDisabled = 'gateway/disabled';

  /// The gateway asked for authentication again ([GatewayClose.authRequired]).
  static const String authRequired = 'gateway/auth-required';

  /// Nothing in `endpoints` answered.
  static const String unreachable = 'gateway/unreachable';
}

/// Reads a `Map<String, Object?>` out of a decoded frame field.
Map<String, Object?>? asGatewayMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return <String, Object?>{for (final entry in value.entries) '${entry.key}': entry.value};
  }
  return null;
}

/// Reads a `List<Map<String, Object?>>` out of a decoded frame field.
List<Map<String, Object?>> asGatewayMaps(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  final out = <Map<String, Object?>>[];
  for (final entry in value) {
    final map = asGatewayMap(entry);
    if (map != null) out.add(map);
  }
  return out;
}

/// Reads a string field, trimming nothing and rejecting non-strings.
String? gatewayString(Map<String, Object?> frame, String key) {
  final value = frame[key];
  return value is String ? value : null;
}

/// Reads an int field (tolerates doubles and numeric strings).
int? gatewayInt(Map<String, Object?> frame, String key) {
  final value = frame[key];
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Reads a bool field.
bool gatewayBool(Map<String, Object?> frame, String key, {bool fallback = false}) {
  final value = frame[key];
  return value is bool ? value : fallback;
}
