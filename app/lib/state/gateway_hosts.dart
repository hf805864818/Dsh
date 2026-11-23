/// Saved Mobile Gateway hosts (`dsh-plugin-mobile-gateway` → `/ws/mobile`).
///
/// Kept apart from [HostsState] on purpose: SSH hosts and gateway hosts have
/// nothing in common beyond "a computer the app can talk to", and keeping the
/// lists separate means the existing SSH storage path stays untouched.
///
/// The long-lived device token never lands here — it goes to the [SecretStore]
/// under `gateway.<gatewayId>.token`.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One paired gateway.
class GatewayHostConfig {
  const GatewayHostConfig({
    required this.id,
    required this.name,
    required this.url,
    required this.endpoints,
    required this.deviceId,
    required this.deviceName,
    required this.clientDeviceId,
  });

  /// Stable identity: the gateway's own `gatewayId`.
  final String id;

  /// Display name (`gatewayName`).
  final String name;

  /// The endpoint that worked last time.
  final String url;

  /// Every advertised endpoint, preferred first.
  final List<String> endpoints;

  /// Server-side device record id.
  final String deviceId;

  /// Device name registered on the gateway.
  final String deviceName;

  /// Install-level id presented on the wire (stable across re-pairing).
  final String clientDeviceId;

  /// Endpoints worth trying: [url] first, then the rest, de-duplicated.
  List<String> get candidateUrls {
    final seen = <String>{};
    final out = <String>[];
    for (final value in <String>[url, ...endpoints]) {
      if (value.isEmpty) continue;
      if (seen.add(value)) out.add(value);
    }
    return List<String>.unmodifiable(out);
  }

  /// Key the device token is stored under.
  String get secretKey => 'gateway.$id.token';

  GatewayHostConfig copyWith({String? url, String? name, List<String>? endpoints}) => GatewayHostConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        endpoints: endpoints ?? this.endpoints,
        deviceId: deviceId,
        deviceName: deviceName,
        clientDeviceId: clientDeviceId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'url': url,
        'endpoints': endpoints,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'clientDeviceId': clientDeviceId,
      };

  static GatewayHostConfig? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final url = value['url'];
    if (id is! String || id.isEmpty || url is! String || url.isEmpty) return null;
    final rawEndpoints = value['endpoints'];
    return GatewayHostConfig(
      id: id,
      name: value['name'] is String ? value['name']! as String : url,
      url: url,
      endpoints: <String>[
        if (rawEndpoints is List)
          for (final entry in rawEndpoints)
            if (entry is String && entry.isNotEmpty) entry,
      ],
      deviceId: value['deviceId'] is String ? value['deviceId']! as String : '',
      deviceName: value['deviceName'] is String ? value['deviceName']! as String : '',
      clientDeviceId: value['clientDeviceId'] is String ? value['clientDeviceId']! as String : '',
    );
  }
}

/// Saved gateway hosts.
class GatewayHostsState {
  const GatewayHostsState({this.hosts = const <GatewayHostConfig>[], this.loaded = false});

  final List<GatewayHostConfig> hosts;
  final bool loaded;

  GatewayHostConfig? byId(String id) {
    for (final host in hosts) {
      if (host.id == id) return host;
    }
    return null;
  }
}

/// Reads and writes [GatewayHostsState] (prefs only; tokens live in the keystore).
class GatewayHostsController extends Notifier<GatewayHostsState> {
  static const prefsKey = 'remote_gateway_hosts';

  @override
  GatewayHostsState build() {
    Future<void>(() => _load());
    return const GatewayHostsState();
  }

  Future<void> _load() async {
    var hosts = const <GatewayHostConfig>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          hosts = decoded.map(GatewayHostConfig.fromJson).whereType<GatewayHostConfig>().toList(growable: false);
        }
      }
    } catch (_) {
      // No prefs backend (tests) or a corrupt entry: start empty.
    }
    state = GatewayHostsState(hosts: hosts, loaded: true);
  }

  Future<bool> _persist(List<GatewayHostConfig> hosts) async {
    state = GatewayHostsState(hosts: List<GatewayHostConfig>.unmodifiable(hosts), loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(
        prefsKey,
        jsonEncode(<Object?>[for (final host in hosts) host.toJson()]),
      );
    } catch (_) {
      return false;
    }
  }

  /// Inserts or replaces a host (matched by [GatewayHostConfig.id]).
  Future<bool> save(GatewayHostConfig host) async {
    final next = <GatewayHostConfig>[...state.hosts.where((existing) => existing.id != host.id), host];
    return _persist(next);
  }

  /// Forgets a host's record (the caller deletes its token too).
  Future<bool> remove(String id) async {
    final next = state.hosts.where((existing) => existing.id != id).toList(growable: false);
    return _persist(next);
  }
}

final gatewayHostsProvider = NotifierProvider<GatewayHostsController, GatewayHostsState>(
  GatewayHostsController.new,
);
