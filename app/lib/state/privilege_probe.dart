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
    this.dpkgVersion = '',
    this.layout = '',
    this.hostMounted = false,
    this.hostMountKnown = true,
    this.hostTools = false,
    this.hostToolsDetail = '',
    this.appVersion = '',
    this.hostToolsRun = '',
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

  /// First line of `dpkg --version`, spawned natively by the host. Empty means
  /// the binary did not run as this user even though the path exists.
  final String dpkgVersion;

  /// Which jailbreak layout the probe actually saw, named for the settings row:
  /// rootful `/usr/bin`, rootless `/var/jb`, roothide randomised `.jbroot`, or
  /// unrecognised. Informational only — `/host` is the same host root either way.
  final String layout;

  /// Whether the guest kernel reports the host root mounted at `/host` right now.
  /// This is the fact the session actually depends on; the preset alone grants
  /// nothing.
  final bool hostMounted;

  /// False when the engine does not export the mount query at all. That is a
  /// different fact from "asked and not mounted", and the row says so.
  final bool hostMountKnown;

  /// Whether the engine was told to load the host_* tools (plugin on disk and
  /// its entry in ios-host.patch.json). Distinct from the mount: it is the only
  /// host access path this build has.
  final bool hostTools;

  /// plugin=有 patch条目=无 — which half of the wiring was found.
  final String hostToolsDetail;

  /// 1.4.0b7: base version plus the CI-bumped build number.
  final String appVersion;

  /// What the plugin found when the engine loaded it (empty when it never ran).
  final String hostToolsRun;

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
      dpkgVersion: map['dpkgVersion'] is String ? map['dpkgVersion'] as String : '',
      layout: map['layout'] is String ? map['layout'] as String : '',
      hostMounted: map['hostMounted'] == true,
      hostMountKnown: map['hostMount'] is String && map['hostMount'] != 'unknown',
    hostTools: map['hostTools'] == true,
    hostToolsDetail: map['hostToolsDetail'] is String ? map['hostToolsDetail'] as String : '',
    appVersion: map['appVersion'] is String ? map['appVersion'] as String : '',
    hostToolsRun: map['hostToolsRun'] is String ? map['hostToolsRun'] as String : '',
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
