// The full-permission failure sheet. A step of the host's sequence failed
// (`privilege_<stage>`), and the user has to decide what happens next, so this
// sheet cannot be swiped or tapped away: the two ways out are 「重试」 and
// 「以普通模式继续」, plus the re-signing tutorial for the stages only a new
// signature can fix.
//
// Each stage gets its own words and its own copyable check, because "mount
// failed: errno 2" and "you did not re-sign" send the user to different places.

import 'package:flutter/material.dart';

import '../common/app_sheet.dart' show showAppSheet, SheetDismissal, kSheetGutter;
import '../common/sheet_title_bar.dart' show SheetTitleBar;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'privilege_guide_page.dart' show PrivilegeCodeBlock, PrivilegeGuidePage;

/// What the user chose on the sheet.
enum PrivilegeFailureChoice {
  /// Run the step again.
  retry,

  /// Leave the conversation in ordinary permission.
  ordinary,
}

/// One stage's title, one-sentence cause, and the check that tells the user
/// which side of it they are on.
typedef _StageCopy = ({String title, String cause, String check});

_StageCopy _copyFor(String stage) => switch (stage) {
  'probe_denied' => (
    title: '这个构建没有被重签',
    cause: '探针读不到容器外的任何目录:签名里没有 no-sandbox,App 只能看见自己那一份沙箱。',
    check: r'''# 签名里应该能看到 no-sandbox
ldid -e Payload/Runner.app/Runner | grep -c com.apple.private.security.no-sandbox''',
  ),
  'mount_disabled' => (
    title: '这个构建停用了宿主挂载',
    cause: '宿主挂载会让引擎启动卡死,所以先在代码里关掉了。宿主文件访问改用原生直通实现,正在开发中。',
    check: r'''# 当前版本仍能读宿主目录(诊断页「可读」那几行),
# 但 guest 里没有 /host;原生直通上线后从会话里调用''',
  ),
  'engine_running' => (
    title: '引擎还在运行',
    cause: '全权限要在引擎停下时切换:它现在还在跑,先停掉再试。',
    check: r'''# 设置 › 诊断 › 运行时 里停掉本机引擎,再点一次完全权限''',
  ),
  'symbol' => (
    title: '这个引擎版本没有全权限接口',
    cause: 'DshGuest 框架里找不到 dsh_guest_set_host_mount:内核组件是旧版,需要换成带该接口的构建。',
    check: r'''# 在设置 › 诊断 › 运行时 里确认引擎版本与应用版本一致''',
  ),
  'mount' => (
    title: '挂载宿主根目录被拒绝',
    cause: '把宿主 / 挂到 guest /host 时内核说不行:常见原因是签名没有 no-sandbox,或 /host 挂载点不在。',
    check: r'''# 1) 签名里应该有 no-sandbox
ldid -e Payload/Runner.app/Runner | grep -c com.apple.private.security.no-sandbox
# 2) 装好应用后在 guest 里看 /host 是否出现
ls -ld /host''',
  ),
  'unmount' => (
    title: '卸载 /host 失败',
    cause: 'guest 里还有进程占着 /host(比如某个 shell 的当前目录),内核因此拒绝卸载。',
    check: r'''# 先停掉所有占用的会话/终端,再点一次停用
mount | grep /host''',
  ),
  'engine_restart' => (
    title: '引擎没能带全权限起来',
    cause: '参数传下去了,引擎启动时退出:看它的最后几行就知道卡在哪。',
    check: r'''# 在「设置 › 诊断 › 运行日志」里看最后 50 行''',
  ),
  _ => (
    title: '全权限没有打开',
    cause: '宿主报了一个没有见过的失败,原因在下面这行里。',
    check: r'''# 复现一次,再看「设置 › 诊断 › 运行日志」''',
  ),
};

/// Shows the failure sheet for [stage] and resolves with the user's choice.
///
/// [errno] and [message] are the host's own (`details.errno` /
/// `details.detail`); [message] is shown as it came, the stage copy explains it.
Future<PrivilegeFailureChoice> showPrivilegeFailureSheet(
  BuildContext context, {
  required String stage,
  int? errno,
  String? message,
}) async {
  final choice = await showAppSheet<PrivilegeFailureChoice>(
    context,
    isScrollControlled: true,
    dismissal: SheetDismissal.button,
    builder: (_) => _PrivilegeFailureSheet(stage: stage, errno: errno, message: message),
  );
  return choice ?? PrivilegeFailureChoice.ordinary;
}

class _PrivilegeFailureSheet extends StatelessWidget {
  const _PrivilegeFailureSheet({required this.stage, this.errno, this.message});

  final String stage;
  final int? errno;
  final String? message;

  void _close(BuildContext context, PrivilegeFailureChoice choice) =>
      Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final copy = _copyFor(stage);
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The one explicit dismiss affordance: same choice as the button.
          SheetTitleBar(
            copy.title,
            onClose: () => _close(context, PrivilegeFailureChoice.ordinary),
            maxLines: null,
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    copy.cause,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  _Fact(label: '阶段', value: stage),
                  _Fact(label: 'errno', value: errno?.toString() ?? '—'),
                  if (message case final detail? when detail.isNotEmpty) _Fact(label: '宿主', value: detail),
                  const SizedBox(height: 4),
                  DecoratedBox(
                    decoration: ShapeDecoration(color: dsh.infoContainer, shape: AppShape.card),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '先在电脑或终端里跑一遍下面的检查,确认这一步到底缺什么;改好之后回到这里点「重试」。',
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.onInfoContainer, height: 1.6),
                      ),
                    ),
                  ),
                  PrivilegeCodeBlock(code: copy.check, language: 'bash'),
                  FilledButton(
                    onPressed: () => _close(context, PrivilegeFailureChoice.retry),
                    child: const Text('重试'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => _close(context, PrivilegeFailureChoice.ordinary),
                    child: const Text('以普通模式继续'),
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const PrivilegeGuidePage()),
                    ),
                    icon: const Icon(AppIcons.instructions, size: 16),
                    label: const Text('查看重签教程'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One host fact: label on the left, the value in monospace on the right.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 44,
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
          ),
          Expanded(
            child: Text(
              value,
              style: AppType.monoSmall(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
