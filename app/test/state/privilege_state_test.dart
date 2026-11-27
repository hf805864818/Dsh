// Full permission is a two-step feature: the probe says whether this build may
// leave its container at all, and only then may one session be switched into
// full permission. Those tests pin exactly what the UI depends on:
//
//   * it never asks the host when the probe already said no (a request there
//     can only end in privilege_mount, and the button must not be offered);
//   * one session owns the mode at a time (a second enable is refused, not
//     stacked);
//   * enabling never restarts the engine. It used to, so the next start could
//     mount the host root into the guest — and on device that start never came
//     back, which froze the whole App. The mount is off
//     (`privilegeMountAvailable = false`) and host file access goes through the
//     native `host_*` tools instead, so the switch is a flag: no stop, no start,
//     no native call at all;
//   * disable clears the owning session and settles back to the probe's phase.
//
// The host is a fake MethodChannel('dsh/runtime'): `privilegeProbe` answers the
// probe payload and every method name is recorded, so "did not call native" is
// asserted rather than assumed.

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

  setUp(() {
    calls = <String>[];
    probe = privilegedProbe;
    // The probe answers from a constant off iOS, so the platform has to claim
    // iOS for the whole enable path to be reachable.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    PrivilegeProbe.reset();
    messenger.setMockMethodCallHandler(channel, (MethodCall call) {
      calls.add(call.method);
      return switch (call.method) {
        'privilegeProbe' => Future<Object?>.value(probe),
        // Anything else would be a host mutation, and these tests assert there
        // are none.
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

  test('enabling switches the session without touching the engine', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(_viewOf(container).phase, PrivilegePhase.privileged);
    expect(_viewOf(container).active, isFalse);

    final enabled = await controller.enable('session-a');

    expect(enabled, isTrue);
    // The whole point of this test: the host was never asked to stop, mount or
    // start anything. A restart here is what froze the App on device.
    expect(mutations(), isEmpty, reason: '启用全权限不该让引擎停一次再起一次');
    expect(calls, isNot(contains('start')));
    expect(calls, isNot(contains('stop')));
    expect(calls, isNot(contains('privilegeEnable')));
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
    expect(_viewOf(container).active, isTrue);
    expect(controller.fullAccessSessionId, 'session-a');
    expect(_viewOf(container).failureStage, isNull);
    expect(_viewOf(container).errno, isNull);
  });

  test('enabling lands on enabled in a single step, never on enabling', () async {
    // "Stuck in enabling" is the failure mode the old restart produced, so the
    // phase the UI watches must settle immediately.
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    final enabling = controller.enable('session-a');

    expect(await enabling, isTrue);
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
  });

  test('a second session cannot take over an enabled one', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();
    expect(await controller.enable('session-a'), isTrue);

    final again = await controller.enable('session-b');

    expect(again, isFalse);
    expect(controller.fullAccessSessionId, 'session-a', reason: '同一时刻只能有一个会话持有全权限');
    expect(_viewOf(container).phase, PrivilegePhase.enabled);
    expect(mutations(), isEmpty, reason: '第二次点击不该再碰宿主机');
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
    // Nothing was mounted, so there is nothing to unmount: a restart here would
    // be the same freeze the enable path used to have.
    expect(mutations(), isEmpty, reason: '没有挂载过，就不该为了卸载重启引擎');
  });

  test('disabling while nothing is enabled leaves the phase alone', () async {
    final controller = _controllerOf(container);
    await controller.refreshProbe();

    await controller.disable();

    expect(_viewOf(container).phase, PrivilegePhase.privileged);
    expect(controller.fullAccessSessionId, isNull);
  });
}
