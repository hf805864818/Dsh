/// [HostLink] for a paired Mobile Gateway (`dsh-plugin-mobile-gateway`).
///
/// Everything above this file sees the same `HostLink` + `DshClient` contract
/// as an SSH or relay host; the gateway only changes how the socket is opened.
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/gateway.dart';

import '../../state/gateway_hosts.dart';
import '../link_status.dart';

/// Opens one gateway host and keeps it alive.
class GatewayHostLink implements HostLink {
  GatewayHostLink({
    required this.config,
    required this.loadToken,
    this.kicks,
  });

  /// The saved pairing.
  GatewayHostConfig config;

  /// Reads the device token (keystore) for [config].
  final Future<String?> Function() loadToken;

  /// Optional "network changed / app resumed" trigger.
  final Stream<void>? kicks;

  final StreamController<HostLinkStatus> _statuses =
      StreamController<HostLinkStatus>.broadcast(sync: true);
  final StreamController<DshClient> _clients = StreamController<DshClient>.broadcast();

  HostLinkStatus _status = HostLinkStatus.idle;
  GatewayClient? _gateway;
  DshClient? _client;
  StreamSubscription<void>? _kicks;
  Timer? _retryTimer;
  bool _closed = false;
  int _attempt = 0;

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<DshClient> get clients => _clients.stream;

  /// Applies an edited config (address change) without dropping the socket.
  void updateConfig(GatewayHostConfig next) => config = next;

  void _emit(HostLinkStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  @override
  Future<DshClient> open() async {
    _closed = false;
    _kicks ??= kicks?.listen((_) => kick());
    _emit(HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    final client = await _connectOnce();
    _emit(HostLinkStatus(HostLinkPhase.connected));
    _attempt = 0;
    return client;
  }

  Future<DshClient> _connectOnce() async {
    final token = await loadToken();
    if (token == null || token.isEmpty) {
      const error = HostLinkError(
        HostLinkErrorKind.notLoggedIn,
        '这个网关还没有配对，请重新扫码。',
      );
      _emit(const HostLinkStatus(HostLinkPhase.failed, error: error));
      throw error;
    }

    HostLinkError? lastError;
    for (final url in config.candidateUrls) {
      if (_closed) break;
      try {
        final gateway = await GatewayClient.connect(
          endpoint: Uri.parse(url),
          token: token,
          clientDeviceId: config.clientDeviceId.isEmpty ? null : config.clientDeviceId,
        );
        final carrier = GatewayCarrier(gateway, deviceId: config.clientDeviceId, gatewayLabel: config.name);
        final client = DshClient.withCarrier(carrier);
        _gateway = gateway;
        _client = client;
        unawaited(gateway.done.then((_) => _onSocketClosed()));
        return client;
      } on GatewayError catch (error) {
        lastError = _mapError(error, url);
        if (error.code == GatewayFailureCode.authRequired || error.code == 'gateway/protocol-mismatch') {
          break; // Another endpoint will fail the same way.
        }
      } on Object catch (error) {
        lastError = HostLinkError(
          HostLinkErrorKind.unreachable,
          '连不上网关地址。',
          detail: '$url: $error',
          retryable: true,
        );
      }
    }

    final failure = lastError ??
        const HostLinkError(HostLinkErrorKind.unreachable, '没有可用的网关地址。', retryable: true);
    _emit(HostLinkStatus(HostLinkPhase.failed, error: failure));
    throw failure;
  }

  HostLinkError _mapError(GatewayError error, String url) {
    final kind = switch (error.code) {
      GatewayFailureCode.authRequired => HostLinkErrorKind.authFailed,
      GatewayFailureCode.gatewayDisabled => HostLinkErrorKind.hostOffline,
      GatewayFailureCode.protocolMismatch => HostLinkErrorKind.unavailable,
      GatewayFailureCode.timeout || GatewayFailureCode.disconnected => HostLinkErrorKind.unreachable,
      _ => HostLinkErrorKind.unreachable,
    };
    return HostLinkError(
      kind,
      switch (kind) {
        HostLinkErrorKind.authFailed => '网关要求重新配对。',
        HostLinkErrorKind.hostOffline => '电脑上的移动网关已关闭。',
        HostLinkErrorKind.unavailable => '网关协议版本不匹配，请更新插件。',
        _ => '网关没有响应。',
      },
      detail: '$url: ${error.code} ${error.message}',
      retryable: error.retryable,
    );
  }

  void _onSocketClosed() {
    if (_closed) return;
    _client = null;
    if (_attempt >= 8) {
      _emit(const HostLinkStatus(
        HostLinkPhase.failed,
        error: HostLinkError(HostLinkErrorKind.unreachable, '网关连接多次中断。'),
      ));
      return;
    }
    _attempt += 1;
    final delay = Duration(seconds: (1 << (_attempt - 1)).clamp(1, 30).toInt());
    _emit(HostLinkStatus(
      HostLinkPhase.reconnecting,
      attempt: _attempt,
      nextRetryAt: DateTime.now().add(delay),
    ));
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(_reconnect()));
  }

  Future<void> _reconnect() async {
    if (_closed) return;
    try {
      final client = await _connectOnce();
      _attempt = 0;
      _emit(HostLinkStatus(HostLinkPhase.connected));
      if (!_clients.isClosed) _clients.add(client);
    } on Object {
      // _connectOnce already published the failure.
    }
  }

  @override
  void kick() {
    if (_status.isConnected || _closed) return;
    _retryTimer?.cancel();
    unawaited(_reconnect());
  }

  @override
  void retry() {
    _attempt = 0;
    _retryTimer?.cancel();
    if (_closed) return;
    _emit(HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    unawaited(_reconnect());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    await _kicks?.cancel();
    _kicks = null;
    await _gateway?.close();
    _gateway = null;
    _client = null;
    _emit(HostLinkStatus.idle);
    await _statuses.close();
    if (!_clients.isClosed) await _clients.close();
  }
}

