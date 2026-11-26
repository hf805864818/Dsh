import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the current build's signature allows, as the kernel reports it.
///
/// `com.apple.private.security.no-sandbox` and `platform-application` are
/// signing-time entitlements: an app cannot grant itself either, and a
/// jailbroken device alone does not lift the sandbox. The native side therefore
/// probes real paths and reports what happened, so the UI can tell "you did not
/// re-sign" apart from "this directory is missing".
@immutable
class PrivilegeStatus {
  const PrivilegeStatus({
    required this.sandboxed,
    required this.readable,
    required this.denied,
    required this.detail,
    this.bootstrap = const <String>[],
  });

  /// True when no candidate path outside the container could be read.
  final bool sandboxed;

  /// Paths the kernel allowed.
  final List<String> readable;

  /// `path -> errno` for every rejected candidate.
  final Map<String, int> denied;

  /// One line for the settings row.
  final String detail;

  /// Jailbreak package-manager paths that exist, e.g. `/var/jb/usr/bin/dpkg`.
  /// Empty means none found: a readable-outside build can still have no dpkg.
  final List<String> bootstrap;

  static const PrivilegeStatus unknown = PrivilegeStatus(
    sandboxed: true,
    readable: <String>[],
    denied: <String, int>{},
    detail: '未知：探针未运行',
  );

  /// Whether a session may be offered the full-permission switch at all.
  bool get canEscalate => !sandboxed;

  static PrivilegeStatus fromMap(Map<String, Object?>? map) {
    if (map == null) return unknown;
    return PrivilegeStatus(
      sandboxed: map['sandboxed'] == true,
      readable: <String>[
        if (map['readable'] case final List list)
          for (final value in list)
            if (value is String) value,
      ],
      denied: <String, int>{
        if (map['denied'] case final Map denied)
          for (final entry in denied.entries)
            if (entry.key is String && entry.value is int) entry.key as String: entry.value as int,
      },
      detail: map['detail'] is String ? map['detail'] as String : unknown.detail,
      bootstrap: <String>[
        if (map['bootstrap'] case final List list)
          for (final value in list)
            if (value is String) value,
      ],
    );
  }
}

/// Reads [PrivilegeStatus] from the iOS host.
class PrivilegeProbe {
  const PrivilegeProbe._();

  static const MethodChannel _channel = MethodChannel('dsh/runtime');
  static PrivilegeStatus? _cached;

  /// The last result, without asking the host again.
  static PrivilegeStatus? get cached => _cached;

  /// Asks the host, or a non-iOS platform that has no sandbox to probe.
  static Future<PrivilegeStatus> read({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _cached = const PrivilegeStatus(
        sandboxed: false,
        readable: <String>[],
        denied: <String, int>{},
        detail: '非 iOS 平台：无沙箱限制',
      );
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('privilegeProbe');
      return _cached = PrivilegeStatus.fromMap(map);
    } on Object {
      return _cached = PrivilegeStatus.unknown;
    }
  }

  /// Drops the cache; the next [read] asks the host again.
  @visibleForTesting
  static void reset() => _cached = null;
}
