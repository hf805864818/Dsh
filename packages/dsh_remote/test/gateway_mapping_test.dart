import 'package:dsh_remote/gateway.dart';
import 'package:test/test.dart';

/// The carrier's dispatcher cannot be reached without a socket, and every shape
/// here has been wrong once in a way that compiled and tested green: a prompt
/// that left the device empty, a queue action the gateway rejected. These check
/// the translation itself.
void main() {
  group('promptMessageParams', () {
    test('takes the text out of content parts and keeps the rest', () {
      final params = promptMessageParams(
        <String, Object?>{
          'request': <String, Object?>{
            'sessionId': 'session-1',
            'mode': 'queue',
            'clientTimeZone': 'Asia/Shanghai',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'hello '},
              <String, Object?>{'type': 'text', 'text': 'world'},
              <String, Object?>{'type': 'image', 'mediaType': 'image/png', 'data': 'AAAA'},
              <String, Object?>{'type': 'file', 'receiptId': 'receipt-1'},
            ],
          },
        },
        sessionId: 'session-1',
      );

      expect(params['text'], 'hello world');
      expect(params['sessionId'], 'session-1');
      expect(params['mode'], 'queue');
      expect(params['clientTimeZone'], 'Asia/Shanghai');
      expect(params['images'], hasLength(1));
      expect(params['files'], <Object?>[
        <String, Object?>{'receiptId': 'receipt-1'},
      ]);
    });

    test('carries requestId so the Host can echo the optimistic bubble', () {
      final params = promptMessageParams(<String, Object?>{
        'request': <String, Object?>{
          'requestId': 'req-42',
          'sessionId': 'session-1',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'hi'},
          ],
        },
      });
      // Without this the gateway's `user/message` event has no requestId and
      // the composer stays on "sending" even though the turn ran.
      expect(params['requestId'], 'req-42');
    });

    test('accepts the older parts name and ignores non-text parts', () {
      final params = promptMessageParams(<String, Object?>{
        'request': <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'legacy'},
            <String, Object?>{'type': 'image', 'data': 'AAAA'},
          ],
        },
      });
      expect(params['text'], 'legacy');
      expect(params.containsKey('images'), isTrue);
    });

    test('a turn with no text keeps images but omits an empty text', () {
      final params = promptMessageParams(<String, Object?>{
        'request': <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'image', 'data': 'AAAA'},
          ],
        },
      });
      expect(params.containsKey('text'), isFalse);
      expect(params['images'], hasLength(1));
    });
  });

  group('queueUpdateParams', () {
    test('turns the action map into a verb and the edited text', () {
      final params = queueUpdateParams(<String, Object?>{
        'request': <String, Object?>{
          'sessionId': 'session-1',
          'itemId': 'item-1',
          'action': <String, Object?>{
            'kind': 'edit',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'edited text'},
            ],
          },
        },
      });
      expect(params['action'], 'edit');
      expect(params['text'], 'edited text');
      expect(params['itemId'], 'item-1');
      expect(params['sessionId'], 'session-1');
    });

    test('remove and steer carry no text', () {
      for (final kind in <String>['remove', 'steer']) {
        final params = queueUpdateParams(<String, Object?>{
          'request': <String, Object?>{
            'itemId': 'item-2',
            'action': <String, Object?>{'kind': kind},
          },
        });
        expect(params['action'], kind);
        expect(params.containsKey('text'), isFalse);
      }
    });
  });

  group('approvalOutcome', () {
    test('maps the three field names DSH uses', () {
      expect(approvalOutcome(<String, Object?>{'outcome': 'allowed-once'}), 'allowed-once');
      expect(approvalOutcome(<String, Object?>{'decision': 'rejected'}), 'rejected');
      expect(approvalOutcome(<String, Object?>{'value': 'deny'}), 'rejected');
    });

    test('anything unusable is a rejection, never an approval', () {
      expect(approvalOutcome(null), 'rejected');
      expect(approvalOutcome(<String, Object?>{}), 'rejected');
      expect(approvalOutcome('nonsense'), 'rejected');
    });
  });
}
