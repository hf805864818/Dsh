/// Mobile Gateway transport (`dsh-plugin-mobile-gateway` → `/ws/mobile`).
///
/// This is a **parallel** path to the relay transport in `src/transport/`: the
/// gateway authenticates with a device token over one plain WebSocket instead
/// of a Noise channel over a relay, so it does not plug into
/// `RemoteTransport` (which carries Noise ciphertext). Consumers use
/// [GatewayClient] directly, or the carrier in `src/gateway/gateway_carrier.dart`.
library;

export 'src/gateway/gateway_carrier.dart';
export 'src/gateway/gateway_client.dart';
export 'src/gateway/gateway_frames.dart';
export 'src/gateway/gateway_mapping.dart';
export 'src/gateway/gateway_snapshot_cache.dart';
export 'src/gateway/gateway_pairing.dart';
