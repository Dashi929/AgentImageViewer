/// AI 助手面板（设计书 4.3.4）：会话流 + 任务卡片 + 确认卡片。
library;

import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/ai/agent_session.dart';
import '../../core/ai/ai_client.dart';
import '../../core/ai/agent_tools.dart';
import '../../core/ai/generative.dart';
import '../../core/db/settings.dart';
import '../theme.dart';

class AiPanel extends StatefulWidget {
  const AiPanel({super.key});

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _Entry {
  _Entry.text(this.text, {this.isError = false}) : action = null;
  _Entry.confirm(this.action) : text = null, isError = false;
  _Entry.tool(this.text) : action = null, isError = false;

  final String? text;
  final bool isError;
  final PendingAction? action;
  bool resolved = false;
}

class _AiPanelState extends State<AiPanel> {
  final _entries = <_Entry>[];
  final _input = TextEditingController();
  AgentSession? _session;
  bool _busy = false;
  String _configError = '';
  AppState? _appRef;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    final app = AppStateScope.of(context, listen: false);
    final settings = await SettingsStore(app.store).load();
    if (!mounted) return;
    _appRef = app;
    if (!settings.aiConfigured) {
      setState(() => _configError = '尚未配置 AI 服务：请到「设置 → AI 设置」填写 API 地址与密钥。');
      return;
    }
    final client = AiClient(AiConfig(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.apiKey,
      model: settings.chatModel,
    ));
    final gen = settings.generativeEnabled
        ? GenerativeClient(GenerativeConfig(
            baseUrl: settings.aiBaseUrl,
            apiKey: settings.apiKey,
            model: settings.imageEditModel,
          ))
        : null;
    setState(() {
      _session = AgentSession(
        client: client,
        tools: AgentTools(
          library: app.library,
          visionImageOfPath: (path) => _readImageBytes(path),
        ),
        visionModel: settings.visionModel,
        generative: gen,
      );
      _configError = '';
    });
  }

  Future<List<int>> _readImageBytes(String path) async {
    // v0.2 简化：读原文件字节。超过 8MB 时改走 320px 缩略图缓存（S6 再细化带宽策略）。
    final f = File(path);
    final size = await f.length();
    if (size > 8 * 1024 * 1024) {
      final app = _appRef;
      if (app == null) return f.readAsBytes();
      final st = await f.stat();
      final thumb = await app.images.decode(path, st.modified.millisecondsSinceEpoch, target: 320);
      final data = await thumb.image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }
    return f.readAsBytes();
  }

  /// 当前浏览图片（设计书 5.5：'描述一下这张图' 依赖当前图上下文）
  String? get _currentImagePath {
    final v = NavigatorStateEx.viewer.value;
    if (v == null) return null;
    return v.list[v.index].path;
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    if (text.isEmpty || _session == null || _busy) return;
    _input.clear();
    // 上下文联动：'这张图' 类指令自动携带当前浏览路径
    final target = resolveTargetPath(text, _currentImagePath);
    if (target != null) {
      text = '$text${String.fromCharCode(10)}（上下文：当前正在查看 $target）';
    }
    setState(() {
      _busy = true;
      _entries.add(_Entry.text(_inputText(text, target != null)));
    });
    await for (final ev in _session!.send(text)) {
      if (!mounted) return;
      setState(() {
        switch (ev) {
          case AgentText(:final text):
            _entries.add(_Entry.text(text));
          case AgentToolRun(:final toolName, :final args):
            _entries.add(_Entry.tool('调用工具 $toolName（${args.keys.join('/')}）…'));
          case AgentConfirmNeeded(:final action):
            _entries.add(_Entry.confirm(action));
          case AgentError(:final message):
            _entries.add(_Entry.text(message, isError: true));
        }
      });
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _resolve(_Entry entry, bool approved) async {
    if (entry.action == null || entry.resolved) return;
    final result = await _session!.resolveConfirmation(entry.action!, approved: approved);
    if (!mounted) return;
    setState(() {
      entry.resolved = true;
      _entries.add(_Entry.tool(result));
    });
  }

  @override
  void dispose() {
    _session?.client.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, size: 18, color: AppColors.aiAccent),
              const SizedBox(width: 8),
              const Text('AI 助手',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_busy)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
        if (_configError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: AppColors.danger, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_configError,
                            style: const TextStyle(fontSize: 12))),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: _entries.isEmpty
              ? _suggestions()
              : ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: _entries.length,
                  itemBuilder: (context, i) => _bubble(_entries[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_busy && _session != null,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '例如：给这个文件夹里的截图打标签',
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _busy ? null : _send,
                icon: const Icon(Icons.send, size: 18),
                tooltip: '发送',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _suggestions() {
    final suggestions = [
      '描述一下这张图',
      '给这个文件夹里的截图打标签',
      '把模糊的连拍挑出来',
      '把人像图按单人/多人分类',
    ];
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in suggestions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: OutlinedButton(
                onPressed: () {
                  _input.text = s;
                  _send();
                },
                child: Text(s, style: const TextStyle(fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bubble(_Entry e) {
    if (e.action != null) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.fact_check_outlined,
                      size: 16, color: AppColors.danger),
                  const SizedBox(width: 6),
                  const Text('需要确认的写操作',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              Text(e.action!.summary,
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary)),
              const SizedBox(height: 10),
              if (!e.resolved)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => _resolve(e, false),
                        child: const Text('取消')),
                    FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger),
                        onPressed: () => _resolve(e, true),
                        child: const Text('确认执行')),
                  ],
                )
              else
                const Text('已处理',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
    }

    final isUser = e.text != null && !e.isError && !e.text!.startsWith('调用工具');
    final alignRight = isUser && !e.text!.startsWith('（');
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: e.isError
              ? AppColors.danger.withValues(alpha: 0.12)
              : alignRight
                  ? AppColors.accent.withValues(alpha: 0.15)
                  : AppColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: e.isError ? AppColors.danger : Colors.white.withValues(alpha: 0.06)),
        ),
        child: Text(
          e.text ?? '',
          style: TextStyle(
              fontSize: 13,
              color: e.isError ? AppColors.danger : AppColors.textPrimary),
        ),
      ),
    );
  }
}

/// 面板显示文案：注入上下文时不暴露长路径。
String _inputText(String text, bool injected) =>
    injected ? text.split('${String.fromCharCode(10)}（上下文：')[0] : text;
