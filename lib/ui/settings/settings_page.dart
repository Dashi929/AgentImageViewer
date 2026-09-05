/// 设置页（设计书 4.3.5）：AI 设置 / 性能 / 系统 / 关于 四组。
library;

import 'package:flutter/material.dart';

import 'dart:io' show Platform;

import '../../app_state.dart';
import '../../core/db/settings.dart';
import '../../platform/file_assoc.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings? _settings;
  bool _assocEnabled = false;

  void _showResult(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(msg, style: const TextStyle(fontSize: 13))));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context, listen: false);
    final s = await SettingsStore(app.store).load();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _persist() async {
    final app = AppStateScope.of(context, listen: false);
    await SettingsStore(app.store).save(_settings!);
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    if (s == null) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent));
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _group('AI 设置',
            '兼容任何 OpenAI 格式服务（智谱 GLM、GPT-4o 等）。密钥仅保存在本机 settings.json。', [
          _field('API 地址', s.aiBaseUrl, (v) => s.aiBaseUrl = v),
          _field('API Key', s.apiKey, (v) => s.apiKey = v, obscure: true),
          _field('对话模型', s.chatModel, (v) => s.chatModel = v),
          _field('视觉模型', s.visionModel, (v) => s.visionModel = v),
          _field('图像编辑模型（生成式改图，留空禁用）', s.imageEditModel,
              (v) => s.imageEditModel = v),
        ]),
        _group('性能', '常规浏览常驻内存目标：桌面 ≤ 512 MB，移动端 ≤ 256 MB。', [
          _dropdown('缩略图尺寸', s.thumbSize.toString(), const ['160', '320', '480'],
              (v) => s.thumbSize = int.parse(v)),
          _dropdown('解码缓存上限', '${s.cacheMB} MB', const ['256 MB', '512 MB', '1024 MB'],
              (v) => s.cacheMB = int.parse(v.split(' ').first)),
        ]),
        _group('系统', '文件关联写入当前用户注册表（HKCU），无需管理员权限。', [
          if (!Platform.isAndroid && !Platform.isIOS) ...[
            SwitchListTile(
              value: _assocEnabled,
              onChanged: (v) async {
                final assoc = FileAssoc(
                  exeName: 'AgentImageViewer',
                  exePath: Platform.resolvedExecutable,
                  iconPath: Platform.resolvedExecutable,
                );
                final ok = v
                    ? await assoc.register(defaultAssocExtensions)
                    : await assoc.unregister(defaultAssocExtensions);
                if (mounted) {
                  setState(() => _assocEnabled = v && ok);
                  _showResult(ok ? '文件关联已${v ? '注册' : '取消'}' : '操作失败，请重试');
                }
              },
              title: const Text('设为以下格式的默认打开方式',
                  style: TextStyle(fontSize: 14)),
              subtitle: const Text('jpg jpeg png gif webp bmp avif',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
          const ListTile(
            enabled: false,
            leading: Icon(Icons.shield_outlined, size: 20),
            title: Text('托盘常驻（AI 任务通知）', style: TextStyle(fontSize: 14)),
            subtitle: Text('v0.3 提供', style: TextStyle(fontSize: 12)),
          ),
        ]),
        _group('关于', '', [
          const ListTile(
            leading: Icon(Icons.info_outline, size: 20),
            title: Text('AgentImageViewer', style: TextStyle(fontSize: 14)),
            subtitle: Text('v0.1.0 · Agent 系列应用 · 本地优先，断网可用',
                style: TextStyle(fontSize: 12)),
          ),
        ]),
      ],
    );
  }

  Widget _group(String title, String desc, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(desc,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(String label, String init, ValueChanged<String> onSaved,
      {bool obscure = false}) {
    final ctrl = TextEditingController(text: init);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label, isDense: true),
        onSubmitted: (v) {
          onSaved(v);
          _persist();
        },
        onTapOutside: (_) {
          if (ctrl.text != init) {
            onSaved(ctrl.text);
            _persist();
          }
        },
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> items,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<String>(
        initialValue: items.contains(value) ? value : items.first,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final it in items)
            DropdownMenuItem(value: it, child: Text(it, style: const TextStyle(fontSize: 13))),
        ],
        onChanged: (v) {
          if (v != null) {
            onChanged(v);
            _persist();
          }
        },
      ),
    );
  }
}
