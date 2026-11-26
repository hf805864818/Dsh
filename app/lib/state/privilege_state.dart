// Full permission is a two-step feature: [PrivilegeProbe] says whether this
// build may leave its container at all (a signing-time entitlement), and only
// then may one conversation be switched into full permission, which the host
// performs by stopping the engine, mounting the host root at /host and starting
// it again with `privilege: 'full'`.
//
// This controller is the single thing the UI watches. It keeps the phase, the
// failing stage and the errno the host reported, so a failure reads "挂载失败，
// errno 2" instead of "未知错误", and it owns the one-session-at-a-time rule.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'privilege_probe.dart';

/// Where the full-permission switch stands.
enum PrivilegePhase {
  /// The probe could not read anything outside the container: this build was
  /// not re-signed, so there is nothing to switch to and the switch must not
  /// be offered (a request there can only end in `privilege_mount`).
  sandboxed,

  /// The build may leave its container; no conversation holds full permission.
  privileged,

  /// The host is stopping the engine, mounting, or starting it again.
  enabling,

  /// One conversation holds full permission.
  enabled,

  /// Taking full permission away, back to [privileged].
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
  /// `privilege: 'full'`; the other options repeat what [RuntimeBridge.start]
  /// sends so a restart does not silently drop them.
  static const MethodChannel _methods = MethodChannel('dsh/runtime');

  /// The owner the diagnostics page's own switch uses: it holds no
  /// conversation, but the one-at-a-time rule still applies.
  static const String diagnosticsSessionId = 'diagnostics';

  /// The conversation that owns full permission; null when nobody does.
  String? _fullAccessSessionId;

  /// Engine options the privileged start repeats, as the caller last knew them.
  bool _phoneStorage = false;
  bool _visualReplies = true;

  /// The conversation holding full permission, at most one at a time.
  String? get fullAccessSessionId => _fullAccessSessionId;

  /// Only iOS's host has mounts to arrange: the `privilege*` methods do not
  /// exist anywhere else, and everywhere else there is no sandbox to lift, so
  /// the preset alone is the whole switch ([PrivilegeProbe] already answers
  /// "not sandboxed" off iOS).
  static bool get _hosted => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

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

  /// Gives [sessionId] full permission: stop the engine, let the host mount
  /// the host root at `/host` inside that start, then bring it back up with `privilege: 'full'`.
  ///
  /// False without touching the host when the probe says the build is
  /// sandboxed, when another conversation already holds the mode, or when a
  /// step failed (then [PrivilegeView.failureStage] / [PrivilegeView.errno]
  /// carry the reason). [phoneStorage] and [visualReplies] are the engine
  /// options the caller knows; they repeat what the app's settings hold.
  Future<bool> enable(String sessionId, {bool phoneStorage = false, bool visualReplies = true}) async {
    // A second tap while the engine is being taken down must not stack.
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

    // No sandbox to lift: the preset alone switches the conversation.
    if (!_hosted) {
      _fullAccessSessionId = sessionId;
      state = state.copyWith(phase: PrivilegePhase.enabled, clearFailure: true);
      return true;
    }

    _phoneStorage = phoneStorage;
    _visualReplies = visualReplies;
    state = state.copyWith(phase: PrivilegePhase.enabling, clearFailure: true);
    try {
      if (!await _stopEngine()) {
        throw PlatformException(code: 'privilege_engine_restart', message: '引擎没有停下，无法切换全权限');
      }
      await _methods.invokeMethod<void>('privilegeEnable');
      await _startEngine(privileged: true);
    } on PlatformException catch (error) {
      _fullAccessSessionId = null;
      state = state.copyWith(
        phase: PrivilegePhase.failed,
        failureStage: _stageOf(error),
        errno: _errnoOf(error),
        message: _messageOf(error),
      );
      return false;
    } catch (error) {
      _fullAccessSessionId = null;
      state = state.copyWith(phase: PrivilegePhase.failed, failureStage: 'enable', message: '$error');
      return false;
    }
    _fullAccessSessionId = sessionId;
    state = state.copyWith(phase: PrivilegePhase.enabled, clearFailure: true);
    // The engine has just restarted with the mount, so the cached probe is stale:
    // 诊断 › 「宿主挂载」 reads that cache and would still say 未挂载 until someone
    // tapped 重新探测. Ask again before reporting success.
    await refreshProbe();
    return true;
  }

  /// Takes full permission away: stop the engine, let the host unmount, then
  /// start it again as usual. A no-op (aside from settling the phase) when
  /// nothing is enabled, so 停用 never restarts a healthy engine for nothing.
  Future<void> disable() async {
    if (state.phase == PrivilegePhase.enabling || state.phase == PrivilegePhase.disabling) return;
    if (!_hosted) {
      _fullAccessSessionId = null;
      state = state.copyWith(phase: _probePhase(), clearFailure: true);
      return;
    }
    if (_fullAccessSessionId == null && state.phase != PrivilegePhase.enabled) {
      state = state.copyWith(phase: _probePhase(), clearFailure: true);
      return;
    }
    state = state.copyWith(phase: PrivilegePhase.disabling, clearFailure: true);
    try {
      if (!await _stopEngine()) {
        throw PlatformException(code: 'privilege_engine_restart', message: '引擎没有停下，无法关闭全权限');
      }
      await _methods.invokeMethod<void>('privilegeDisable');
      await _startEngine(privileged: false);
    } on PlatformException catch (error) {
      _fullAccessSessionId = null;
      state = state.copyWith(
        phase: PrivilegePhase.failed,
        failureStage: _stageOf(error),
        errno: _errnoOf(error),
        message: _messageOf(error),
      );
      return;
    } catch (error) {
      _fullAccessSessionId = null;
      state = state.copyWith(phase: PrivilegePhase.failed, failureStage: 'disable', message: '$error');
      return;
    }
    _fullAccessSessionId = null;
    state = state.copyWith(phase: PrivilegePhase.privileged, clearFailure: true);
    // Same reason as in enable(): the row must stop claiming /host is mounted.
    await refreshProbe();
  }

  /// Stops the engine and waits for it to leave `running`, as mounts are fixed
  /// at launch. True when it is already down or went down; false when the stop
  /// did not finish (the bound is on the UI wait, not on native cleanup).
  Future<bool> _stopEngine() async {
    bool stoppedNow() {
      final phase = ref.read(localRuntimeProvider).status.phase;
      return !phase.isBusy && phase != RuntimePhase.running;
    }

    if (stoppedNow()) return true;
    final stopped = Completer<bool>();
    final sub = ref.listen<RuntimePhase>(localRuntimeProvider.select((s) => s.status.phase), (_, next) {
      if (!next.isBusy && next != RuntimePhase.running && !stopped.isCompleted) stopped.complete(true);
    });
    try {
      if (stoppedNow()) return true;
      if (ref.read(localRuntimeProvider).status.phase != RuntimePhase.stopping) {
        await ref.read(localRuntimeProvider.notifier).stop();
      }
      if (stoppedNow()) return true;
      return await stopped.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
    } finally {
      sub.close();
    }
  }

  /// Starts the engine again, with or without the host's full-permission
  /// mounts. Nothing else about the start changes.
  Future<void> _startEngine({required bool privileged}) => _methods.invokeMethod<void>('start', {
    'env': const <String, String>{},
    'phoneStorage': _phoneStorage,
    'mode': null,
    'visualReplies': _visualReplies,
    if (privileged) 'privilege': 'full',
  });

  /// The phase the last probe implies, for settling without an engine step.
  PrivilegePhase _probePhase() {
    final probe = PrivilegeProbe.cached;
    if (probe == null) return state.phase;
    return probe.sandboxed ? PrivilegePhase.sandboxed : PrivilegePhase.privileged;
  }

  /// `privilege_mount` → `mount`; a stage the host named wins.
  static String _stageOf(PlatformException error) {
    const prefix = 'privilege_';
    final details = error.details;
    if (details is Map && details['stage'] is String) return details['stage'] as String;
    return error.code.startsWith(prefix) ? error.code.substring(prefix.length) : error.code;
  }

  static int? _errnoOf(PlatformException error) => switch (error.details) {
    {'errno': final int errno} => errno,
    {'errno': final num errno} => errno.toInt(),
    _ => null,
  };

  /// The host's own sentence when it wrote one, else the exception's.
  static String _messageOf(PlatformException error) {
    final detail = switch (error.details) {
      {'detail': final String detail} => detail,
      _ => null,
    };
    return detail ?? error.message ?? error.code;
  }
}

final privilegeControllerProvider = NotifierProvider<PrivilegeController, PrivilegeView>(
  PrivilegeController.new,
);
