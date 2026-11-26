// Full permission is a two-step feature: the probe says whether this build may
// leave its container at all, and only then may one session be switched into
// full permission, which the host performs. The controller is the single thing
// the UI watches, so these tests pin exactly what the UI depends on:
//
//   * it never asks the host when the probe already said no (a request there
//     can only end in privilege_mount, and the button must not be offered);
//   * one session owns the mode at a time (a second enable is refused, not
//     stacked);
//   * a host failure becomes a phase with the stage and errno kept, so the UI
//     can say which step failed instead of "未知错误";
//   * disable returns to privileged and clears the owning session.
//
// Written against the agreed interface (PrivilegePhase / PrivilegeView /
// PrivilegeController + privilegeControllerProvider) because
// lib/state/privilege_state.dart was still being implemented when this file
// landed. Two adaptation points only: [_controllerOf] and [_viewOf].
//
// The host is a fake MethodChannel('dsh/runtime'): privilegeProbe answers the
// probe payload, privilegeEnable / privilegeDisable answer whatever the test
// set, and every method name is recorded so "did not call native" can be
// asserted instead of assumed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/state/privilege_probe.dart';
import 'package:dsh_app/state/privilege_state.dart';

/// ADAPT: the controller provider's real name in privilege_state.dart.
PrivilegeController _controllerOf(ProviderContainer container) => container.read(privilegeControllerProvider.notifier);

/// ADAPT: the provider the UI watches for the phases.
PrivilegeView _viewOf(ProviderContainer container) => container.read(privilegeControllerProvider);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Method names the controller sent to the host, in order.
  late List<String> calls;

  /// What `privilegeProbe` answers this test.
  late Map<String, Object?> probe;

  /// What `privilegeEnable` answers, or throws, this test.
  late Future<Object?> Function() enableReply;

  /// What `privilegeDisable` answers, or throws, this test.
  late Future<Object?> Function() disableReply;

  late ProviderContainer container;

  // A build whose signature lost no-sandbox: every candidate path failed, so
  // there is nothing to escalate to.
  const sandboxedProbe = <String, Object?>{
    'sandboxed': true,
    'readable': <String>[],
    'denied': <String, int>{'/var/mobile/Documents': 1},
    'detail': '受限：签名未包含 no-sandbox，无法读取容器外目录',
  };

  // A re-signed build: the container is out of the way, so a session may be
  // offered the switch.
  const privilegedProbe = <String, Object?>{
    'sandboxed': false,
    'readable': <String>['/var/mobile/Documents', '/var/mobile/Media'],
    'denied': <String, int>{'/var/jb': 2},
    'detail': '可读容器外目录（2/4）',
  };

  /// The mount step failing the way the host reports it: code carries the
  /// stage, details carry the same stage plus the errno the syscall returned.
  PlatformException mountFailure() => PlatformException(
    code: 'privilege_mount',
    message: 'mount failed',
    details: <String, Object?>{'stage': 'mount', 'errno': 2, 'detail': 'dsh_root 挂载失败：No such file or directory'},
  );

  setUp(() {
    calls = <String>[];
    probe = privilegedProbe;
    enableReply = () async => <String, Object?>{'ok': true};
    disableReply = () async => <String, Object?>{'ok': true};
    // The probe answers from a constant off iOS, so the platform has to claim
    // iOS for the whole enable path to be reachable.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    PrivilegeProbe.reset();
    messenger.setMockMethodCallHandler(channel, (MethodCall call) {
      calls.add(call.method);
      return switch (call.method) {
        'privilegeProbe' => Future<Object?>.value(probe),
        'privilegeEnable' => enableReply(),
        // The disable step's method name is the implementation's to choose;
        // answering every other privilege method keeps this fake honest either
        // way, and the assertions below only need "some mutation happened".
        'privilegeDisable' => disableReply(),
        _ => Future<Object?>.value(null)
      };
    });
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
    PrivilegeProbe.reset();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// Everything sent to the host that changes host state (probe reads aside).
  List<String> mutations() => calls.where((String method) => method != 'privilegeProbe').toList();

  test('a sandboxed build cannot be enabled and never asks the host to try', () async {
    probe = sandboxedProbe;
    final controller = _controllerOf(container);

    await controller.refreshProbe();

    expect(_viewOf(container).phase, PrivilegePhase.sandboxed);

    final enabled = await controller.enable('session-a');

    expect(enabled, isFalse);
    expect(mutations(), isEmpty, reason: '没有权限可给，调用宿主机只会换来一次 privilege_mount');
    expect(_viewOf(container).phase, PrivilegePhase.sandboxed);
    expect(controller.fullAccessSessionId, isNull);
  });

  test('enabling from the privileged phase switches the session and keeps its id', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(_viewOf(container).phase, PrivilegePhase.privileged);
    expect(_viewOf(container).active, isFalse);

    final enabled = await controller.enable('session-a');

    expect(enabled, isTrue);
    expect(calls, contains('privilegeEnable'));
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
    expect(_viewOf(container).active, isTrue);
    expect(controller.fullAccessSessionId, 'session-a');
    expect(_viewOf(container).failureStage, isNull);
    expect(_viewOf(container).errno, isNull);
  });

  test('an in-flight enable is observable as enabling, then lands on enabled', () async {
    // The phase is the only thing that greys out the switch, and "stuck in
    // enabling" is the failure mode a restart can produce, so both edges are
    // pinned here rather than left to the UI test.
    final gate = Completer<void>();
    enableReply = () async {
      await gate.future;
      return <String, Object?>{'ok': true};
    };
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    final enabling = controller.enable('session-a');
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(_viewOf(container).phase, PrivilegePhase.enabling);
    expect(_viewOf(container).active, isFalse);

    gate.complete();
    expect(await enabling, isTrue);
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
  });

  test('a mount failure keeps the stage and the errno for the UI', () async {
    enableReply = () async => throw mountFailure();
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    final enabled = await controller.enable('session-a');

    expect(enabled, isFalse);
    expect(_viewOf(container).phase, PrivilegePhase.failed);
    expect(_viewOf(container).failureStage, 'mount');
    expect(_viewOf(container).errno, 2, reason: 'errno 是用户唯一能拿去查的线索（EPERM 还是 ENOENT）');
    expect(_viewOf(container).message, isNotNull);
    expect(controller.fullAccessSessionId, isNull, reason: '挂载失败后不该留下一个“已开通”的会话 id');
  });

  test('a host failure without details still leaves failed, not enabling', () async {
    enableReply = () async => throw PlatformException(code: 'privilege_enable');
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    final enabled = await controller.enable('session-a');

    expect(enabled, isFalse);
    expect(_viewOf(container).phase, PrivilegePhase.failed, reason: '相位卡在 enabling 会让按钮永久禁用');
    expect(controller.fullAccessSessionId, isNull);
  });

  test('a failed enable can be retried with the same session and clears the old failure', () async {
    enableReply = () async => throw mountFailure();
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(await controller.enable('session-a'), isFalse);
    expect(_viewOf(container).phase, PrivilegePhase.failed);

    enableReply = () async => <String, Object?>{'ok': true};
    expect(await controller.enable('session-a'), isTrue);

    expect(_viewOf(container).phase, PrivilegePhase.enabled);
    expect(_viewOf(container).failureStage, isNull, reason: '重试成功还留着上次的 stage，UI 会一直显示旧错误');
    expect(_viewOf(container).errno, isNull);
    expect(controller.fullAccessSessionId, 'session-a');
  });

  test('a second session cannot take over an enabled one', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(await controller.enable('session-a'), isTrue);

    final again = await controller.enable('session-b');

    expect(again, isFalse);
    expect(controller.fullAccessSessionId, 'session-a', reason: '同一时刻只能有一个会话持有全权限');
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
    expect(mutations().where((String method) => method == 'privilegeEnable'), hasLength(1), reason: '第二次点击不该再拆装一次挂载');
  });

  test('disabling returns to the privileged phase and clears the session id', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(await controller.enable('session-a'), isTrue);
    calls.clear();

    await controller.disable();

    expect(_viewOf(container).phase, PrivilegePhase.privileged);
    expect(_viewOf(container).active, isFalse);
    expect(controller.fullAccessSessionId, isNull);
    expect(mutations(), isNotEmpty, reason: '卸载同样要落到宿主机，否则 dsh_root 会留在挂载表里');
  });

  test('disabling while nothing is enabled leaves the phase alone', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    await controller.disable();

    expect(_viewOf(container).phase, PrivilegePhase.privileged);
    expect(controller.fullAccessSessionId, isNull);
  });
}
