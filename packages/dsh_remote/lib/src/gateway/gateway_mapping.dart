/// Pure translations between DSH endpoint payloads and gateway frames.
///
/// The carrier's dispatcher is untestable on its own (a `GatewayClient` needs a
/// socket), and every bug this file prevents was silent: a prompt whose text
/// never left the device, a queue action the gateway rejected, an approval
/// outcome it did not recognise. Keeping the arithmetic here lets the shapes be
/// asserted without a Host.
library;

/// Splits DSH's `session/prompt` payload into the gateway's `message` params.
///
/// DSH sends `request.content` parts — text, images, file receipts — plus
/// `mode` and `clientTimeZone`; the gateway wants `text`, `images`, `files` and
/// the rest at the top level.
Map<String, Object?> promptMessageParams(Map<String, Object?> args, {String? sessionId}) {
  final request = _map(args['request']) ?? args;
  final text = _promptText(request);
  final images = <Object?>[];
  final files = <Object?>[];

  // `content` is the current wire name; `parts` was the older one.
  final content = request['content'] ?? request['parts'];
  if (content is List) {
    for (final part in content) {
      final map = _map(part);
      if (map == null) continue;
      switch (map['type']) {
        case 'image':
          images.add(map);
        case 'file':
          files.add(<String, Object?>{'receiptId': map['receiptId']});
      }
    }
  }

  return <String, Object?>{
    'sessionId': ?sessionId,
    'text': ?(text ?? _string(request['text'])),
    if (images.isNotEmpty) 'images': images,
    if (files.isNotEmpty) 'files': files,
    'mode': ?_string(request['mode']),
    'clientTimeZone': ?_string(request['clientTimeZone']),
  };
}

/// The plain text of a prompt: `text` first, else the concatenated `text` parts
/// of `content` (or the older `parts`).
String? _promptText(Map<String, Object?> request) {
  final direct = _string(request['text']);
  if (direct != null) return direct;

  final parts = request['content'] ?? request['parts'];
  if (parts is! List) return null;
  final buffer = StringBuffer();
  for (final part in parts) {
    final map = _map(part);
    if (map == null || map['type'] != 'text') continue;
    final text = _string(map['text']);
    if (text != null) buffer.write(text);
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// DSH's `session/updateQueue` action map → the gateway's verb plus text.
Map<String, Object?> queueUpdateParams(Map<String, Object?> args, {String? sessionId}) {
  final request = _map(args['request']) ?? args;
  final action = _map(request['action']);
  final kind = _string(action?['kind']) ?? _string(request['action']) ?? 'edit';
  var text = _string(request['text']);
  if (text == null) {
    final content = action?['content'];
    if (content is List && content.isNotEmpty) {
      text = _string(_map(content.first)?['text']);
    }
  }
  return <String, Object?>{
    'sessionId': ?(sessionId ?? _string(request['sessionId'])),
    'itemId': ?_string(request['itemId']),
    'action': kind,
    'text': ?text,
  };
}

/// DSH's outcome map → the gateway's `allowed-once` / `rejected`.
///
/// DSH names the decision field differently per surface (`outcome`, `decision`,
/// `value`), and the gateway only takes those two words.
String approvalOutcome(Object? value) {
  final map = _map(value);
  final raw = _string(map?['outcome']) ?? _string(map?['decision']) ?? _string(map?['value']);
  if (raw == null) return 'rejected';
  return raw.contains('reject') || raw.contains('deny') ? 'rejected' : 'allowed-once';
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.map((key, value) => MapEntry('$key', value)) : null;

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;
