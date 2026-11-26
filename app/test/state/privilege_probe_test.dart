// The probe answers the one question the full-permission switch stands on:
// may this build's signature leave its container at all, and if so, which
// paths did the kernel actually allow. Both answers come from
// MethodChannel('dsh/runtime').invokeMapMethod('privilegeProbe') on iOS and
// from a constant everywhere else, so the channel is faked here and the
// parsing, the failure shape and the cache are pinned without a device.
//
// Everything that reads the cache resets it in setUp and tearDown: the cache
// is static, so a leftover would make one test answer with another's payload.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/state/privilege_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Method names the probe sent to the host, in order.
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    // read() answers without touching the host on anything but iOS, so the
    // platform has to claim iOS for the channel path to be exercised at all.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    PrivilegeProbe.reset();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PrivilegeProbe.reset();
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// Installs a host that records the method name and answers with [reply].
  ///
  /// No expectation goes inside [reply]: the probe swallows every exception on
  /// purpose (it turns them into [PrivilegeStatus.unknown]), so a failing
  /// expect there would be hidden and the test would pass for the wrong reason.
  void install(Future<Object?> Function() reply) {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) {
      calls.add(call.method);
      return reply();
    });
  }

  const deniedPayload = <String, Object?>{
    'sandboxed': true,
    'readable': <String>[],
    'denied': <String, int>{'/var/mobile/Documents': 1},
    'detail': '受限：签名未包含 no-sandbox，无法读取容器外目录',
  };

  test('a sandboxed build offers no escalation and keeps every denial', () async {
    install(() async => deniedPayload);

    final status = await PrivilegeProbe.read();

    expect(calls, <String>['privilegeProbe']);
    expect(status.sandboxed, isTrue);
    expect(status.canEscalate, isFalse);
    expect(status.readable, isEmpty);
    // 1 is EPERM: the signature did not include no-sandbox. The UI shows this
    // errno, so it must survive the map round trip as an int.
    expect(status.denied, <String, int>{'/var/mobile/Documents': 1});
    expect(status.detail, contains('no-sandbox'));
  });

  test('a build that may read outside the container offers the switch', () async {
    install(() async => <String, Object?>{
      'sandboxed': false,
      'readable': <String>['/var/mobile/Documents', '/var/mobile/Media'],
      'denied': <String, int>{'/var/jb': 2},
      'detail': '可读容器外目录（2/4）',
    });

    final status = await PrivilegeProbe.read();

    expect(status.sandboxed, isFalse);
    expect(status.canEscalate, isTrue);
    expect(status.readable, hasLength(2));
    expect(status.readable, contains('/var/mobile/Media'));
    // /var/jb is absent on stock devices (ENOENT), not merely denied: a missing
    // path and a refused one must stay distinguishable.
    expect(status.denied, <String, int>{'/var/jb': 2});
    expect(status.detail, contains('2/4'));
  });

  test('a failing channel yields unknown, never an optimistic answer', () async {
    install(
      () async => throw PlatformException(code: 'privilege_probe_failed', message: 'stat failed'),
    );

    final status = await PrivilegeProbe.read();

    expect(status.sandboxed, isTrue, reason: '未知按受困处理，否则 UI 会给出一个注定失败的开关');
    expect(status.canEscalate, isFalse);
    expect(status.readable, isEmpty);
    expect(status.denied, isEmpty);
    expect(status.detail, PrivilegeStatus.unknown.detail);
  });

  test('a null answer is the whole unknown status', () async {
    install(() async => null);

    final status = await PrivilegeProbe.read();

    expect(status.sandboxed, isTrue);
    expect(status.canEscalate, isFalse);
    expect(status.detail, PrivilegeStatus.unknown.detail);
  });

  test('an empty answer reads as unrestricted — fail-open, as implemented today', () async {
    // Locked down here because it is the one place the parse is optimistic:
    // a payload that lost its keys (a native build answering with a new shape)
    // turns sandboxed into false. The review list asks for this to be made
    // fail-closed; when that happens this test should flip, not silently pass.
    install(() async => <String, Object?>{});

    final status = await PrivilegeProbe.read();

    expect(status.sandboxed, isFalse);
    expect(status.canEscalate, isTrue);
    expect(status.detail, PrivilegeStatus.unknown.detail, reason: 'detail 回落到 unknown 文案，说明确实没拿到字段');
  });

  test('the second read answers from the cache; refresh asks the host again', () async {
    var sandboxed = true;
    install(() async => <String, Object?>{
      'sandboxed': sandboxed,
      'readable': <String>[if (!sandboxed) '/var/mobile/Media'],
      'denied': <String, int>{if (sandboxed) '/var/mobile/Documents': 1},
      'detail': sandboxed ? '受限' : '可读',
    });

    final first = await PrivilegeProbe.read();
    final second = await PrivilegeProbe.read();

    expect(calls, hasLength(1), reason: '第二次读不该再问一次宿主机');
    expect(PrivilegeProbe.cached, same(first));
    expect(second.sandboxed, isTrue);

    sandboxed = false;
    final refreshed = await PrivilegeProbe.read(refresh: true);

    expect(calls, hasLength(2));
    expect(refreshed.sandboxed, isFalse);
    expect(refreshed.canEscalate, isTrue);
    expect(PrivilegeProbe.cached, same(refreshed));
    expect(await PrivilegeProbe.read(), same(refreshed), reason: 'refresh 的结果就是新的缓存');
  });

  test('reset drops the cache so the next read asks the host again', () async {
    install(() async => deniedPayload);

    final first = await PrivilegeProbe.read();
    expect(PrivilegeProbe.cached, same(first));

    PrivilegeProbe.reset();
    expect(PrivilegeProbe.cached, isNull);

    await PrivilegeProbe.read();
    expect(calls, hasLength(2));
  });

  test('off iOS nothing is probed and no sandbox is claimed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    install(() async => deniedPayload);

    final status = await PrivilegeProbe.read();

    expect(calls, isEmpty, reason: '没有沙箱可探，就不该发 channel 调用');
    expect(status.sandboxed, isFalse);
    expect(status.canEscalate, isTrue);
    expect(status.detail, contains('非 iOS'));
    expect(PrivilegeProbe.cached, same(status));
  });

  group('PrivilegeStatus.fromMap', () {
    test('null is the unknown status', () {
      final status = PrivilegeStatus.fromMap(null);

      expect(status.sandboxed, isTrue);
      expect(status.canEscalate, isFalse);
      expect(status.detail, PrivilegeStatus.unknown.detail);
    });

    test('wrongly typed fields are dropped instead of crashing', () {
      final status = PrivilegeStatus.fromMap(<String, Object?>{
        'sandboxed': 'true',
        'readable': <Object?>[1, 'a', null],
        'denied': <String, Object?>{'/x': 'EPERM', '/y': 13},
        'detail': 42,
      });

      expect(status.sandboxed, isFalse, reason: '只有 == true 才算非受困');
      expect(status.readable, <String>['a']);
      expect(status.denied, <String, int>{'/y': 13});
      expect(status.detail, PrivilegeStatus.unknown.detail);
    });

    test('missing collections become empty, not null', () {
      final status = PrivilegeStatus.fromMap(<String, Object?>{'sandboxed': true, 'detail': '受限'});

      expect(status.readable, isEmpty);
      expect(status.denied, isEmpty);
      expect(status.detail, '受限');
      expect(status.canEscalate, isFalse);
    });
  });
}
