/// A [DshCarrier] backed by one Mobile Gateway WebSocket.
///
/// `DshCarrier` sits *below* `DshRpc`/`DshMux`, so mapping the gateway's own
/// frame vocabulary onto DSH endpoints keeps every screen above this file
/// unchanged. Endpoints the gateway cannot serve are refused through
/// [allowsEndpoint], which turns them into `METHOD_NOT_ALLOWED` instead of
/// throwing — the UI already degrades on that code.
///
/// Shapes below were captured from a live gateway (0.12.2 / DSH 0.2.2-rc.5):
/// * `sessions`  → `{"items":[{sessionId, updatedAt, running, blank,
///   agentAvailable, cwd, projections:{asOfSeq, values:{title}}}]}` — already
///   the exact shape `SessionSummary.fromJson` expects.
/// * `history`   → `{"events":[...raw SessionEvent...], "hasMore":bool}`
///   while DSH wants `{"records":[{"event":…}], "hasMore":bool}`.
/// * `event`     → `{"sessionId","seq","time","event":{type,…}}` which becomes
///   a follow item `{"type":"event","event":{type,seq,time,data}}`.
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'gateway_client.dart';
import 'gateway_frames.dart';

/// Endpoints this carrier answers.
const Set<String> _servedEndpoints = <String>{
  'session/list',
  'session/page',
  'session/rename',
  'session/prompt',
  'session/cancel',
  'session/search',
  'session/attachment',
  'workspace/archiveSession',
  'userQuestions/answer',
};

/// A gateway connection presented as a `DshCarrier`.
class GatewayCarrier implements DshCarrier {
  GatewayCarrier(this._client, {this.deviceId, this.gatewayLabel});

  final GatewayClient _client;

  /// Install-level device id presented on the wire.
  final String? deviceId;

  /// Display name for diagnostics.
  final String? gatewayLabel;

  /// Cached `sessions` reply, so `session/projections` can be answered without
  /// another round trip.
  final Map<String, Map<String, Object?>> _sessionCache = <String, Map<String, Object?>>{};

  GatewayClient get client => _client;

  @override
  String get kind => 'gateway';

  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => _servedEndpoints.contains(endpoint);

  @override
  Set<String>? get peerCapabilities => _client.capabilities.toSet();

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    try {
      final value = await _dispatch(endpoint, args, timeout);
      return RpcOk(value);
    } on GatewayError catch (error) {
      return RpcError(DshRemoteException(error.code, error.message, _details(error)));
    } on DshRemoteException catch (error) {
      return RpcError(error);
    }
  }

  Future<Object?> _dispatch(String endpoint, Map<String, Object?> args, Duration? timeout) async {
    switch (endpoint) {
      case 'session/list':
        final frame = await _client.request(GatewayRequest.sessions, timeout: _or(timeout));
        final items = asGatewayMaps(frame['items']);
        for (final item in items) {
          final id = gatewayString(item, 'sessionId');
          if (id != null) _sessionCache[id] = item;
        }
        return <String, Object?>{'items': items};

      case 'session/page':
        final request = asGatewayMap(args['request']) ?? const <String, Object?>{};
        final sessionId = _sessionIdOf(request);
        if (sessionId == null) {
          throw const DshRemoteException('gateway/bad-request', 'session/page needs a session address');
        }
        // Gateway pages by `beforeSeq` only; DSH passes `throughSeq` as well.
        final beforeSeq = args['beforeSeq'] ?? request['beforeSeq'];
        final maxMessages = request['maxMessages'] ?? args['maxMessages'];
        final frame = await _client.request(
          GatewayRequest.history,
          params: <String, Object?>{
            'sessionId': sessionId,
            'maxMessages': maxMessages is int ? maxMessages : 60,
            'view': 'conversation',
            if (beforeSeq is int) 'beforeSeq': beforeSeq,
            if (beforeSeq is int) 'historyFormatVersion': 4,
          },
          timeout: _or(timeout),
        );
        final events = GatewayClient.historyEvents(frame);
        return <String, Object?>{
          'records': <Object?>[
            for (final event in events) <String, Object?>{'event': event},
          ],
          'hasMore': frame['hasMore'] == true,
        };

      case 'session/rename':
        final sessionId = gatewayString(args, 'sessionId') ?? gatewayString(args, 'address');
        final title = gatewayString(args, 'title') ?? gatewayString(args, 'name');
        await _client.request(
          GatewayRequest.sessionRename,
          params: <String, Object?>{'sessionId': ?sessionId, 'title': ?title},
          timeout: _or(timeout),
        );
        return null;

      case 'session/prompt':
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        final text = gatewayString(args, 'text') ?? _promptText(args);
        await _client.request(
          GatewayRequest.message,
          params: <String, Object?>{
            'sessionId': ?sessionId,
            'text': ?text,
          },
          expect: _promptExpect(),
          timeout: _or(timeout),
        );
        return null;

      case 'session/cancel':
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        await _client.request(
          GatewayRequest.sessionCancel,
          params: <String, Object?>{'sessionId': ?sessionId},
          timeout: _or(timeout),
        );
        return null;

      case 'workspace/archiveSession':
        final sessionId = gatewayString(args, 'sessionId') ?? _sessionIdOf(args);
        await _client.request(
          GatewayRequest.sessionArchive,
          params: <String, Object?>{'sessionId': ?sessionId},
          timeout: _or(timeout),
        );
        return null;

      case 'session/search':
        final query = gatewayString(args, 'query') ?? gatewayString(args, 'text') ?? '';
        final frame = await _client.request(
          GatewayRequest.search,
          params: <String, Object?>{'query': query},
          timeout: _or(timeout),
        );
        return frame['items'] ?? frame['results'] ?? const <Object?>[];

      case 'session/attachment':
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        final attachmentId = gatewayString(args, 'attachmentId') ?? gatewayString(args, 'id');
        final frame = await _client.request(
          GatewayRequest.attachment,
          params: <String, Object?>{'sessionId': ?sessionId, 'attachmentId': ?attachmentId},
          timeout: _or(timeout),
        );
        return frame['data'] ?? frame['bytes'] ?? frame;

      case 'userQuestions/answer':
        // Human-in-the-loop replies reuse the gateway's dedicated frames; the
        // gateway keys them by the plugin's own rpcId.
        throw const DshRemoteException(
          'gateway/not-implemented',
          'Answering questions over the gateway carrier is not wired yet.',
        );

      default:
        throw DshRemoteException('METHOD_NOT_ALLOWED', 'The gateway cannot serve $endpoint.');
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _GatewayMuxLink(_client);
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    return link;
  }

  @override
  Future<void> close() => _client.close();

  static Duration _or(Duration? timeout) => timeout ?? const Duration(seconds: 30);

  static Set<String> _promptExpect() => <String>{GatewayKind.sent, GatewayRequest.message};

  static Map<String, Object?> _details(GatewayError error) => <String, Object?>{
        if (error.requestType != null) 'requestType': error.requestType,
        if (error.sessionId != null) 'sessionId': error.sessionId,
      };

  /// Reads a session id out of `{'address': {'sessionId': …}}` or a flat map.
  static String? _sessionIdOf(Map<String, Object?> value) {
    final address = asGatewayMap(value['address']);
    if (address != null) {
      final id = gatewayString(address, 'sessionId') ?? gatewayString(address, 'id');
      if (id != null) return id;
    }
    return gatewayString(value, 'sessionId');
  }

  /// Pulls the plain text out of a DSH prompt payload.
  static String? _promptText(Map<String, Object?> args) {
    final request = asGatewayMap(args['request']);
    final source = request ?? args;
    final direct = gatewayString(source, 'text');
    if (direct != null) return direct;
    final parts = source['parts'];
    if (parts is List) {
      final buffer = StringBuffer();
      for (final part in parts) {
        final map = asGatewayMap(part);
        if (map == null) continue;
        final text = gatewayString(map, 'text');
        if (text != null) buffer.write(text);
      }
      if (buffer.isNotEmpty) return buffer.toString();
    }
    return null;
  }
}

/// One `DshMuxLink` over the gateway socket.
///
/// `$events` gets a synthetic `ready` item (the gateway has no per-connection
/// home directory) and then forwards host-level pushes. `session/follow`
/// subscribes to the session and forwards `event` frames as follow items.
class _GatewayMuxLink implements DshMuxLink {
  _GatewayMuxLink(this._client);

  final GatewayClient _client;
  DshMuxFrameHandler? _onFrame;
  DshMuxLossHandler? _onLost;
  StreamSubscription<Map<String, Object?>>? _pushes;
  final Map<String, String> _streamSessions = <String, String>{};
  bool _closed = false;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
    _pushes = _client.pushes.listen(_deliver, onDone: _reportLoss, onError: (Object _) => _reportLoss());
  }

  void _reportLoss() {
    if (_closed) return;
    _closed = true;
    _onLost?.call(const DshCarrierLostException('gateway link closed'), null);
  }

  void _emit(Map<String, Object?> frame) {
    if (_closed) return;
    _onFrame?.call(frame);
  }

  void _deliver(Map<String, Object?> frame) {
    final kind = gatewayString(frame, 'kind');
    switch (kind) {
      case GatewayKind.event:
        final sessionId = gatewayString(frame, 'sessionId');
        final event = asGatewayMap(frame['event']);
        if (sessionId == null || event == null) return;
        final streamId = _streamSessions.entries
            .where((entry) => entry.value == sessionId)
            .map((entry) => entry.key)
            .firstOrNull;
        if (streamId == null) return;
        _emit(<String, Object?>{
          'type': 'item',
          'streamId': streamId,
          'value': <String, Object?>{
            'type': 'event',
            'event': <String, Object?>{
              'type': gatewayString(event, 'type') ?? 'unknown',
              'seq': gatewayInt(frame, 'seq') ?? 0,
              'time': gatewayInt(frame, 'time') ?? 0,
              'data': event,
            },
          },
        });
      case GatewayKind.sessionTitleChanged:
        final sessionId = gatewayString(frame, 'sessionId');
        final title = gatewayString(frame, 'title');
        if (sessionId == null) return;
        _emit(<String, Object?>{
          'type': 'item',
          'streamId': hostEventsEndpoint,
          'value': <String, Object?>{
            'type': 'emit',
            'event': 'api-session/status',
            'args': <Object?>[sessionId, title ?? ''],
          },
        });
      default:
        break;
    }
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == hostEventsEndpoint || endpoint == r'$events') {
      // Synthetic ready: the socket itself is the generation.
      _emit(<String, Object?>{
        'type': 'item',
        'streamId': streamId,
        'value': <String, Object?>{
          'type': 'ready',
          'clientId': _client.device?.id ?? _client.handshake?.gatewayId ?? 'gateway',
          'host': <String, Object?>{'home': ''},
        },
      });
      return;
    }
    if (endpoint == 'session/follow') {
      final request = asGatewayMap(payload['args'])?['request'] ??
          asGatewayMap(payload)?['request'] ??
          payload['request'];
      final sessionId = request is Map ? GatewayCarrier._sessionIdOf(asGatewayMap(request) ?? const {}) : null;
      final id = sessionId ?? (request is Map ? '${asGatewayMap(request) ?? const {}}' : null);
      if (id == null) {
        _emit(<String, Object?>{
          'type': 'error',
          'streamId': streamId,
          'error': <String, Object?>{'code': 'gateway/bad-request', 'message': 'follow needs a session'},
        });
        return;
      }
      _streamSessions[streamId] = id;
      unawaited(
        _client
            .request(
              GatewayRequest.subscribe,
              params: <String, Object?>{'sessionId': id},
              expect: <String>{GatewayKind.subscribed},
            )
            .catchError((Object error) {
          _emit(<String, Object?>{
            'type': 'error',
            'streamId': streamId,
            'error': <String, Object?>{'code': 'gateway/subscribe-failed', 'message': '$error'},
          });
          throw error;
        }),
      );
    }
  }

  @override
  void sendItem(String streamId, Object? value) {
    // The gateway owns message delivery; nothing to send from a stream.
  }

  @override
  void endUplink(String streamId) {
    // No uplink support.
  }

  @override
  void cancel(String streamId) {
    _streamSessions.remove(streamId);
  }

  @override
  Future<void> close(int code, String reason) async {
    _closed = true;
    await _pushes?.cancel();
    _pushes = null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

