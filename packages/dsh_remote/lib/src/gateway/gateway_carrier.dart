/// A [DshCarrier] backed by one Mobile Gateway WebSocket.
///
/// `DshCarrier` sits *below* `DshRpc`/`DshMux`, so mapping the gateway's own
/// frame vocabulary onto DSH endpoints keeps every screen above this file
/// unchanged. Endpoints the gateway cannot serve are refused through
/// [allowsEndpoint], which turns them into `METHOD_NOT_ALLOWED` instead of
/// throwing — the UI already degrades on that code.
///
/// Shapes below were captured from a live gateway (0.12.2 / DSH 0.2.2-rc.5):
/// * `sessions`  → `{"items":[{sessionId, updatedAt, running, blank,
///   agentAvailable, cwd, projections:{asOfSeq, values:{title}}}]}` — already
///   the exact shape `SessionSummary.fromJson` expects.
/// * `history`   → `{"events":[...raw SessionEvent...], "hasMore":bool}`
///   while DSH wants `{"records":[{"event":…}], "hasMore":bool}`.
/// * `event`     → `{"sessionId","seq","time","event":{type,…}}` which becomes
///   a follow item `{"type":"event","event":{type,seq,time,data}}`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_client/dsh_client.dart';

import 'gateway_client.dart';
import 'gateway_frames.dart';

/// Endpoints this carrier answers.
const Set<String> _servedEndpoints = <String>{
  'session/list',
  'session/page',
  'session/rename',
  'session/prompt',
  'session/cancel',
  'session/search',
  'session/attachment',
  'workspace/archiveSession',
  'userQuestions/answer',
  r'$events/result',
  'session/modelCatalog',
  'session/selectModel',
  'llm/listProviders',
  'session/projections',
  'session/fork',
  'session/updateQueue',
  'workspace/list',
  'commands/execute',
  'permissionPresets/catalog',
  'directoryPicker/list',
  'directoryPicker/createDirectory',
  'workspace/create',
  'session/create',
  'fileUploads/upload',
  'workspaceFiles/stat',
  'workspaceFiles/readBytes',
  'goals/get',
  'schedule/catalog',
  'speech/catalog',
  'speech/transcribe',
  'speech/configure',
  'speech/prepare',
  'speech/cancelPreparation',
};

/// A gateway connection presented as a `DshCarrier`.
class GatewayCarrier implements DshCarrier {
  GatewayCarrier(this._client, {this.deviceId, this.gatewayLabel});

  final GatewayClient _client;

  /// Install-level device id presented on the wire.
  final String? deviceId;

  /// Display name for diagnostics.
  final String? gatewayLabel;

  /// Cached `sessions` reply, so `session/projections` can be answered without
  /// another round trip.
  final Map<String, Map<String, Object?>> _sessionCache = <String, Map<String, Object?>>{};

  GatewayClient get client => _client;

  @override
  String get kind => 'gateway';

  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => _servedEndpoints.contains(endpoint);

  @override
  Set<String>? get peerCapabilities => _client.capabilities.toSet();

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    try {
      final value = await _dispatch(endpoint, args, timeout);
      return RpcOk(value);
    } on GatewayError catch (error) {
      return RpcError(DshRemoteException(error.code, error.message, _details(error)));
    } on DshRemoteException catch (error) {
      return RpcError(error);
    }
  }

  Future<Object?> _dispatch(String endpoint, Map<String, Object?> args, Duration? timeout) async {
    switch (endpoint) {
      case 'session/list':
        final frame = await _client.request(GatewayRequest.sessions, timeout: _or(timeout));
        final items = asGatewayMaps(frame['items']);
        for (final item in items) {
          final id = gatewayString(item, 'sessionId');
          if (id != null) _sessionCache[id] = item;
        }
        return <String, Object?>{'items': items};

      case 'session/page':
        final request = asGatewayMap(args['request']) ?? const <String, Object?>{};
        final sessionId = _sessionIdOf(request);
        if (sessionId == null) {
          throw const DshRemoteException('gateway/bad-request', 'session/page needs a session address');
        }
        // Gateway pages by `beforeSeq` only; DSH passes `throughSeq` as well.
        final beforeSeq = args['beforeSeq'] ?? request['beforeSeq'];
        final maxMessages = request['maxMessages'] ?? args['maxMessages'];
        final frame = await _client.request(
          GatewayRequest.history,
          params: <String, Object?>{
            'sessionId': sessionId,
            'maxMessages': maxMessages is int ? maxMessages : 60,
            'view': 'conversation',
            if (beforeSeq is int) 'beforeSeq': beforeSeq,
            if (beforeSeq is int) 'historyFormatVersion': 4,
          },
          timeout: _or(timeout),
        );
        final events = GatewayClient.historyEvents(frame);
        return <String, Object?>{
          'records': <Object?>[
            for (final event in events) <String, Object?>{'event': event},
          ],
          'hasMore': frame['hasMore'] == true,
        };

      case 'session/rename':
        final sessionId = gatewayString(args, 'sessionId') ?? gatewayString(args, 'address');
        final title = gatewayString(args, 'title') ?? gatewayString(args, 'name');
        final frame = await _client.request(
          GatewayRequest.sessionRename,
          params: <String, Object?>{'sessionId': ?sessionId, 'title': ?title},
          // Reply kind is `session-renamed`; DSH reads `title` back.
          expect: <String>{GatewayKind.sessionRenamed},
          timeout: _or(timeout),
        );
        return <String, Object?>{'title': gatewayString(frame, 'title') ?? title};

      case 'session/prompt':
        // DSH sends the turn as `request.content` parts (text, images, file
        // receipts) plus `mode`; the gateway's `message` wants those split out.
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        final request = asGatewayMap(args['request']) ?? args;
        final text = gatewayString(request, 'text') ?? _promptText(request);
        final images = <Object?>[];
        final files = <Object?>[];
        final content = request['content'];
        if (content is List) {
          for (final part in content) {
            final map = asGatewayMap(part);
            if (map == null) continue;
            switch (gatewayString(map, 'type')) {
              case 'image':
                images.add(map);
              case 'file':
                files.add(<String, Object?>{'receiptId': gatewayString(map, 'receiptId')});
            }
          }
        }
        await _client.request(
          GatewayRequest.message,
          params: <String, Object?>{
            'sessionId': ?sessionId,
            'text': ?text,
            if (images.isNotEmpty) 'images': images,
            if (files.isNotEmpty) 'files': files,
            'mode': ?gatewayString(request, 'mode'),
            'clientTimeZone': ?gatewayString(request, 'clientTimeZone'),
          },
          expect: _promptExpect(),
          timeout: _or(timeout),
        );
        return null;

      case 'session/cancel':
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        await _client.request(
          GatewayRequest.sessionCancel,
          params: <String, Object?>{'sessionId': ?sessionId},
          expect: <String>{GatewayKind.sessionCancelled},
          timeout: _or(timeout),
        );
        return null;

      case 'workspace/archiveSession':
        final sessionId = gatewayString(args, 'sessionId') ?? _sessionIdOf(args);
        final frame = await _client.request(
          GatewayRequest.sessionArchive,
          params: <String, Object?>{'sessionId': ?sessionId},
          expect: <String>{GatewayKind.sessionArchived},
          timeout: _or(timeout),
        );
        return <String, Object?>{'archivedSessionIds': frame['archivedSessionIds'] ?? const <Object?>[]};

      case 'session/search':
        final query = gatewayString(args, 'query') ?? gatewayString(args, 'text') ?? '';
        final frame = await _client.request(
          GatewayRequest.search,
          params: <String, Object?>{'query': query},
          expect: <String>{GatewayKind.search},
          timeout: _or(timeout),
        );
        return <String, Object?>{
          'items': frame['items'] ?? const <Object?>[],
          'hasMore': frame['hasMore'] == true,
        };

      case 'session/attachment':
        final sessionId = _sessionIdOf(args) ?? gatewayString(args, 'sessionId');
        final attachmentId = gatewayString(args, 'attachmentId') ?? gatewayString(args, 'id');
        final frame = await _client.request(
          GatewayRequest.attachment,
          params: <String, Object?>{
            'sessionId': ?sessionId,
            'attachmentId': ?attachmentId,
            if (args['attachment'] != null) 'attachment': args['attachment'],
          },
          timeout: _or(timeout),
        );
        // DSH reads `{attachment, data}`; the gateway frame already is that.
        return frame;

      case 'session/projections':
        // Four projection reads, merged. A projection the gateway refused must
        // not fail the whole read: the caller renders what it got.
        final projectionsRequest = asGatewayMap(args['request']) ?? args;
        final projectionsSession = _sessionIdOf(projectionsRequest) ?? gatewayString(projectionsRequest, 'sessionId');
        if (projectionsSession == null) {
          throw const DshRemoteException('gateway/bad-request', 'session/projections needs a session');
        }
        final values = <String, Object?>{};
        // Base: the projections the `sessions` row already carried (title,
        // permissions, modelSelection, inbox...), so the panel is populated
        // even before the live reads land.
        final cachedProjections = asGatewayMap(_sessionCache[projectionsSession]?['projections']);
        final cachedValues = asGatewayMap(cachedProjections?['values']);
        if (cachedValues != null) values.addAll(cachedValues);
        var asOfSeq = gatewayInt(cachedProjections ?? const <String, Object?>{}, 'asOfSeq') ?? 0;
        Future<void> take(String type, String kind, Map<String, String> keys) async {
          try {
            final reply = await _client.request(
              type,
              params: <String, Object?>{'sessionId': projectionsSession},
              expect: <String>{kind},
              timeout: _or(timeout),
            );
            final seq = gatewayInt(reply, 'asOfSeq');
            if (seq != null && seq > asOfSeq) asOfSeq = seq;
            for (final entry in keys.entries) {
              final value = reply[entry.value];
              if (value != null) values[entry.key] = value;
            }
          } on Object {
            // Absent projection: leave the key out.
          }
        }

        await Future.wait(<Future<void>>[
          take(GatewayRequest.contextUsage, 'context-usage', <String, String>{
            'tokenUsage': 'tokenUsage',
            'contextPressure': 'contextPressure',
          }),
          take(GatewayRequest.sessionStats, 'session-stats', <String, String>{'sessionStats': 'sessionStats'}),
          take(GatewayRequest.tasksList, 'tasks', <String, String>{'todos': 'todos'}),
          take(GatewayRequest.goalInfo, 'goal', <String, String>{'goal': 'goal'}),
        ]);
        return <String, Object?>{'asOfSeq': asOfSeq, 'values': values};

      case 'session/fork':
        final forkRequest = asGatewayMap(args['request']) ?? args;
        final reply = await _client.request(
          GatewayRequest.fork,
          params: <String, Object?>{
            'sessionId': ?_sessionIdOf(forkRequest),
            'atSeq': ?(forkRequest['atSeq'] is int ? forkRequest['atSeq'] as int : null),
          },
          expect: <String>{'fork'},
          timeout: _or(timeout),
        );
        return <String, Object?>{'sessionId': gatewayString(reply, 'sessionId') ?? ''};

      case 'session/updateQueue':
        // DSH sends `action` as a map (`{kind, content}`); the gateway wants
        // the plain verb plus the edited text.
        final queueRequest = asGatewayMap(args['request']) ?? args;
        final action = asGatewayMap(queueRequest['action']);
        final kind = gatewayString(action ?? const <String, Object?>{}, 'kind') ??
            gatewayString(queueRequest, 'action') ??
            'edit';
        var text = gatewayString(queueRequest, 'text');
        if (text == null) {
          final content = action?['content'];
          if (content is List && content.isNotEmpty) {
            text = gatewayString(asGatewayMap(content.first) ?? const <String, Object?>{}, 'text');
          }
        }
        await _client.request(
          GatewayRequest.queueUpdate,
          params: <String, Object?>{
            'sessionId': ?_sessionIdOf(queueRequest),
            'itemId': ?gatewayString(queueRequest, 'itemId'),
            'action': kind,
            'text': ?text,
          },
          timeout: _or(timeout),
        );
        return null;

      case 'workspace/list':
        final reply = await _client.request(
          GatewayRequest.workspaces,
          expect: <String>{'workspaces'},
          timeout: _or(timeout),
        );
        return reply['workspaces'] ?? reply['items'] ?? reply;

      case 'session/create':
        // The gateway wants a requestId for this one; DSH only sends options.
        final createRequest = asGatewayMap(args['request']) ?? args;
        final reply = await _client.request(
          GatewayRequest.sessionCreate,
          params: <String, Object?>{
            'requestId': 'create-${DateTime.now().microsecondsSinceEpoch}',
            'workspaceId': ?gatewayString(createRequest, 'workspaceId'),
            'cwd': ?gatewayString(createRequest, 'cwd'),
            'sessionId': ?gatewayString(createRequest, 'sessionId'),
            'agentPreset': ?gatewayString(createRequest, 'agentPreset'),
          },
          expect: <String>{'session-created'},
          timeout: _or(timeout),
        );
        return <String, Object?>{
          'sessionId': gatewayString(reply, 'sessionId') ?? '',
          'agentPreset': gatewayString(reply, 'agentPreset'),
        };

      case 'directoryPicker/list':
        // The gateway's `directories` reply already carries path/home/entries.
        final reply = await _client.request(
          GatewayRequest.directories,
          params: <String, Object?>{'path': ?gatewayString(args, 'path')},
          expect: <String>{'directories'},
          timeout: _or(timeout),
        );
        return reply;

      case 'directoryPicker/createDirectory':
        final reply = await _client.request(
          GatewayRequest.directoryCreate,
          params: <String, Object?>{
            'path': ?gatewayString(args, 'path'),
            'name': ?gatewayString(args, 'name'),
          },
          expect: <String>{'directory-created', 'directories'},
          timeout: _or(timeout),
        );
        return gatewayString(reply, 'path') ?? reply['path'];

      case 'workspace/create':
        final workspaceRequest = asGatewayMap(args['request']) ?? args;
        final reply = await _client.request(
          GatewayRequest.workspaceCreate,
          params: <String, Object?>{'path': ?gatewayString(workspaceRequest, 'path')},
          expect: <String>{'workspace-create', 'workspaces'},
          timeout: _or(timeout),
        );
        return reply;

      case 'fileUploads/upload':
        // DSH sends the whole file as one base64 frame; the gateway wants a
        // sha256, then open / chunk… / finish.
        final uploadSession = gatewayString(args, 'agentId') ?? _sessionIdOf(args);
        final uploadRequest = asGatewayMap(args['request']) ?? args;
        final uploadName = gatewayString(uploadRequest, 'name') ?? 'upload.bin';
        final uploadBytes = base64Decode(gatewayString(uploadRequest, 'data') ?? '');
        final uploadRequestId = 'upload-${DateTime.now().microsecondsSinceEpoch}';
        final open = await _client.request(
          GatewayRequest.fileUploadOpen,
          params: <String, Object?>{
            'requestId': uploadRequestId,
            'sessionId': ?uploadSession,
            'name': uploadName,
            'size': uploadBytes.length,
            'sha256': crypto.sha256.convert(uploadBytes).toString(),
          },
          expect: <String>{GatewayKind.fileUploadOpened},
          timeout: const Duration(minutes: 2),
        );
        final uploadId = gatewayString(open, 'uploadId');
        if (uploadId == null) {
          throw const DshRemoteException('gateway/file-upload', '网关没有返回 uploadId。');
        }
        final chunkBytes = gatewayInt(open, 'chunkBytes') ?? 256 * 1024;
        var sent = 0;
        while (sent < uploadBytes.length) {
          final end = sent + chunkBytes > uploadBytes.length ? uploadBytes.length : sent + chunkBytes;
          await _client.request(
            GatewayRequest.fileUploadChunk,
            params: <String, Object?>{
              'requestId': uploadRequestId,
              'uploadId': uploadId,
              'sessionId': ?uploadSession,
              'offset': sent,
              'data': base64Encode(uploadBytes.sublist(sent, end)),
            },
            expect: <String>{GatewayKind.fileUploadChunkAccepted},
            timeout: const Duration(minutes: 2),
          );
          sent = end;
        }
        final finished = await _client.request(
          GatewayRequest.fileUploadFinish,
          params: <String, Object?>{
            'requestId': uploadRequestId,
            'uploadId': uploadId,
            'sessionId': ?uploadSession,
          },
          expect: <String>{GatewayKind.fileUploadCompleted},
          timeout: const Duration(minutes: 5),
        );
        return <String, Object?>{
          'receiptId': gatewayString(finished, 'receiptId'),
          'file': finished['file'],
        };

      case 'workspaceFiles/stat':
        final statPath = gatewayString(args, 'path') ?? '';
        final resolved = await _client.request(
          GatewayRequest.fileResolve,
          params: <String, Object?>{
            'sessionId': ?gatewayString(args, 'workspaceFileScopeId'),
            'path': statPath,
          },
          expect: <String>{GatewayKind.fileResolved},
          timeout: _or(timeout),
        );
        return <String, Object?>{
          'absolutePath': gatewayString(resolved, 'path') ?? statPath,
          'version': '${gatewayInt(resolved, 'modifiedAt') ?? 0}',
          'bytes': gatewayInt(resolved, 'size'),
        };

      case 'workspaceFiles/readBytes':
        // One transfer per path, read forward; DSH asks window by window.
        final readPath = gatewayString(args, 'path') ?? '';
        final readSession = gatewayString(args, 'workspaceFileScopeId');
        final options = asGatewayMap(args['options']);
        final range = asGatewayMap(options?['range']);
        final wantedOffset = gatewayInt(range ?? const <String, Object?>{}, 'offset') ?? 0;
        final wantedLength = gatewayInt(range ?? const <String, Object?>{}, 'length') ?? 1 << 20;
        final transfer = await _transferFor(readSession, readPath);
        final want = wantedOffset + wantedLength;
        while (transfer.buffered.length < want && !transfer.eof) {
          final chunk = await _client.request(
            GatewayRequest.fileDownloadRead,
            params: <String, Object?>{'transferId': transfer.transferId, 'offset': transfer.buffered.length},
            expect: <String>{GatewayKind.fileDownloadChunk},
            timeout: const Duration(minutes: 2),
          );
          final data = gatewayString(chunk, 'data');
          if (data == null || data.isEmpty) {
            transfer.eof = true;
          } else {
            transfer.buffered.add(base64Decode(data));
          }
          if (chunk['eof'] == true) transfer.eof = true;
        }
        final bytesOut = transfer.buffered.takeBytes();
        final from = wantedOffset < bytesOut.length ? wantedOffset : bytesOut.length;
        final to = want < bytesOut.length ? want : bytesOut.length;
        final window = bytesOut.sublist(from, to);
        // Keep what is left for the next window.
        transfer.buffered.add(bytesOut.sublist(to));
        return <String, Object?>{
          'version': transfer.version,
          'data': base64Encode(window),
          'bytes': to,
          'eof': transfer.eof && to >= bytesOut.length,
        };

      case 'goals/get':
        // The gateway's goal projection already carries the snapshot; flatten
        // it so GoalSnapshot.fromJson sees `ref`/`objective`/`phase` on top.
        final goalSession = gatewayString(args, 'agentId') ?? _sessionIdOf(args);
        final goalReply = await _client.request(
          GatewayRequest.goalInfo,
          params: <String, Object?>{'sessionId': ?goalSession},
          expect: <String>{'goal'},
          timeout: _or(timeout),
        );
        final projection = asGatewayMap(goalReply['goal']);
        final snapshot = asGatewayMap(projection?['goal']);
        if (projection == null || snapshot == null) return null;
        return <String, Object?>{
          ...snapshot,
          if (projection['roundsStarted'] != null) 'roundsStarted': projection['roundsStarted'],
          if (projection['createdAt'] != null) 'createdAt': projection['createdAt'],
          if (projection['updatedAt'] != null) 'updatedAt': projection['updatedAt'],
        };

      case 'speech/catalog':
        final catalog = await _client.request(
          GatewayRequest.speechCatalog,
          expect: <String>{GatewayKind.speechCatalog},
          timeout: _or(timeout),
        );
        return catalog;

      case 'speech/transcribe':
        // DSH nests the audio under `request`; the gateway reads it at the top.
        final speechRequest = asGatewayMap(args['request']) ?? args;
        final transcript = await _client.request(
          GatewayRequest.speechTranscribe,
          params: <String, Object?>{
            'audioBase64': ?gatewayString(speechRequest, 'audioBase64'),
            'providerId': ?gatewayString(speechRequest, 'providerId'),
            'language': ?gatewayString(speechRequest, 'language'),
          },
          expect: <String>{GatewayKind.speechTranscribe},
          timeout: timeout ?? const Duration(minutes: 3),
        );
        return <String, Object?>{
          'text': gatewayString(transcript, 'text') ?? '',
          'audioSeconds': transcript['audioSeconds'] ?? 0,
        };

      case 'speech/configure':
        final patch = asGatewayMap(args['patch']) ?? const <String, Object?>{};
        await _client.request(
          GatewayRequest.speechConfigure,
          params: <String, Object?>{
            'providerId': ?gatewayString(patch, 'providerId'),
            'language': ?gatewayString(patch, 'language'),
          },
          expect: <String>{'speech-configured', 'speech-configure'},
          timeout: _or(timeout),
        );
        return null;

      case 'speech/prepare':
        final prepareOptions = asGatewayMap(args['options']);
        await _client.request(
          GatewayRequest.speechPrepare,
          params: <String, Object?>{
            'providerId': ?gatewayString(args, 'providerId'),
            'options': ?prepareOptions,
          },
          expect: <String>{'speech-prepared', 'speech-prepare'},
          timeout: _or(timeout),
        );
        return null;

      case 'speech/cancelPreparation':
        await _client.request(
          GatewayRequest.speechCancelPreparation,
          params: <String, Object?>{'providerId': ?gatewayString(args, 'providerId')},
          expect: <String>{'speech-preparation-cancelled', 'speech-cancel-preparation'},
          timeout: _or(timeout),
        );
        return null;

      case 'schedule/catalog':
        // DSH wants a plain list; the gateway spreads its catalog into the frame.
        final catalog = await _client.request(
          GatewayRequest.scheduleCatalog,
          expect: <String>{GatewayKind.scheduleCatalog},
          timeout: _or(timeout),
        );
        return catalog['catalog'] ?? catalog['tasks'] ?? catalog['items'] ?? const <Object?>[];

      case 'commands/execute':
        // Slash commands as typed in the composer; `/compact` is the long one.
        final commandSession = gatewayString(args, 'agentId') ?? gatewayString(args, 'sessionId');
        final line = gatewayString(args, 'line') ?? '';
        final compact = line.trim().startsWith('/compact');
        final reply = await _client.request(
          GatewayRequest.commandExecute,
          params: <String, Object?>{'sessionId': ?commandSession, 'line': line},
          expect: <String>{'command-executed'},
          timeout: compact ? const Duration(minutes: 30) : _or(timeout),
        );
        final result = asGatewayMap(reply['result']) ?? const <String, Object?>{};
        return <String, Object?>{
          'commandId': gatewayString(reply, 'commandId'),
          'result': <String, Object?>{
            'kind': gatewayString(result, 'kind') ?? 'success',
            if (result['text'] != null) 'text': result['text'],
          },
        };

      case 'permissionPresets/catalog':
        // The gateway already answers the catalog shape this reads.
        final reply = await _client.request(
          GatewayRequest.permissionOptions,
          expect: <String>{'permission-options'},
          timeout: _or(timeout),
        );
        return <String, Object?>{
          'options': reply['options'] ?? const <Object?>[],
          'defaultOptions': reply['defaultOptions'] ?? reply['options'] ?? const <Object?>[],
          'defaultPreset': reply['defaultPreset'] ?? '',
        };

      case 'session/modelCatalog':
        // The gateway's `models` groups are already the shape ModelCatalog
        // reads; `current` is the session's selection.
        final reply = await _client.request(
          GatewayRequest.models,
          expect: <String>{GatewayKind.models},
          timeout: _or(timeout),
        );
        final groups = asGatewayMaps(reply['groups']);
        return <String, Object?>{
          'groups': groups,
          'default': reply['current'],
          'routableProviders': <String>[
            for (final group in groups)
              if (gatewayString(group, 'id') != null) gatewayString(group, 'id')!,
          ],
        };

      case 'session/selectModel':
        final request = asGatewayMap(args['request']) ?? args;
        final reply = await _client.request(
          GatewayRequest.selectModel,
          params: <String, Object?>{
            'sessionId': ?_sessionIdOf(request),
            'provider': ?gatewayString(request, 'provider'),
            'model': ?gatewayString(request, 'model'),
            'reasoningEffort': ?gatewayString(request, 'reasoningEffort'),
          },
          expect: <String>{GatewayKind.selectModel},
          timeout: _or(timeout),
        );
        return <String, Object?>{'selected': reply['selected'] ?? reply};

      case 'llm/listProviders':
        final reply = await _client.request(
          GatewayRequest.providers,
          expect: <String>{GatewayKind.providers},
          timeout: _or(timeout),
        );
        return reply['providers'] ?? reply['items'] ?? const <Object?>[];

      case 'userQuestions/answer':
        // `{agentId, callId, answer: {answers}}`: the gateway frames carry no
        // callId, so the pending question for that session is the target.
        final agentId = gatewayString(args, 'agentId') ?? gatewayString(args, 'sessionId');
        final pending = _pendingQuestionFor(agentId);
        if (pending == null) {
          throw const DshRemoteException('gateway/no-pending-question', '没有等待回答的提问。');
        }
        final answer = asGatewayMap(args['answer']) ?? const <String, Object?>{};
        await _client.request(
          GatewayRequest.questionAnswer,
          params: <String, Object?>{
            'rpcId': pending.rpcId,
            'sessionId': pending.sessionId,
            'answers': answer['answers'] ?? const <Object?>[],
          },
          // The reply is `question-response`, not the request's own kind.
          expect: <String>{GatewayKind.questionResponse},
          timeout: const Duration(seconds: 20),
        );
        _pendingRequests.remove(pending.rpcId);
        return true;

      case r'$events/result':
        // `{clientId, eventId, outcome}`: approvals are answered from their card.
        final eventId = gatewayString(args, 'eventId');
        final pending = eventId == null ? null : _pendingRequests[eventId];
        if (pending == null) return null;
        await _client.request(
          GatewayRequest.approvalResponse,
          params: <String, Object?>{
            'rpcId': pending.rpcId,
            'sessionId': pending.sessionId,
            if (pending.approvalId != null) 'approvalId': pending.approvalId,
            'outcome': _approvalOutcome(args['outcome']),
          },
          timeout: const Duration(seconds: 20),
        );
        _pendingRequests.remove(pending.rpcId);
        return null;

      default:
        throw DshRemoteException('METHOD_NOT_ALLOWED', 'The gateway cannot serve $endpoint.');
    }
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _GatewayMuxLink(_client, _sessionCache, _pendingRequests);
    link.start(onFrame: (_) {}, onLost: (_, _) {});
    return link;
  }

  @override
  Future<void> close() => _client.close();

  /// Requests the Host is waiting on, keyed by the id DSH answers with (the
  /// gateway's own `rpcId`).
  final Map<String, _PendingRequest> _pendingRequests = <String, _PendingRequest>{};

  /// Open byte transfers per "session|path", so windows read forward.
  final Map<String, _FileTransfer> _transfers = <String, _FileTransfer>{};

  Future<_FileTransfer> _transferFor(String? sessionId, String path) async {
    final key = '${sessionId ?? ''}|$path';
    final existing = _transfers[key];
    if (existing != null) return existing;
    final requestId = 'download-${DateTime.now().microsecondsSinceEpoch}';
    final opened = await _client.request(
      GatewayRequest.fileDownloadOpen,
      params: <String, Object?>{'requestId': requestId, 'sessionId': ?sessionId, 'path': path},
      expect: <String>{GatewayKind.fileDownloadOpened},
      timeout: _or(null),
    );
    final transferId = gatewayString(opened, 'transferId');
    if (transferId == null) {
      throw const DshRemoteException('workspace-file/not-found', '网关没有返回 transferId。');
    }
    final transfer = _FileTransfer(
      transferId: transferId,
      version: '${gatewayInt(opened, 'size') ?? 0}',
    );
    _transfers[key] = transfer;
    return transfer;
  }
  _PendingRequest? _pendingQuestionFor(String? sessionId) {    for (final entry in _pendingRequests.values) {
      if (entry.question && (sessionId == null || entry.sessionId == sessionId)) return entry;
    }
    return null;
  }

  /// Maps DSH's outcome map onto the gateway's `allowed-once` / `rejected`.
  static String _approvalOutcome(Object? value) {
    final map = asGatewayMap(value);
    final raw = gatewayString(map ?? const <String, Object?>{}, 'outcome') ??
        gatewayString(map ?? const <String, Object?>{}, 'decision') ??
        gatewayString(map ?? const <String, Object?>{}, 'value');
    if (raw == null) return 'rejected';
    return raw.contains('reject') || raw.contains('deny') ? 'rejected' : 'allowed-once';
  }

  static Duration _or(Duration? timeout) => timeout ?? const Duration(seconds: 30);

  static Set<String> _promptExpect() => <String>{GatewayKind.sent, GatewayRequest.message};

  static Map<String, Object?> _details(GatewayError error) => <String, Object?>{
        if (error.requestType != null) 'requestType': error.requestType,
        if (error.sessionId != null) 'sessionId': error.sessionId,
      };

  /// Reads a session id out of `{'address': {'sessionId': …}}` or a flat map.
  static String? _sessionIdOf(Map<String, Object?> value) {
    final address = asGatewayMap(value['address']);
    if (address != null) {
      final id = gatewayString(address, 'sessionId') ?? gatewayString(address, 'id');
      if (id != null) return id;
    }
    return gatewayString(value, 'sessionId');
  }

  /// Pulls the plain text out of a DSH prompt payload.
  static String? _promptText(Map<String, Object?> request) {
    final direct = gatewayString(request, 'text');
    if (direct != null) return direct;
    // `content` is the current wire name; `parts` was the older one.
    final parts = request['content'] ?? request['parts'];
    if (parts is List) {
      final buffer = StringBuffer();
      for (final part in parts) {
        final map = asGatewayMap(part);
        if (map == null) continue;
        if (gatewayString(map, 'type') != 'text') continue;
        final text = gatewayString(map, 'text');
        if (text != null) buffer.write(text);
      }
      if (buffer.isNotEmpty) return buffer.toString();
    }
    return null;
  }
}

/// One `DshMuxLink` over the gateway socket.
///
/// `$events` gets a synthetic `ready` item (the gateway has no per-connection
/// home directory) and then forwards host-level pushes. `session/follow`
/// subscribes to the session and forwards `event` frames as follow items.
class _GatewayMuxLink implements DshMuxLink {
  _GatewayMuxLink(this._client, this._sessions, this._pending);

  final GatewayClient _client;

  /// Session rows from the last `sessions` reply, used to build a snapshot
  /// header when the gateway's own `session-snapshot` has not arrived yet.
  final Map<String, Map<String, Object?>> _sessions;

  /// The carrier's request registry, so incoming asks can be answered.
  final Map<String, _PendingRequest> _pending;

  /// Stream id of the Host `$events` link, where asks are delivered.
  String? _eventsStreamId;

  void _emitHost(Map<String, Object?> value) {
    final streamId = _eventsStreamId;
    if (streamId == null) return;
    _emit(<String, Object?>{'type': 'item', 'streamId': streamId, 'value': value});
  }
  DshMuxFrameHandler? _onFrame;
  DshMuxLossHandler? _onLost;
  StreamSubscription<Map<String, Object?>>? _pushes;
  final Map<String, String> _streamSessions = <String, String>{};

  /// Streams that already opened with a snapshot (a second one resyncs).
  final Set<String> _snapshotSent = <String>{};
  bool _closed = false;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
    _pushes = _client.pushes.listen(_deliver, onDone: _reportLoss, onError: (Object _) => _reportLoss());
  }

  void _reportLoss() {
    if (_closed) return;
    _closed = true;
    _onLost?.call(const DshCarrierLostException('gateway link closed'), null);
  }

  void _emit(Map<String, Object?> frame) {
    if (_closed) return;
    _onFrame?.call(frame);
  }

  void _deliver(Map<String, Object?> frame) {
    final kind = gatewayString(frame, 'kind');
    switch (kind) {
      case GatewayKind.event:
        final sessionId = gatewayString(frame, 'sessionId');
        final event = asGatewayMap(frame['event']);
        if (sessionId == null || event == null) return;
        final streamId = _streamSessions.entries
            .where((entry) => entry.value == sessionId)
            .map((entry) => entry.key)
            .firstOrNull;
        if (streamId == null) return;
        _emit(<String, Object?>{
          'type': 'item',
          'streamId': streamId,
          'value': <String, Object?>{
            'type': 'event',
            'event': <String, Object?>{
              'type': gatewayString(event, 'type') ?? 'unknown',
              'seq': gatewayInt(frame, 'seq') ?? 0,
              'time': gatewayInt(frame, 'time') ?? 0,
              'data': event,
            },
          },
        });
      case GatewayKind.approvalRequested:
        final rpcId = gatewayString(frame, 'rpcId');
        final sessionId = gatewayString(frame, 'sessionId');
        if (rpcId == null || sessionId == null) return;
        _pending[rpcId] = _PendingRequest(
          rpcId: rpcId,
          sessionId: sessionId,
          approvalId: gatewayString(frame, 'approvalId'),
        );
        _emitHost(<String, Object?>{
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': rpcId,
          'agentId': sessionId,
          'request': <String, Object?>{
            'toolName': gatewayString(frame, 'toolName') ?? 'tool',
            if (frame['callId'] != null) 'callId': frame['callId'],
            if (frame['reason'] != null) 'reason': frame['reason'],
          },
        });
      case GatewayKind.approvalResolved:
        final rpcId = gatewayString(frame, 'rpcId');
        if (rpcId == null) return;
        _pending.remove(rpcId);
        _emitHost(<String, Object?>{'type': 'cancel', 'eventId': rpcId});
      case GatewayKind.questionRequested:
        final rpcId = gatewayString(frame, 'rpcId');
        final sessionId = gatewayString(frame, 'sessionId');
        if (rpcId == null || sessionId == null) return;
        _pending[rpcId] = _PendingRequest(rpcId: rpcId, sessionId: sessionId, question: true);
        _emitHost(<String, Object?>{
          'type': 'waterfall',
          'event': 'user-questions/request',
          'eventId': rpcId,
          'agentId': sessionId,
          'request': <String, Object?>{'questions': frame['questions'] ?? const <Object?>[]},
        });
      case GatewayKind.questionResolved:
        final rpcId = gatewayString(frame, 'rpcId');
        if (rpcId == null) return;
        _pending.remove(rpcId);
        _emitHost(<String, Object?>{'type': 'cancel', 'eventId': rpcId});
      case GatewayKind.sessionSnapshot:
        // The gateway's own opening page for a subscribed session: forward it
        // once as the follow snapshot.
        final sessionId = gatewayString(frame, 'sessionId');
        if (sessionId == null) return;
        final streamId = _streamSessions.entries
            .where((entry) => entry.value == sessionId)
            .map((entry) => entry.key)
            .firstOrNull;
        if (streamId == null) return;
        _emitSnapshot(streamId, sessionId, frame);
      case GatewayKind.sessionTitleChanged:
        final sessionId = gatewayString(frame, 'sessionId');
        final title = gatewayString(frame, 'title');
        if (sessionId == null) return;
        _emit(<String, Object?>{
          'type': 'item',
          'streamId': hostEventsEndpoint,
          'value': <String, Object?>{
            'type': 'emit',
            'event': 'api-session/status',
            'args': <Object?>[sessionId, title ?? ''],
          },
        });
      default:
        break;
    }
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == hostEventsEndpoint || endpoint == r'$events') {
      _eventsStreamId = streamId;
      // Synthetic ready: the socket itself is the generation.
      _emit(<String, Object?>{
        'type': 'item',
        'streamId': streamId,
        'value': <String, Object?>{
          'type': 'ready',
          'clientId': _client.device?.id ?? _client.handshake?.gatewayId ?? 'gateway',
          'host': <String, Object?>{'home': ''},
        },
      });
      return;
    }
    if (endpoint == 'session/follow') {
      final request = asGatewayMap(payload['args'])?['request'] ??
          asGatewayMap(payload)?['request'] ??
          payload['request'];
      final sessionId = request is Map ? GatewayCarrier._sessionIdOf(asGatewayMap(request) ?? const {}) : null;
      final id = sessionId ?? (request is Map ? '${asGatewayMap(request) ?? const {}}' : null);
      if (id == null) {
        _emit(<String, Object?>{
          'type': 'error',
          'streamId': streamId,
          'error': <String, Object?>{'code': 'gateway/bad-request', 'message': 'follow needs a session'},
        });
        return;
      }
      _streamSessions[streamId] = id;
      unawaited(_openFollow(streamId, id));
    }
  }

  /// Subscribes, then guarantees the stream opens with a snapshot.
  ///
  /// The gateway pushes `session-snapshot` right after `subscribed`; a 6s
  /// fallback asks `history` so a silent gateway cannot leave the conversation
  /// view spinning on 「正在同步对话」, which is what `session/follow` without a
  /// snapshot looks like (DshClient throws `follow opened without snapshot`).
  Future<void> _openFollow(String streamId, String sessionId) async {
    try {
      await _client.request(
        GatewayRequest.subscribe,
        params: <String, Object?>{'sessionId': sessionId},
        expect: <String>{GatewayKind.subscribed},
      );
    } on Object catch (error) {
      _emit(<String, Object?>{
        'type': 'error',
        'streamId': streamId,
        'error': <String, Object?>{'code': 'gateway/subscribe-failed', 'message': '$error'},
      });
      return;
    }

    await Future<void>.delayed(const Duration(seconds: 6));
    if (_closed || _snapshotSent.contains(streamId)) return;
    try {
      final frame = await _client.request(
        GatewayRequest.history,
        params: <String, Object?>{'sessionId': sessionId, 'maxMessages': 80, 'view': 'conversation'},
        timeout: const Duration(seconds: 30),
      );
      _emitSnapshot(streamId, sessionId, frame);
    } on Object catch (error) {
      _emit(<String, Object?>{
        'type': 'error',
        'streamId': streamId,
        'error': <String, Object?>{'code': 'gateway/history-failed', 'message': '$error'},
      });
    }
  }

  /// Emits the one `snapshot` a follow stream may open with.
  void _emitSnapshot(String streamId, String sessionId, Map<String, Object?> frame) {
    if (!_snapshotSent.add(streamId)) return;
    final events = GatewayClient.historyEvents(frame);
    var cursor = -1;
    for (final event in events) {
      final seq = gatewayInt(event, 'seq');
      if (seq != null && seq > cursor) cursor = seq;
    }
    final cached = _sessions[sessionId];
    _emit(<String, Object?>{
      'type': 'item',
      'streamId': streamId,
      'value': <String, Object?>{
        'type': 'snapshot',
        'header': <String, Object?>{
          'id': sessionId,
          'version': 4,
          'createdAt': gatewayInt(cached ?? const <String, Object?>{}, 'updatedAt') ?? 0,
          'isSeeded': false,
          if (cached?['cwd'] is String) 'cwd': cached!['cwd'],
        },
        'cursor': cursor,
        'records': <Object?>[
          for (final event in events) <String, Object?>{'event': event},
        ],
        'hasMore': frame['hasMore'] == true,
        // The gateway trims session-list projections to `title` alone, so the
        // snapshot's own projections (full values) win when present.
        'projections': frame['projections'] ??
            cached?['projections'] ??
            <String, Object?>{'asOfSeq': cursor, 'values': <String, Object?>{}},
        'assistantStream': frame['assistantStream'],
      },
    });
  }

  @override
  void sendItem(String streamId, Object? value) {
    // The gateway owns message delivery; nothing to send from a stream.
  }

  @override
  void endUplink(String streamId) {
    // No uplink support.
  }

  @override
  void cancel(String streamId) {
    _streamSessions.remove(streamId);
  }

  @override
  Future<void> close(int code, String reason) async {
    _closed = true;
    await _pushes?.cancel();
    _pushes = null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}


/// A request the Host is waiting on: an approval or a user question.
class _PendingRequest {
  const _PendingRequest({
    required this.rpcId,
    required this.sessionId,
    this.approvalId,
    this.question = false,
  });

  final String rpcId;
  final String sessionId;
  final String? approvalId;
  final bool question;
}
/// One open download: bytes read so far, and whether the file ended.
class _FileTransfer {
  _FileTransfer({required this.transferId, required this.version});

  final String transferId;
  final String version;
  final BytesBuilder buffered = BytesBuilder(copy: false);
  bool eof = false;
}