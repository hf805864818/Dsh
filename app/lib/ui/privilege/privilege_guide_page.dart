// 重签教程: full permission is a signing-time entitlement, so the only way to
// get it is to re-sign the IPA with `com.apple.private.security.no-sandbox`
// and `platform-application` and install that build. Everyone who meets the
// failure sheet ends up on this page, so it carries the whole procedure —
// unpack, inject, sign every Mach-O, repack — plus what re-signing costs.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../settings/settings_widgets.dart' show SettingsSection, SettingsMetrics;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The entitlements file the injection step writes. Kept verbatim: a stray
/// space or a missing `<true/>` silently produces a build that still cannot
/// read outside its container.
const _extraPlist = r'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>platform-application</key>
    <true/>
</dict>
</plist>''';

const _unpack = r'''unzip DSH-Go-unsigned.ipa -d out
cd out''';

const _inject = r'''# 把两项签名权限写进 extra.plist,再用它重签主二进制
#   com.apple.private.security.no-sandbox = true
#   platform-application = true
ldid -Sextra.plist Payload/Runner.app/Runner''';

const _signAll = r'''# 扩展、App Clip、Frameworks 里的可执行文件都要签,漏一个就起不来
find Payload -type f -perm -111 -exec ldid -Sextra.plist {} \;''';

const _repack = r'''# 在 out/ 里执行,压缩包里必须直接是 Payload/
zip -qr ../DSH-Go-nosandbox.ipa Payload''';

/// 重签 IPA: the whole procedure, one copyable block per step.
class PrivilegeGuidePage extends StatelessWidget {
  const PrivilegeGuidePage({super.key});

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: '重签 IPA',
    subtitle: const Text('给 App 加上 no-sandbox 与 platform-application 两项签名权限'),
    children: const [
      SettingsSection(
        title: '为什么必须重签',
        children: [
          _Paragraph(
            '沙箱是内核按签名决定的:App 自己改不了,越狱也绕不过去。'
            '「完全权限」要让引擎把宿主根目录挂到 guest 的 /host 上、并读到容器外的目录,'
            '靠的就是这两项签名权限。',
          ),
          _Paragraph('重签后用这个 IPA 覆盖安装即可,原来的对话和工作区都还在。'),
        ],
      ),
      SettingsSection(title: '步骤 1 · 解压', children: [PrivilegeCodeBlock(code: _unpack, language: 'bash')]),
      SettingsSection(
        title: '步骤 2 · 写入 entitlements',
        children: [
          _Paragraph('新建 extra.plist,内容照抄:'),
          PrivilegeCodeBlock(code: _extraPlist, language: 'xml'),
        ],
      ),
      SettingsSection(
        title: '步骤 3 · 重签主二进制',
        children: [PrivilegeCodeBlock(code: _inject, language: 'bash')],
      ),
      SettingsSection(
        title: '步骤 4 · 重签其余可执行文件',
        children: [PrivilegeCodeBlock(code: _signAll, language: 'bash')],
      ),
      SettingsSection(title: '步骤 5 · 重新打包', children: [PrivilegeCodeBlock(code: _repack, language: 'bash')]),
      SettingsSection(
        title: '风险',
        footer: Text('重签前先备份一份能用的 IPA。'),
        children: [
          ListPageRow(
            icon: AppIcons.warning,
            title: '整个磁盘都可读',
            subtitle: 'no-sandbox 之后,任何能跑起来的代码都能读别的 App 的容器和数据库',
            subtitleMaxLines: 2,
          ),
          ListPageRow(
            icon: AppIcons.refresh,
            title: '每次构建都要重签',
            subtitle: '签过的那份 IPA 只对那次构建有效,升级 App 要重来一遍',
            subtitleMaxLines: 2,
          ),
          ListPageRow(
            icon: AppIcons.warning,
            title: 'iOS 升级可能崩溃',
            subtitle: '私有签名权限不保证跨版本可用,系统更新后可能直接起不来',
            subtitleMaxLines: 2,
          ),
        ],
      ),
    ],
  );
}

/// A paragraph of body text inside a settings card.
class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 12),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.6),
      ),
    );
  }
}

/// 等宽的代码块 + 复制键. The text is selectable (long-press, then drag) and the
/// key copies the whole block, so following a step never means retyping it.
class PrivilegeCodeBlock extends StatelessWidget {
  const PrivilegeCodeBlock({super.key, required this.code, this.language});

  final String code;

  /// A short language tag beside the copy key (`bash`, `xml`); null shows
  /// nothing.
  final String? language;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (language case final tag?) Text(tag, style: AppType.monoLabel(color: dsh.textTertiary)),
              const Spacer(),
              Semantics(
                button: true,
                label: l10n.commonCopy,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_copy(context)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(AppIcons.copy, size: 14, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          l10n.commonCopy,
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          DecoratedBox(
            decoration: ShapeDecoration(color: dsh.codeWellBg, shape: AppShape.card),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: SelectableText(code, style: AppType.mono(color: dsh.codeWellFg, height: 1.5)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (context.mounted) showBriefNotice(context, context.l10n.commonCopied);
  }
}
