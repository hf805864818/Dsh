import 'dart:convert';

import 'package:dsh_remote/gateway.dart';
import 'package:test/test.dart';

/// Builds a pairing string the way the gateway does (Base64URL, no padding).
String pairingText(Map<String, Object?> payload) =>
    base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');

Map<String, Object?> samplePayload({
  int version = 2,
  String publicUrl = 'wss://dsh.example.com:42429/ws/mobile',
  String pairingCode = 'abcDEF123_-xyz',
  int? expiresAt,
  List<String>? endpoints,
}) =>
    <String, Object?>{
      'version': version,
      'publicUrl': publicUrl,
      'pairingCode': pairingCode,
      'expiresAt': expiresAt ?? DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      'gatewayId': '8acd8064-e6c6-47b5-aac2-6cbe964d6580',
      'gatewayName': 'office-pc',
      'endpoints': ?endpoints,
    };

void main() {
  group('GatewayPairing.parse', () {
    test('decodes a v2 payload', () {
      final pairing = GatewayPairing.parse(pairingText(samplePayload()));

      expect(pairing.publicUrl.toString(), 'wss://dsh.example.com:42429/ws/mobile');
      expect(pairing.pairingCode, 'abcDEF123_-xyz');
      expect(pairing.gatewayId, '8acd8064-e6c6-47b5-aac2-6cbe964d6580');
      expect(pairing.gatewayName, 'office-pc');
      expect(pairing.label, 'office-pc');
      expect(pairing.isExpired(), isFalse);
    });

    test('keeps publicUrl first and de-duplicates endpoints', () {
      final pairing = GatewayPairing.parse(pairingText(samplePayload(endpoints: <String>[
        'ws://192.168.0.17:3081/ws/mobile',
        'wss://dsh.example.com:42429/ws/mobile',
        'ws://100.70.97.58:3081/ws/mobile',
      ])));

      expect(
        pairing.candidates.map((uri) => uri.toString()).toList(),
        <String>[
          'wss://dsh.example.com:42429/ws/mobile',
          'ws://192.168.0.17:3081/ws/mobile',
          'ws://100.70.97.58:3081/ws/mobile',
        ],
      );
    });

    test('rejects padding, plain Base64 and raw JSON', () {
      final encoded = pairingText(samplePayload());

      expect(
        () => GatewayPairing.parse('$encoded=='),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.notBase64Url)),
      );
      expect(
        () => GatewayPairing.parse(jsonEncode(samplePayload())),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.notBase64Url)),
      );
      expect(
        () => GatewayPairing.parse(''),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.empty)),
      );
    });

    test('rejects an unsupported version', () {
      expect(
        () => GatewayPairing.parse(pairingText(samplePayload(version: 1))),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.unsupportedVersion)),
      );
    });

    test('rejects a missing field', () {
      final payload = samplePayload()..remove('pairingCode');
      expect(
        () => GatewayPairing.parse(pairingText(payload)),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.missingField)),
      );
    });

    test('rejects an expired code', () {
      final expired = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
      expect(
        () => GatewayPairing.parse(pairingText(samplePayload(expiresAt: expired))),
        throwsA(isA<GatewayPairingException>()
            .having((e) => e.code, 'code', GatewayPairingErrorCode.expired)),
      );
    });

    test('round-trips through encode()', () {
      final original = GatewayPairing.parse(pairingText(samplePayload(endpoints: <String>[
        'ws://192.168.0.17:3081/ws/mobile',
      ])));
      final again = GatewayPairing.parse(original.encode());

      expect(again.publicUrl, original.publicUrl);
      expect(again.pairingCode, original.pairingCode);
      expect(again.expiresAt, original.expiresAt);
      expect(again.endpoints, original.endpoints);
    });
  });

  group('GatewayHandshake', () {
    test('reads capabilities and identity', () {
      final handshake = GatewayHandshake.fromFrame(<String, Object?>{
        'kind': 'hello',
        'protocol': 3,
        'capabilities': <Object?>['split-channels', 'images', 'session-archive'],
        'authenticated': true,
        'device': <String, Object?>{'id': 'dev-1', 'name': 'iPhone'},
        'port': 3080,
        'clients': 2,
      });

      expect(handshake.protocol, 3);
      expect(handshake.capabilities, contains('session-archive'));
      expect(handshake.has('images'), isTrue);
      expect(handshake.authenticated, isTrue);
      expect(handshake.deviceId, 'dev-1');
      expect(handshake.clients, 2);
    });
  });

  group('GatewayError', () {
    test('maps retryable host codes', () {
      expect(const GatewayError('agent-busy', 'busy').retryable, isTrue);
      expect(const GatewayError('bad-request', 'no').retryable, isFalse);
      expect(const GatewayError(GatewayFailureCode.timeout, 'slow').retryable, isTrue);
    });

    test('reads an error frame', () {
      final error = GatewayError.fromFrame(<String, Object?>{
        'kind': 'error',
        'code': 'session-not-found',
        'message': 'no such session',
        'requestType': 'history',
        'sessionId': 'session-abc',
      });

      expect(error.code, 'session-not-found');
      expect(error.requestType, 'history');
      expect(error.sessionId, 'session-abc');
    });
  });
}
