// Full permission is a two-step feature: [PrivilegeProbe] says whether this
// build may leave its container at all (a signing-time entitlement), and only
// then may one conversation be switched into full permission.
//
// The switch itself is a flag now. It used to stop the engine so the next start
// could mount the host root into the guest at /host, and on device that start
// never came back, which froze the App. The mount is off
// (`privilegeMountAvailable = false`); host files are reached through the native
// `host_*` tools instead, which the engine already has. So enabling touches no
// engine, and cannot hang.
//
// This controller is the single thing the UI watches: the phase, and the
// one-session-at-a-time rule.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'privilege_probe.dart';

/// Where the full-permission switch stands.
enum PrivilegePhase {
  /// The probe could not read anything outside the container: this build was
  /// not re-signed, so there is nothing to switch to and the switch must not
  /// be offered (a request there can only end in `privilege_mount`).
  sandboxed,

  /// The build may leave its container; no conversation holds full permission.
  privileged,

  /// Reserved: the switch no longer has an in-flight state. Kept so stored views
  /// and the failure sheet keep compiling.
  enabling,

  /// One conversation holds full permission.
  enabled,

  /// Reserved, like [enabling].
  disabling,

  /// A step of [PrivilegeController.enable] or [PrivilegeController.disable]
  /// failed; [failureStage] and [errno] say which, so the sheet can name it.
  failed,
}

/// What the UI and the settings rows read.
@immutable
class PrivilegeView {
  const PrivilegeView({this.phase = PrivilegePhase.sandboxed, this.failureStage, this.errno, this.message});

  /// The phase before the first probe: nothing is offered until the host
  /// answered (see [PrivilegeController.refreshProbe]).
  static const unknown = PrivilegeView();

  final PrivilegePhase phase;

  /// The host's stage (`probe_denied`, `open_root`, `root_new`, `mount`,
  /// `empty_mount`, `engine_restart`), or a step this side failed at.
  final String? failureStage;

  /// The syscall's errno: EPERM and ENOENT are different problems.
  final int? errno;

  /// One Chinese sentence from the host (or from this side, when the engine
  /// would not stop).
  final String? message;

  /// A conversation currently runs with full permission.
  bool get active => phase == PrivilegePhase.enabled;

  /// Whether the full-permission switch may be offered at all.
  bool get canOffer => phase == PrivilegePhase.privileged || active;

  PrivilegeView copyWith({
    PrivilegePhase? phase,
    String? failureStage,
    int? errno,
    String? message,
    bool clearFailure = false,
  }) => PrivilegeView(
    phase: phase ?? this.phase,
    failureStage: clearFailure ? null : failureStage ?? this.failureStage,
    errno: clearFailure ? null : errno ?? this.errno,
    message: clearFailure ? null : message ?? this.message,
  );

  @override
  bool operator ==(Object other) =>
      other is PrivilegeView &&
      other.phase == phase &&
      other.failureStage == failureStage &&
      other.errno == errno &&
      other.message == message;

  @override
  int get hashCode => Object.hash(phase, failureStage, errno, message);
}

/// Drives the engine through the host's full-permission steps and keeps the
/// one conversation that owns them.
class PrivilegeController extends Notifier<PrivilegeView> {
  /// The iOS host (`ios/Runner/EngineChannel.swift`). `start` is called here
  /// rather than through [RuntimeBridge] because only this path passes
  /// The owner the diagnostics page's own switch uses: it holds no
  /// conversation, but the one-at-a-time rule still applies.
  static const String diagnosticsSessionId = 'diagnostics';

  /// The conversation that owns full permission; null when nobody does.
  String? _fullAccessSessionId;

  /// Engine options the privileged start repeats, as the caller last knew them.

  /// The conversation holding full permission, at most one at a time.
  String? get fullAccessSessionId => _fullAccessSessionId;


  @override
  PrivilegeView build() => PrivilegeView.unknown;

  /// Reads the probe again (the switch's 重新探测). Keeps an enabled session.
  Future<void> refreshProbe() async {
    final probe = await PrivilegeProbe.read(refresh: true);
    if (state.phase == PrivilegePhase.enabling || state.phase == PrivilegePhase.disabling) return;
    state = state.copyWith(
      phase: _fullAccessSessionId != null
          ? PrivilegePhase.enabled
          : probe.sandboxed
          ? PrivilegePhase.sandboxed
          : PrivilegePhase.privileged,
      clearFailure: true,
    );
  }

  /// Gives [sessionId] full permission. This sets a flag and nothing else: no
  /// engine stop, no mount, no start (see the file header for why).
  ///
  /// False, without touching the host, when the probe says the build is
  /// sandboxed or when another conversation already holds the mode.
  /// [phoneStorage] and [visualReplies] stay in the signature because callers
  /// still pass the engine options they know.
  Future<bool> enable(String sessionId, {bool phoneStorage = false, bool visualReplies = true}) async {
    if (state.phase == PrivilegePhase.enabling || state.phase == PrivilegePhase.disabling) return false;

    // No permission to give: asking the host can only end in privilege_mount.
    final probe = PrivilegeProbe.cached ?? await PrivilegeProbe.read();
    if (probe.sandboxed) {
      state = state.copyWith(phase: PrivilegePhase.sandboxed, clearFailure: true, message: probe.detail);
      return false;
    }

    if (_fullAccessSessionId != null) {
      state = state.copyWith(message: '请先结束当前全权限会话');
      return false;
    }

    // No engine restart, ever. Enabling full permission used to stop the engine so
    // the next start could mount the host root into the guest — and on device that
    // start never came back, which froze the whole app. The mount is off now
    // (`privilegeMountAvailable = false`), and host file access goes through the
    // native `host_*` tools, which the engine already has. So this is a flag plus
    // the danger-full-access preset the caller sends, and nothing else.
    _fullAccessSessionId = sessionId;
    state = state.copyWith(phase: PrivilegePhase.enabled, clearFailure: true);
    unawaited(refreshProbe());
    return true;
  }

  /// Takes full permission away. Nothing to unmount, because nothing was ever
  /// mounted: this only clears the flag and settles the phase, so 停用 can never
  /// restart (and never hang) a healthy engine.
  Future<void> disable() async {
    if (state.phase == PrivilegePhase.disabling) return;
    _fullAccessSessionId = null;
    state = state.copyWith(phase: _probePhase(), clearFailure: true);
    unawaited(refreshProbe());
  }

  /// The phase the last probe implies, for settling without an engine step.
  PrivilegePhase _probePhase() {
    final probe = PrivilegeProbe.cached;
    if (probe == null) return state.phase;
    return probe.sandboxed ? PrivilegePhase.sandboxed : PrivilegePhase.privileged;
  }

}

final privilegeControllerProvider = NotifierProvider<PrivilegeController, PrivilegeView>(
  PrivilegeController.new,
);
