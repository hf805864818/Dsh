/// Pair a Mobile Gateway (`dsh-plugin-mobile-gateway` → `/ws/mobile`).
///
/// The computer shows a pairing payload (QR or copyable text) that is valid for
/// five minutes. Pasting it here runs the gateway's own pairing handshake, keeps
/// the device token in the keystore and registers the host so
/// `HostKind.gateway` can connect to it.
library;

import 'dart:async';

import 'package:dsh_remote/gateway.dart' as gw;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/gateway_hosts.dart';
import '../../state/hosts_state.dart';

/// Where the install-level device id lives (stable across re-pairing).
const String gatewayClientIdKey = 'remote_gateway_client_id';

Future<String> gatewayClientDeviceId() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(gatewayClientIdKey);
    if (existing != null && existing.length >= 8) return existing;
    final created = 'dshgo-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    await prefs.setString(gatewayClientIdKey, created);
    return created;
  } catch (_) {
    return 'dshgo-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  }
}

/// Paste-a-pairing-code page.
class GatewayPairPage extends ConsumerStatefulWidget {
  const GatewayPairPage({super.key});

  /// Pushes the page; resolves to true when a host was added.
  static Future<bool?> open(BuildContext context) => Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(builder: (_) => const GatewayPairPage()),
      );

  @override
  ConsumerState<GatewayPairPage> createState() => _GatewayPairPageState();
}

class _GatewayPairPageState extends ConsumerState<GatewayPairPage> {
  final TextEditingController _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prefill());
  }

  Future<void> _prefill() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (!mounted || text == null || text.isEmpty || _code.text.isNotEmpty) return;
      if (text.length > 80 && !text.contains(' ')) {
        setState(() => _code.text = text);
      }
    } catch (_) {
      // Clipboard unavailable: the field stays empty.
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    gw.GatewayClient? client;
    try {
      final pairing = gw.GatewayPairing.parse(_code.text);
      final deviceId = await gatewayClientDeviceId();
      client = await gw.GatewayClient.pair(
        endpoint: pairing.publicUrl,
        pairingCode: pairing.pairingCode,
        clientDeviceId: deviceId,
        deviceName: 'DSH Go',
      );

      final token = client.newDeviceToken;
      final device = client.device;
      if (token == null || token.isEmpty || device == null) {
        throw const gw.GatewayError('gateway/protocol-mismatch', '配对没有返回设备凭证。');
      }

      final hostId = pairing.gatewayId ?? pairing.publicUrl.host;
      final config = GatewayHostConfig(
        id: hostId,
        name: pairing.gatewayName ?? pairing.publicUrl.host,
        url: pairing.publicUrl.toString(),
        endpoints: <String>[for (final uri in pairing.candidates) uri.toString()],
        deviceId: device.id,
        deviceName: device.name,
        clientDeviceId: deviceId,
      );

      await ref.read(secretStoreProvider).write(config.secretKey, token);
      await ref.read(gatewayHostsProvider.notifier).save(config);
      ref.read(activeHostProvider.notifier).select(HostRef.gateway(config.id, name: config.name));

      if (mounted) Navigator.of(context).pop(true);
    } on gw.GatewayPairingException catch (error) {
      setState(() => _error = '配对串无效：${error.message}');
    } on gw.GatewayError catch (error) {
      setState(() => _error = '配对失败：${error.message}');
    } on Object catch (error) {
      setState(() => _error = '配对失败：$error');
    } finally {
      if (client != null) {
        unawaited(client.close());
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('配对移动网关')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: <Widget>[
          Text(
            '在电脑上打开 DSH → 移动设备 → 连接与配对，生成配对码，然后把整串粘贴到这里。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            minLines: 3,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              labelText: '配对串',
              hintText: 'eyJ2ZXJzaW9uIjoyLCJwdWJsaWNVcmwiOiJ3c3M6Ly8…',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy || _code.text.trim().isEmpty ? null : _pair,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('配对'),
          ),
        ],
      ),
    );
  }
}

