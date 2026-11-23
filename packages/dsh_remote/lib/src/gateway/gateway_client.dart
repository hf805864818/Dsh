/// One authenticated WebSocket to a Mobile Gateway (`/ws/mobile`).
///
/// The gateway speaks its own JSON frame vocabulary (`type` requests,
/// `kind` replies/pushes) and authenticates with a one-time pairing code or a
/// long-lived device token. It does **not** use Noise and it does **not** use
/// WebRTC: one socket carries control and data.
///
/// Protocol reference: `dsh-plugin-mobile-gateway` `PROTOCOL.md`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'gateway_frames.dart';

/// The device record the gateway hands out once per pairing.
class GatewayDevice {
  const GatewayDevice({required this.id, required this.name, required this.token});

  /// Server-side device id (the gateway's record id, not the client's id).
  final String id;

  /// Display name registered on the gateway.
  final String name;

  /// Long-lived bearer token. Store it in the Keychain, never in prefs.
  final String token;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'name': name, 'token': token};

  /// Reads a stored device record.
  static GatewayDevice? fromJson(Object? value) {
    final map = asGatewayMap(value);
    if (map == null) return null;
    final id = gatewayString(map, 'id');
    final token = gatewayString(map, 'token');
    if (id == null || token == null || token.isEmpty) return null;
    return GatewayDevice(id: id, name: gatewayString(map, 'name') ?? '', token: token);
  }
}

/// What `hello` announced about this connection.
class GatewayHandshake {
  const GatewayHandshake({
    required this.protocol,
    required this.capabilities,
    required this.authenticated,
    this.deviceId,
    this.deviceName,
    this.port,
    this.clients,
    this.gatewayId,
    this.gatewayName,
  });

  final int protocol;
  final List<String> capabilities;
  final bool authenticated;
  final String? deviceId;
  final String? deviceName;
  final int? port;
  final int? clients;
  final String? gatewayId;
  final String? gatewayName;

  /// Whether the host announced [capability].
  bool has(String capability) => capabilities.contains(capability);

  /// Builds from a decoded `kind == "hello"` frame.
  static GatewayHandshake fromFrame(Map<String, Object?> frame) {
    final device = asGatewayMap(frame['device']);
    final rawCapabilities = frame['capabilities'];
    return GatewayHandshake(
      protocol: gatewayInt(frame, 'protocol') ?? 0,
      capabilities: <String>[
        if (rawCapabilities is List)
          for (final entry in rawCapabilities)
            if (entry is String) entry,
      ],
      authenticated: gatewayBool(frame, 'authenticated'),
      deviceId: device == null ? null : gatewayString(device, 'id'),
      deviceName: device == null ? null : gatewayString(device, 'name'),
      port: gatewayInt(frame, 'port'),
      clients: gatewayInt(frame, 'clients'),
      gatewayId: gatewayString(frame, 'gatewayId'),
      gatewayName: gatewayString(frame, 'gatewayName'),
    );
  }
}

/// A live gateway connection.
class GatewayClient {
  GatewayClient._(this._socket, this.endpoint) {
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _beat());
    _listen();
  }

  /// How often a `ping` goes out (proxies close idle sockets on their own).
  static const Duration _heartbeatInterval = Duration(seconds: 20);

  /// How many unanswered heartbeats before the socket is considered dead.
  static const int _maxMissedBeats = 3;

  final WebSocket _socket;
  final Uri endpoint;

  GatewayHandshake? _handshake;
  GatewayDevice? _device;
  String? _clientDeviceId;

  final Map<String, Queue<Completer<Map<String, Object?>>>> _pending =
      <String, Queue<Completer<Map<String, Object?>>>>{};
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> _backlog = <Map<String, Object?>>[];
  final Completer<void> _done = Completer<void>();

  late final Timer _heartbeat;
  int _missedBeats = 0;
  bool _closed = false;
  bool _attached = false;
  int? _closeCode;
  String? _closeReason;

  /// What `hello` announced; null until the handshake finished.
  GatewayHandshake? get handshake => _handshake;

  /// The device record, when this connection came from a pairing.
  GatewayDevice? get device => _device;

  /// The long-lived token, when this connection came from a pairing.
  String? get newDeviceToken => _device?.token;

  /// Install-level device id this client presented.
  String? get clientDeviceId => _clientDeviceId;

  /// Capabilities `hello` advertised (empty before the handshake).
  List<String> get capabilities => _handshake?.capabilities ?? const <String>[];

  /// Whether the socket is still open.
  bool get isOpen => !_closed;

  /// Close code the gateway used, once closed.
  int? get closeCode => _closeCode;

  /// Close reason, once closed.
  String? get closeReason => _closeReason;

  /// Frames the gateway pushes without being asked (events, archives,
  /// questions, approvals, title changes…).
  Stream<Map<String, Object?>> get pushes => _events.stream;

  /// Completes once when the socket closes.
  Future<void> get done => _done.future;

  // ---------------------------------------------------------------- opening

  /// Pairs with a one-time code and returns a ready client.
  ///
  /// The caller must persist [newDeviceToken] and [device].
  static Future<GatewayClient> pair({
    required Uri endpoint,
    required String pairingCode,
    required String clientDeviceId,
    String? deviceName,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final protocols = <String>[
      kGatewaySubprotocol,
      '$kGatewayPairSubprotocolPrefix$pairingCode',
      '$kGatewayDeviceSubprotocolPrefix$clientDeviceId',
    ];
    if (deviceName != null && deviceName.isNotEmpty) {
      protocols.add(
        '$kGatewayDeviceNameSubprotocolPrefix'
        '${base64Url.encode(utf8.encode(deviceName)).replaceAll('=', '')}',
      );
    }
    final socket = await _open(endpoint, protocols: protocols, headers: const <String, Object?>{}, timeout: timeout);
    final client = GatewayClient._(socket, endpoint);
    client._clientDeviceId = clientDeviceId;

    final paired = await client._awaitKind(GatewayKind.paired, timeout);
    if (paired['kind'] == GatewayKind.error) {
      await client.close(GatewayClose.normal, 'pairing rejected');
      throw GatewayError.fromFrame(paired);
    }

    final deviceMap = asGatewayMap(paired['device']);
    final token = gatewayString(paired, 'token');
    final deviceId = deviceMap == null ? null : gatewayString(deviceMap, 'id');
    if (deviceId == null || token == null || token.isEmpty) {
      await client.close(GatewayClose.normal, 'incomplete pairing');
      throw const GatewayError(
        GatewayFailureCode.protocolMismatch,
        'The "paired" frame did not carry a device and a token.',
      );
    }
    client._device = GatewayDevice(
      id: deviceId,
      name: gatewayString(deviceMap!, 'name') ?? '',
      token: token,
    );

    await client._finishHandshake(timeout);
    return client;
  }

  /// Connects with a long-lived device token.
  static Future<GatewayClient> connect({
    required Uri endpoint,
    required String token,
    String? clientDeviceId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final protocols = <String>[kGatewaySubprotocol, '$kGatewayAuthSubprotocolPrefix$token'];
    if (clientDeviceId != null && clientDeviceId.isNotEmpty) {
      protocols.add('$kGatewayDeviceSubprotocolPrefix$clientDeviceId');
    }
    final socket = await _open(
      endpoint,
      protocols: protocols,
      headers: <String, Object?>{'Authorization': 'Bearer $token'},
      timeout: timeout,
    );
    final client = GatewayClient._(socket, endpoint);
    client._clientDeviceId = clientDeviceId;
    await client._finishHandshake(timeout);
    return client;
  }

  Future<void> _finishHandshake(Duration timeout) async {
    final hello = await _awaitKind(GatewayKind.hello, timeout);
    if (hello['kind'] == GatewayKind.error) {
      await close(GatewayClose.normal, 'handshake rejected');
      throw GatewayError.fromFrame(hello);
    }
    final handshake = GatewayHandshake.fromFrame(hello);
    if (handshake.protocol != kGatewayProtocol) {
      await close(GatewayClose.normal, 'protocol mismatch');
      throw GatewayError(
        GatewayFailureCode.protocolMismatch,
        'The gateway speaks protocol ${handshake.protocol}; this client needs $kGatewayProtocol.',
      );
    }
    _handshake = handshake;
    _attached = true;
    if (_backlog.isNotEmpty) {
      final buffered = List<Map<String, Object?>>.of(_backlog);
      _backlog.clear();
      for (final frame in buffered) {
        if (!_events.isClosed) _events.add(frame);
      }
    }
  }

  static Future<WebSocket> _open(
    Uri endpoint, {
    required List<String> protocols,
    required Map<String, Object?> headers,
    required Duration timeout,
  }) async {
    final socket = await WebSocket.connect(
      endpoint.toString(),
      protocols: protocols,
      headers: headers.isEmpty ? null : headers,
    ).timeout(timeout);
    return socket;
  }

  /// Waits for the first frame whose `kind` is [kind] (or an `error` frame).
  Future<Map<String, Object?>> _awaitKind(String kind, Duration timeout) async {
    for (final frame in List<Map<String, Object?>>.of(_backlog)) {
      final frameKind = gatewayString(frame, 'kind');
      if (frameKind == kind || frameKind == GatewayKind.error) {
        _backlog.remove(frame);
        return frame;
      }
    }
    final completer = Completer<Map<String, Object?>>();
    (_pending[kind] ??= Queue<Completer<Map<String, Object?>>>()).add(completer);
    (_pending[GatewayKind.error] ??= Queue<Completer<Map<String, Object?>>>()).add(completer);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw GatewayError(
        GatewayFailureCode.timeout,
        'The gateway did not send "$kind" within ${timeout.inSeconds}s.',
      );
    }
  }

  // ------------------------------------------------------------- transport

  void _listen() {
    _socket.listen(
      _onData,
      onDone: () => _finish(_socket.closeCode, _socket.closeReason),
      onError: (Object _) => _finish(_socket.closeCode, _socket.closeReason),
      cancelOnError: false,
    );
  }

  void _onData(Object? frame) {
    Map<String, Object?>? decoded;
    try {
      final text = frame is String ? frame : utf8.decode((frame as List<int>));
      decoded = asGatewayMap(jsonDecode(text));
    } on Object {
      return;
    }
    if (decoded == null) return;

    final kind = gatewayString(decoded, 'kind');
    if (kind == null) return;

    if (kind == GatewayKind.pong) {
      _missedBeats = 0;
      return;
    }

    final waiters = _pending[kind];
    if (waiters != null && waiters.isNotEmpty) {
      final completer = waiters.removeFirst();
      if (waiters.isEmpty) _pending.remove(kind);
      if (!completer.isCompleted) completer.complete(decoded);
      return;
    }

    if (kind == GatewayKind.error) {
      final error = GatewayError.fromFrame(decoded);
      final requestType = error.requestType;
      final queued = requestType == null ? null : _pending[requestType];
      if (queued != null && queued.isNotEmpty) {
        final completer = queued.removeFirst();
        if (queued.isEmpty) _pending.remove(requestType);
        if (!completer.isCompleted) completer.completeError(error);
        return;
      }
    }

    if (!_attached) {
      _backlog.add(decoded);
      return;
    }
    if (!_events.isClosed) _events.add(decoded);
  }

  void _beat() {
    if (_closed) return;
    _missedBeats += 1;
    if (_missedBeats > _maxMissedBeats) {
      unawaited(close(GatewayClose.normal, 'heartbeat timeout'));
      return;
    }
    _send(<String, Object?>{'type': GatewayRequest.ping});
  }

  void _send(Map<String, Object?> frame) {
    if (_closed) return;
    try {
      _socket.add(jsonEncode(frame));
    } on Object {
      unawaited(close(GatewayClose.normal, 'send failed'));
    }
  }

  void _finish(int? code, String? reason) {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    _heartbeat.cancel();
    final failure = _closingError(code, reason);
    for (final queue in _pending.values) {
      for (final completer in queue) {
        if (!completer.isCompleted) completer.completeError(failure);
      }
    }
    _pending.clear();
    if (!_events.isClosed) unawaited(_events.close());
    if (!_done.isCompleted) _done.complete();
  }

  GatewayError _closingError(int? code, String? reason) {
    final trimmed = reason?.trim();
    final suffix = trimmed == null || trimmed.isEmpty ? '' : ': $trimmed';
    return switch (code) {
      GatewayClose.gatewayDisabled => GatewayError(
          GatewayFailureCode.gatewayDisabled,
          'The mobile gateway was switched off$suffix.',
        ),
      GatewayClose.authRequired => GatewayError(
          GatewayFailureCode.authRequired,
          'The gateway asked for authentication again$suffix.',
        ),
      _ => GatewayError(GatewayFailureCode.disconnected, 'The gateway connection dropped$suffix.'),
    };
  }

  // ------------------------------------------------------------------ calls

  /// Sends one request and waits for the reply of [expect]
  /// (defaults to the request type, which is what the gateway echoes back for
  /// most handlers).
  ///
  /// Throws [GatewayError] for host refusals, a closed socket, or a timeout.
  Future<Map<String, Object?>> request(
    String type, {
    Map<String, Object?> params = const <String, Object?>{},
    Set<String>? expect,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed) throw _closingError(_closeCode, _closeReason);

    final kinds = expect ?? <String>{type};
    final completer = Completer<Map<String, Object?>>();
    for (final kind in kinds) {
      (_pending[kind] ??= Queue<Completer<Map<String, Object?>>>()).add(completer);
    }

    _send(<String, Object?>{'type': type, ...params});

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      for (final kind in kinds) {
        final queue = _pending[kind];
        if (queue != null) {
          queue.remove(completer);
          if (queue.isEmpty) _pending.remove(kind);
        }
      }
      throw GatewayError(
        GatewayFailureCode.timeout,
        'The gateway did not answer "$type" within ${timeout.inSeconds}s.',
        requestType: type,
      );
    }
  }

  /// `sessions`: the list already carries titles, so no per-row follow-up.
  Future<List<Map<String, Object?>>> sessions() async {
    final frame = await request(GatewayRequest.sessions);
    return asGatewayMaps(frame['items']);
  }

  /// `history`: one page of a conversation.
  Future<Map<String, Object?>> history(
    String sessionId, {
    int maxMessages = 60,
    int? beforeSeq,
    String view = 'conversation',
  }) =>
      request(
        GatewayRequest.history,
        params: <String, Object?>{
          'sessionId': sessionId,
          'maxMessages': maxMessages,
          'view': view,
          'beforeSeq': ?beforeSeq,
          if (beforeSeq != null) 'historyFormatVersion': 4,
        },
      );

  /// The `events` array of a `history` reply (raw `SessionEvent` objects).
  static List<Map<String, Object?>> historyEvents(Map<String, Object?> historyFrame) =>
      asGatewayMaps(historyFrame['events']);

  /// Closes the socket. Safe to call twice.
  Future<void> close([int code = GatewayClose.normal, String reason = 'client closing']) async {
    if (_closed) return;
    try {
      await _socket.close(code, reason);
    } on Object {
      // Closing a socket that is already gone is fine.
    }
    _finish(code, reason);
  }
}


