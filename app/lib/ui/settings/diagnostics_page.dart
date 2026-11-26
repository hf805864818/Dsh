// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../diagnostics/diagnostics_publish.dart';
import '../../diagnostics/automatic_diagnostics.dart';
import '../../diagnostics/redact.dart';
import '../../diagnostics/system_ime_diagnostics.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/runtime_bridge.dart';
import '../../state/android_features.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/privilege_probe.dart';
import '../../state/privilege_state.dart';
import '../../state/settings_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/risk_notice.dart';
import '../common/list_page_row.dart';
import '../engine/diagnostics_export_card.dart';
import '../engine/engine_screen.dart' show shortRuntimeVersion;
import '../engine/engine_status.dart';
import '../shell/page_frame.dart';
import '../phone/phone_control_screen.dart';
import '../privilege/privilege_failure_sheet.dart';
import '../privilege/privilege_guide_page.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';
import 'direct_engine_settings.dart';
import '../common/brief_notice.dart';

/// Self-service diagnostics: what the app knows about the runtime and the
/// connection, plus a copyable report with every secret redacted.
class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  static Map<String, Object?> report({
    required LocalRuntimeState runtime,
    required AppSettings settings,
    required String connection,
    required int logLines,
  }) {
    final s = runtime.status;
    return {
      'app': AppInfo.version,
      'runtime': {
        'phase': s.phase.name,
        'abi': s.abi,
        'bundledVersion': s.bundledVersion,
        'installedVersion': s.installedVersion,
        'dshVersion': s.dshVersion,
        'nodeVersion': s.nodeVersion,
        'baseUrl': s.baseUrl,
        'token': s.token == null ? null : '<redacted>',
        'error': s.error,
        'logLines': logLines,
        ...s.launchDiagnostics,
      },
      'connection': connection,
      'settings': {
        'hasApiKey': settings.hasApiKey,
        'themeMode': settings.themeMode.name,
        'autoStartLocal': settings.autoStartLocal,
        'autoApproveCommands': settings.autoApproveCommands,
      },
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final runtime = ref.watch(localRuntimeProvider);
    final settings = ref.watch(settingsProvider);
    final conn = ref.watch(localConnectionProvider);
    final status = runtime.status;
    final connection = switch (conn) {
      AsyncData(:final value) => value == null ? l10n.commonNotConnected : l10n.pluginsConnectedHost(value.label),
      AsyncError(:final error) => l10n.pluginsConnectionError('$error'),
      _ => l10n.pluginsConnecting,
    };
    Future<void> copyReport() async {
      final json = const JsonEncoder.withIndent('  ').convert(
        redactJson(
          report(
            runtime: runtime,
            settings: settings,
            connection: connection,
            logLines: ref.read(localRuntimeLogsProvider).length,
          ),
        ),
      );
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        showBriefNotice(context, l10n.pluginsDiagnosticsCopied);
      }
    }

    Future<void> publishForAi() async {
      final published = await ref.read(diagnosticsPublisherProvider).publish(includeSystemIme: true);
      if (!context.mounted) return;
      showBriefNotice(context, published == null ? l10n.diagnosticsForAiFailed : l10n.diagnosticsForAiDone);
    }

    return AppPage.list(
      title: l10n.pluginsDiagnostics,
      subtitle: Text(l10n.pluginsDiagnosticsDescription),
      children: [
        SettingsSection(
          title: l10n.pluginsRuntime,
          children: [
            InfoRow(label: l10n.commonStatus, value: EngineStatusView.of(runtime).label),
            InfoRow(label: l10n.pluginsArchitecture, value: status.abi ?? '—', mono: true),
            InfoRow(label: l10n.pluginsBundledVersion, value: shortRuntimeVersion(status.bundledVersion), mono: true),
            InfoRow(
              label: l10n.pluginsInstalledVersion,
              value: shortRuntimeVersion(status.installedVersion),
              mono: true,
            ),
            RuntimeLaunchFacts(status: status),
            InfoRow(label: 'DSH', value: status.dshVersion ?? '—', mono: true),
            InfoRow(label: 'Node.js', value: status.nodeVersion ?? '—', mono: true),
            if (status.error case final error?) InfoRow(label: l10n.pluginsErrorLabel, value: error, mono: true),
          ],
        ),
        SettingsSection(
          title: l10n.pluginsConnection,
          children: [
            InfoRow(label: l10n.pluginsAddress, value: status.baseUrl ?? '—', mono: true),
            InfoRow(label: l10n.pluginsClient, value: connection),
            InfoRow(label: 'API Key', value: settings.hasApiKey ? l10n.pluginsConfigured : l10n.commonNotSet),
          ],
        ),
        // Its failure evidence is recorded natively: Android's own, HarmonyOS's from HiAppEvent.
        const AutomaticDiagnosticsSection(),
        // Android reads the system log through a privileged channel; HarmonyOS, this app's own window.
        const SystemImeDiagnosticsSection(),
        DiagnosticsExportCard(
          title: l10n.pluginsExport,
          extra: [
            ListPageRow(
              icon: AppIcons.copy,
              title: l10n.pluginsCopyDiagnostics,
              subtitle: l10n.pluginsDiagnosticsContents,
              onTap: copyReport,
            ),
            ListPageRow(
              icon: AppIcons.bot,
              title: l10n.diagnosticsForAi,
              subtitle: l10n.diagnosticsForAiHint,
              onTap: publishForAi,
            ),
          ],
        ),
        // Signed entitlements decide what this build may read; the probe reports
        // what the kernel actually allowed, so "did you re-sign" stops being a
        // guess. Full-permission sessions build on this.
        const _PrivilegeSection(),
        // The note belongs to the export card; the next group starts 24 below
        // it, as groups do.
        const DiagnosticsBundleNote(),
        if (ref.watch(androidSystemFeaturesProvider)) ...[const SizedBox(height: 24), const DirectEngineSettings()],
      ],
    );
  }
}

/// What the current signature allows outside the app container, and the switch
/// that acts on it.
///
/// `no-sandbox` and `platform-application` are signing-time entitlements, so a
/// build that was not re-signed cannot read the phone's shared folders however
/// the app is configured. The phase and the failing stage come from
/// [privilegeControllerProvider] — the same source the chat's permission panel
/// reads — so this page and the panel never disagree about whether full
/// permission is on.
class _PrivilegeSection extends ConsumerStatefulWidget {
  const _PrivilegeSection();

  @override
  ConsumerState<_PrivilegeSection> createState() => _PrivilegeSectionState();
}

class _PrivilegeSectionState extends ConsumerState<_PrivilegeSection> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    setState(() => _busy = true);
    await ref.read(privilegeControllerProvider.notifier).refreshProbe();
    if (mounted) setState(() => _busy = false);
  }

  /// The switch itself. The diagnostics page owns no conversation, so it claims
  /// the mode under [PrivilegeController.diagnosticsSessionId]: a chat switched
  /// on afterwards is told to end this one first.
  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.read(privilegeControllerProvider.notifier);
    if (!enabled) {
      await controller.disable();
      if (mounted) setState(() => _busy = false);
      return;
    }
    final settings = ref.read(settingsProvider);
    final ok = await controller.enable(
      PrivilegeController.diagnosticsSessionId,
      phoneStorage: settings.phoneStorage,
      visualReplies: settings.visualReplies,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showBriefNotice(context, '完全权限已开启');
      return;
    }
    final view = ref.read(privilegeControllerProvider);
    if (view.phase == PrivilegePhase.sandboxed) {
      await showPrivilegeFailureSheet(context, stage: 'probe_denied', message: view.message);
      return;
    }
    if (view.failureStage case final stage?) {
      final choice = await showPrivilegeFailureSheet(
        context,
        stage: stage,
        errno: view.errno,
        message: view.message,
      );
      if (choice == PrivilegeFailureChoice.retry) await _setEnabled(true);
      return;
    }
    showBriefNotice(context, view.message ?? '请先结束当前全权限会话');
  }

  static String _phaseLabel(PrivilegePhase phase) => switch (phase) {
    PrivilegePhase.sandboxed => '受限（沙箱内）',
    PrivilegePhase.privileged => '可读容器外目录',
    PrivilegePhase.enabling => '正在切换…',
    PrivilegePhase.enabled => '完全权限 · 宿主可读写',
    PrivilegePhase.disabling => '正在关闭…',
    PrivilegePhase.failed => '失败',
  };

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(privilegeControllerProvider);
    final status = PrivilegeProbe.cached;
    final stage = view.phase == PrivilegePhase.failed ? view.failureStage : null;
    final phaseText = _busy
        ? '探测中…'
        : stage == null
        ? _phaseLabel(view.phase)
        : '${_phaseLabel(view.phase)}：$stage${view.errno == null ? '' : ' · errno ${view.errno}'}';
    return SettingsSection(
      title: '全权限（宿主目录）',
      children: [
        InfoRow(label: '签名状态', value: phaseText),
        if (view.message case final message? when message.isNotEmpty) InfoRow(label: '说明', value: message),
        if (status case final probe? when probe.readable.isNotEmpty)
          InfoRow(label: '可读', value: probe.readable.join('\n'), mono: true),
        if (status case final probe? when probe.denied.isNotEmpty)
          InfoRow(
            label: '被拒',
            value: probe.denied.entries.map((entry) => '${entry.key}  errno ${entry.value}').join('\n'),
            mono: true,
          ),
        if (status case final probe? when probe.layout.isNotEmpty)
          InfoRow(label: '越狱布局', value: probe.layout),
        if (status case final probe?)
          InfoRow(
            label: 'dpkg',
            value: probe.bootstrap.isEmpty
                ? '未找到（rootful /usr/bin、rootless /var/jb、Roothide .jbroot 都没有）'
                : '${probe.bootstrap.join('\n')}${probe.dpkgVersion.isEmpty ? '\n（路径在，但以当前身份跑不起来）' : '\n${probe.dpkgVersion}'}',
            mono: true,
          ),
        ListPageRow(
          icon: AppIcons.refresh,
          title: '重新探测',
          subtitle: view.phase == PrivilegePhase.sandboxed
              ? '需要重签 IPA 加入 no-sandbox 才能开启完全权限'
              : view.canOffer
              ? '当前签名可开启「完全权限」会话'
              : '探测中，稍等',
          onTap: _busy ? null : _probe,
        ),
        ListPageRow(
          icon: view.active ? AppIcons.lock : AppIcons.unlock,
          title: view.active ? '停用全权限' : '启用全权限',
          subtitle: view.active ? '把引擎切回普通参数，宿主目录不再可写' : '停引擎 → 把宿主 / 挂到 /host → 以全权限参数重启',
          subtitleMaxLines: 2,
          danger: view.active,
          onTap: _busy || (!view.canOffer && view.phase != PrivilegePhase.failed)
              ? null
              : () => unawaited(_setEnabled(!view.active)),
        ),
        ListPageRow(
          icon: AppIcons.instructions,
          title: '重签教程',
          subtitle: '加入 no-sandbox 与 platform-application 的完整步骤',
          onTap: () => unawaited(
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivilegeGuidePage())),
          ),
        ),
      ],
    );
  }
}

/// One opt-in, one status, one ordinary report-session entry.
class AutomaticDiagnosticsSection extends ConsumerStatefulWidget {
  const AutomaticDiagnosticsSection({super.key});

  @override
  ConsumerState<AutomaticDiagnosticsSection> createState() => _AutomaticDiagnosticsSectionState();
}

class _AutomaticDiagnosticsSectionState extends ConsumerState<AutomaticDiagnosticsSection> with WidgetsBindingObserver {
  bool _changing = false;
  int _recoveryEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.isCurrentOf(context) == false) _recoveryEpoch++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _recoveryEpoch++;
  }

  @override
  void dispose() {
    _recoveryEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _recover() async {
    final automatic = ref.read(automaticDiagnosticsProvider);
    if (_changing || automatic.busy || !ref.read(activeHostProvider).isLocal) return;
    final epoch = _recoveryEpoch;
    setState(() => _changing = true);
    try {
      await automatic.recoverStorage(
        isCurrent: () =>
            mounted &&
            epoch == _recoveryEpoch &&
            ModalRoute.of(context)?.isCurrent != false &&
            ref.read(activeHostProvider).isLocal,
      );
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _change(bool enabled) async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      final l10n = context.l10n;
      if (enabled) {
        final accepted = await confirmRisk(
          context,
          RiskNotice(
            id: 'diagnostics.automatic',
            level: RiskLevel.high,
            title: l10n.automaticDiagnosticsConsentTitle,
            body: l10n.automaticDiagnosticsConsent,
            action: l10n.automaticDiagnosticsEnable,
          ),
        );
        if (!mounted || !accepted || !ref.read(activeHostProvider).isLocal) return;
      }
      await ref.read(settingsProvider.notifier).setAutomaticDiagnostics(enabled);
    } catch (_) {
      if (mounted) showBriefNotice(context, context.l10n.automaticDiagnosticsStoreFailed);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final local = ref.watch(activeHostProvider).isLocal;
    final automatic = ref.watch(automaticDiagnosticsProvider);
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next) _recoveryEpoch++;
    });
    ref.listen(settingsProvider.select((s) => s.automaticDiagnostics), (previous, next) {
      if (previous != next) _recoveryEpoch++;
    });
    return ListenableBuilder(
      listenable: automatic,
      builder: (context, _) {
        final status = switch (automatic.phase) {
          AutomaticDiagnosticsPhase.failed =>
            automatic.failureCode == 'store_failed'
                ? l10n.automaticDiagnosticsStoreFailed
                : automatic.failureCode == 'cancel_failed'
                ? l10n.automaticDiagnosticsCancelFailed
                : l10n.automaticDiagnosticsFailed,
          _ when !settings.automaticDiagnostics => l10n.automaticDiagnosticsOff,
          _ when !automatic.eligible => l10n.automaticDiagnosticsWaiting,
          AutomaticDiagnosticsPhase.collecting => l10n.automaticDiagnosticsCollecting,
          AutomaticDiagnosticsPhase.analyzing => l10n.automaticDiagnosticsAnalyzing,
          AutomaticDiagnosticsPhase.complete => l10n.automaticDiagnosticsComplete,
          AutomaticDiagnosticsPhase.cancelled => l10n.automaticDiagnosticsCancelled,
          _ => l10n.automaticDiagnosticsReady,
        };
        return SettingsSection(
          title: l10n.automaticDiagnosticsTitle,
          children: [
            SettingsSwitchTile(
              title: l10n.automaticDiagnosticsTitle,
              subtitle: l10n.automaticDiagnosticsHint,
              value: settings.automaticDiagnostics,
              onChanged: _changing || !settings.loaded || (!local && !settings.automaticDiagnostics) ? null : _change,
            ),
            InfoRow(label: l10n.commonStatus, value: status),
            if (automatic.failureCode == 'store_failed')
              SettingsTile(
                title: l10n.automaticDiagnosticsRecover,
                subtitle: l10n.automaticDiagnosticsRecoverHint,
                onTap: local && !_changing && !automatic.busy ? _recover : null,
              ),
            if (automatic.reportSessionId case final id?)
              SettingsTile(
                title: l10n.automaticDiagnosticsViewReport,
                subtitle: l10n.automaticDiagnosticsReportHint,
                onTap: !local
                    ? null
                    : () {
                        // Only a deliberate tap selects this ordinary conversation.
                        if (!ref.read(activeHostProvider).isLocal) return;
                        ref.read(currentSessionProvider.notifier).select(id);
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      },
              ),
          ],
        );
      },
    );
  }
}

/// Only this visible, user-owned section can start a native consent request.
class SystemImeDiagnosticsSection extends ConsumerStatefulWidget {
  const SystemImeDiagnosticsSection({super.key});

  @override
  ConsumerState<SystemImeDiagnosticsSection> createState() => _SystemImeDiagnosticsSectionState();
}

class _SystemImeDiagnosticsSectionState extends ConsumerState<SystemImeDiagnosticsSection> with WidgetsBindingObserver {
  late final SystemImeDiagnostics _diagnostics;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _diagnostics = ref.read(systemImeDiagnosticsProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_route?.isCurrent == false) _diagnostics.cancelPending(notify: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A native consent dialog makes Flutter inactive without leaving the Activity.
    // Native onActivityPaused also revokes consent when the user actually leaves.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _diagnostics.cancelPending();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _diagnostics.cancelPending(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _diagnostics,
    builder: (context, _) {
      final l10n = context.l10n;
      final evidence = _diagnostics.evidence;
      // HarmonyOS records this app's own window geometry: no privileged log, nothing to grant.
      final ohos = ref.watch(operatingSystemProvider) == 'ohos';
      final status = _diagnostics.collecting
          ? l10n.systemImeCollecting
          : switch (evidence?.code) {
              null => l10n.systemImeNotCollected,
              'ok' => l10n.systemImeRetained,
              'noEvents' => l10n.systemImeNoEvents,
              'unavailable' => ohos ? l10n.systemImeOhosUnavailable : l10n.systemImeUnavailable,
              'unsupported' => l10n.systemImeUnsupported,
              'denied' => l10n.systemImeDenied,
              'cancelled' => l10n.systemImeCancelled,
              'busy' => l10n.systemImeBusy,
              'timeout' => l10n.systemImeTimeout,
              'limitExceeded' => l10n.systemImeLimitExceeded,
              _ => l10n.systemImeFailed,
            };
      return SettingsSection(
        title: ohos ? l10n.systemImeOhosTitle : l10n.systemImeTitle,
        children: [
          SettingsTile(
            icon: AppIcons.exportLog,
            title: ohos ? l10n.systemImeOhosCollect : l10n.systemImeCollect,
            subtitle: ohos ? l10n.systemImeOhosPrivacy : l10n.systemImePrivacy,
            onTap: _diagnostics.collecting
                ? null
                : () => _diagnostics.collect(isCurrent: () => mounted && (_route?.isCurrent ?? true)),
            tinted: false,
          ),
          SettingsTile(title: status, subtitle: l10n.systemImeEvidenceLimits),
          InfoRow(label: l10n.systemImeEventCount, value: '${evidence?.events.length ?? 0} / 64'),
          if (evidence != null)
            InfoRow(
              label: l10n.systemImeCapturedAt,
              value: DateTime.fromMillisecondsSinceEpoch(evidence.capturedAt).toString().split('.').first,
            ),
          if (evidence?.code == 'unavailable' && !ohos)
            SettingsTile(
              icon: AppIcons.permissions,
              title: l10n.systemImePermissions,
              subtitle: l10n.systemImePermissionsHint,
              onTap: () {
                _diagnostics.cancelPending();
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneControlScreen()));
              },
              tinted: false,
            ),
          SettingsTile(
            icon: AppIcons.clearAll,
            title: l10n.systemImeClear,
            subtitle: l10n.systemImeMemory,
            onTap: evidence != null || _diagnostics.collecting ? _diagnostics.clear : null,
            tinted: false,
          ),
        ],
      );
    },
  );
}

/// The engine process as the native side observes it (never the saved
/// preference), then the latest launch attempt, kept after it exits.
class RuntimeLaunchFacts extends StatelessWidget {
  const RuntimeLaunchFacts({super.key, required this.status});
  final RuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String method(String mode) => switch (mode) {
      'direct' => l10n.phoneLaunchDirect,
      'proot' => l10n.phoneLaunchCompatible,
      'tawcroot' => l10n.phoneLaunchTawcroot,
      'ohos-embedded' => l10n.harmonyLaunchEmbedded,
      _ => mode,
    };
    // One child of the card: keep SheetGroup's 2dp between its rows.
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        InfoRow(
          label: l10n.phoneActualLaunchMode,
          value: switch (status.currentExecutionMode) {
            final String mode => method(mode),
            null => l10n.phoneLaunchNotObserved,
          },
        ),
        // A live process is that launch: the attempt only adds news once it ended.
        if (status.launchSelectedMode case final selected? when status.currentExecutionMode == null)
          InfoRow(label: l10n.phoneLastLaunchSelection, value: method(selected)),
        if (status.directEngineFallbackReason case final reason?)
          InfoRow(
            label: l10n.phoneDirectRejectedReason,
            value: switch (reason) {
              'incompatibleFiles' => l10n.phoneDirectIncompatibleFiles,
              'notEnoughSpace' => l10n.phoneDirectNotEnoughSpace,
              'migrationFailed' => l10n.phoneDirectMigrationFailed,
              'directFailed' => l10n.phoneDirectLaunchFailed,
              'tawcrootFailed' => l10n.phoneTawcLaunchFailed,
              'tawcrootUnsupported' => l10n.phoneTawcUnsupported,
              'tawcrootNotBundled' || 'tawcrootApiTooOld' => l10n.phoneTawcUnavailable,
              'safeRecovery' => l10n.phoneSafeMode,
              _ => reason,
            },
          ),
        if (status.launchFailureReason case final reason?)
          InfoRow(
            label: l10n.phoneLaunchFailureReason,
            value: reason == 'startFailed'
                ? l10n.phoneLaunchStartFailed
                : reason == 'ohos_node_exited'
                ? l10n.harmonyLaunchNodeExited
                : reason.startsWith('exit:') && int.tryParse(reason.substring(5)) != null
                ? l10n.phoneLaunchExited(reason.substring(5))
                : reason,
          ),
      ],
    );
  }
}