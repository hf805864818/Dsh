import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/gateway.dart';
import 'package:test/test.dart';

/// The cache decides whether a conversation can paint before the Host answers,
/// so its failure modes matter more than its happy path: a bad file must look
/// like no file, never like a broken opening frame.
void main() {
  late Directory dir;
  late GatewaySnapshotCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gw-snap-');
    cache = GatewaySnapshotCache(directory: dir, maxFiles: 3);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Map<String, Object?> frame(int cursor, {String text = 'hi'}) => <String, Object?>{
        'header': <String, Object?>{'id': 'session-1', 'version': 4},
        'cursor': cursor,
        'records': <Object?>[
          <String, Object?>{
            'event': <String, Object?>{
              'type': 'user/message',
              'seq': cursor,
              'time': 1,
              'data': <String, Object?>{'text': text},
            },
          },
        ],
        'hasMore': false,
        'projections': <String, Object?>{'values': <String, Object?>{'title': 'T'}},
      };

  test('a written frame reads back with its cursor', () async {
    await cache.write('session-1', frame(7));
    final cached = await cache.read('session-1');
    expect(cached, isNotNull);
    expect(cached!.cursor, 7);
    expect(cached.frame['records'], hasLength(1));
  });

  test('an unknown session has no frame', () async {
    expect(await cache.read('session-2'), isNull);
  });

  test('a corrupt file is treated as absent, not as an error', () async {
    await cache.write('session-1', frame(3));
    final file = File('${dir.path}${Platform.pathSeparator}session-1.json');
    await file.writeAsString('{not json');
    expect(await cache.read('session-1'), isNull);
  });

  test('a frame without records cannot open a conversation', () async {
    await cache.write('session-1', <String, Object?>{'cursor': 4});
    expect(await cache.read('session-1'), isNull);
  });

  test('a frame past staleAfter is not offered', () async {
    await cache.write('session-1', frame(9));
    final later = DateTime.now().add(const Duration(days: 30));
    expect(await cache.read('session-1', now: later), isNull);
  });

  test('session ids with separators stay inside the directory', () async {
    await cache.write('a/b\\c:d', frame(1));
    final names = await dir.list().map((entry) => entry.path.split(Platform.pathSeparator).last).toList();
    expect(names, hasLength(1));
    expect(names.single, isNot(contains('/')));
    expect(names.single, isNot(contains('\\')));
  });

  test('older files are evicted once maxFiles is exceeded', () async {
    for (var i = 0; i < 5; i++) {
      await cache.write('session-$i', frame(i));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    final names = await dir.list().where((entry) => entry is File).length;
    expect(names, lessThanOrEqualTo(3));
  });

  test('a frame larger than maxBytes is skipped', () async {
    final small = GatewaySnapshotCache(directory: dir, maxBytes: 64);
    await small.write('session-1', frame(1, text: 'x' * 400));
    expect(await small.read('session-1'), isNull);
  });

  test('what is written is valid JSON with the frame shape', () async {
    await cache.write('session-1', frame(11));
    final raw = await File('${dir.path}${Platform.pathSeparator}session-1.json').readAsString();
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    expect(decoded['cursor'], 11);
    expect(decoded['header'], isA<Map<String, Object?>>());
  });
}
