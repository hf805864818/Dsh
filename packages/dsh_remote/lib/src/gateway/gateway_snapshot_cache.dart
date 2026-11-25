/// Last follow snapshot per session, kept on disk so a conversation can paint
/// before the Host answers.
///
/// `DshClient` refuses to render until a follow stream opens with a snapshot
/// (`follow opened without snapshot`), so a cold open waits for the Host no
/// matter how the connection is made. Handing the previous snapshot over as the
/// opening frame makes the screen show what it showed last time, and the live
/// page is then merged on top by `seq` — `ChatTranscript` is idempotent for
/// exactly this reason.
///
/// This is a cache: unreadable, oversized or unrelated files are ignored rather
/// than reported, and it never writes outside its own directory.
library;

import 'dart:convert';
import 'dart:io';

/// One cached snapshot, with the moment it was stored.
class CachedSnapshot {
  const CachedSnapshot(this.frame, this.storedAt);

  final Map<String, Object?> frame;
  final DateTime storedAt;

  int get cursor {
    final value = frame['cursor'];
    return value is int ? value : -1;
  }
}

/// Stores follow snapshots as one JSON file per session.
class GatewaySnapshotCache {
  GatewaySnapshotCache({
    Directory? directory,
    this.staleAfter = const Duration(days: 14),
    this.maxFiles = 60,
    this.maxBytes = 4 * 1024 * 1024,
  }) : directory = directory ??
            Directory('${Directory.systemTemp.path}${Platform.pathSeparator}gw_snapshots');

  /// Where the files live. Created on first write.
  final Directory directory;

  /// Entries older than this are not offered as an opening frame.
  final Duration staleAfter;

  /// Beyond this many files the least recently written ones are removed.
  final int maxFiles;

  /// A frame larger than this is not cached; the Host page is capped anyway.
  final int maxBytes;

  File _fileFor(String sessionId) {
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${directory.path}${Platform.pathSeparator}$safe.json');
  }

  /// The stored snapshot for [sessionId], or null when there is none usable.
  Future<CachedSnapshot?> read(String sessionId, {DateTime? now}) async {
    try {
      final file = _fileFor(sessionId);
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final storedAt = stat.modified;
      if ((now ?? DateTime.now()).difference(storedAt) > staleAfter) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final frame = decoded.map((key, value) => MapEntry('$key', value));
      // A frame without records or a cursor cannot open a conversation.
      if (frame['records'] is! List) return null;
      return CachedSnapshot(frame, storedAt);
    } on Object {
      return null;
    }
  }

  /// Keeps [frame] as the opening frame for [sessionId].
  Future<void> write(String sessionId, Map<String, Object?> frame) async {
    try {
      final encoded = jsonEncode(frame);
      if (encoded.length > maxBytes) return;
      await directory.create(recursive: true);
      final file = _fileFor(sessionId);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
      await _evict();
    } on Object {
      // A cache that cannot be written is not an error the caller can act on.
    }
  }

  /// Removes the oldest files once [maxFiles] is exceeded.
  Future<void> _evict() async {
    try {
      final files = <File>[];
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.endsWith('.json')) files.add(entry);
      }
      if (files.length <= maxFiles) return;
      final stamped = <(File, DateTime)>[];
      for (final file in files) {
        stamped.add((file, (await file.stat()).modified));
      }
      stamped.sort((a, b) => a.$2.compareTo(b.$2));
      for (final entry in stamped.take(files.length - maxFiles)) {
        await entry.$1.delete();
      }
    } on Object {
      // Eviction is best effort.
    }
  }
}
