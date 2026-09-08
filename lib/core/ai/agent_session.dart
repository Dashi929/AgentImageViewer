/// Agent 会话（设计书 2.4）：模型决议 → 本地工具执行 → 结果回填 → 继续推理。
///
/// 事件流驱动 UI 面板：文本增量、任务卡片、确认卡片、错误与重试。
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_image_viewer/core/ai/queue.dart';

import 'ai_client.dart';
import 'agent_tools.dart';
import 'chat_stream.dart';
import 'generative.dart';
import 'vision_tagger.dart';

sealed class AgentEvent {}

class AgentText extends AgentEvent {
  AgentText(this.text);
  final String text; // 模型回复（整段）
}

/// 流式文本增量（设计书 4.3.4：模型回复流式输出）。
/// UI 侧把增量追加到正在生成的气泡；会话结束前的 [AgentText]
/// 携带完整文本用于收敛。
class AgentTextDelta extends AgentEvent {
  AgentTextDelta(this.delta);
  final String delta;
}

class AgentToolRun extends AgentEvent {
  AgentToolRun(this.toolName, this.args);
  final String toolName;
  final Map<String, Object?> args;
}

class AgentConfirmNeeded extends AgentEvent {
  AgentConfirmNeeded(this.action);
  final PendingAction action;
}

class AgentError extends AgentEvent {
  AgentError(this.message);
  final String message;
}

/// 批量任务卡片（设计书 4.3.4：任务卡片展示进度，失败可单独重试）。
class AgentTaskCard extends AgentEvent {
  AgentTaskCard(this.task);
  final AiTask<List<String>> task;
}

/// 判断是否为批量打标类指令（纯函数，可单测）。
bool isBatchTagIntent(String text) {
  final t = text.toLowerCase();
  final wantsBatch = t.contains('批量') ||
      t.contains('所有') ||
      t.contains('全部') ||
      t.contains('每个') ||
      t.contains('每张');
  final wantsTag = t.contains('打标') || t.contains('标签') || t.contains('整理');
  return wantsBatch && wantsTag;
}

/// 指令 → 本地滤镜节点 的编译（设计书 ai_edit）。
/// 返回 null 表示无法本地编译（生成式能力当前版本不支持）。
class EditPlan {
  EditPlan(this.nodes, this.explanation);
  final List<({String op, Map<String, Object?> params})> nodes;
  final String explanation;
}

class AgentSession {
  AgentSession({
    required this.client,
    required this.tools,
    this.visionModel,
    this.generative,
    this.maxTurns = 8,
  });

  final ChatBackend client;
  final AgentTools tools;

  /// 生成式图像编辑客户端（背景替换/消除/扩图）；为 null 时该类指令被拒绝。
  final GenerativeClient? generative;

  /// 视觉模型名（识图/OCR 单独使用；为空则退回对话模型）。
  final String? visionModel;
  final int maxTurns;

  final List<ChatMessage> _history = [
    ChatMessage.system(
        '你是 AgentImageViewer 内置的图片助手。你可以调用工具识图、打标、整理、检索与编辑图片。'
        '涉及真实文件的写操作必须先调用工具生成确认请求，等待用户确认。'
        '回复使用简体中文，简洁直接。'),
  ];

  Stream<AgentEvent> send(String userText) async* {
    // 批量打标：不走对话循环，直接构造串行任务队列（逐项容错 + 进度卡片）
    if (isBatchTagIntent(userText)) {
      yield* _runBatchTag(userText);
      return;
    }
    _history.add(ChatMessage.user(userText));

    for (var turn = 0; turn < maxTurns; turn++) {
      String acc = '';
      List<ToolCall>? streamCalls;
      try {
        await for (final chunk in client.chatStream(
          _history,
          StreamOptions(tools: [for (final s in tools.specs) s.toOpenAiJson()]),
        )) {
          if (chunk.toolCalls.isNotEmpty) {
            streamCalls = chunk.toolCalls;
            break;
          }
          if (chunk.textDelta.isNotEmpty) {
            acc += chunk.textDelta;
            yield AgentTextDelta(chunk.textDelta);
          }
        }
      } catch (e) {
        yield AgentError(e.toString());
        return;
      }

      if (streamCalls != null && streamCalls.isNotEmpty) {
        _history.add(ChatMessage.assistant(acc, toolCalls: streamCalls));
        for (final call in streamCalls) {
          yield AgentToolRun(call.name, call.arguments);
          final result = await _executeTool(call);
          if (result.pendingAction != null) {
            // 需要确认：挂起该工具（历史里记录等待态），把确认卡片交给 UI
            yield AgentConfirmNeeded(result.pendingAction!);
            _history.add(ChatMessage.tool(
                call.id,
                '已生成变更清单，等待用户确认。用户确认后由本地执行，结果将在下轮告知。'));
          } else {
            _history.add(ChatMessage.tool(call.id, result.text ?? ''));
          }
        }
        continue; // 结果回填后继续推理
      }

      _history.add(ChatMessage.assistant(acc));
      if (acc.isNotEmpty) yield AgentText(acc);
      return;
    }
    yield AgentError('达到最大工具轮次（$maxTurns），任务中止。');
  }

  /// 批量打标任务：对当前浏览文件夹（无浏览时回退本地库）逐张视觉识别，
  /// 写入标签与虚拟标题。
  Stream<AgentEvent> _runBatchTag(String userText) async* {
    final entries = tools.currentBrowseList();
    if (entries.isEmpty) {
      yield AgentError('当前没有可打标的图片：请先打开一个文件夹再试。');
      return;
    }
    final tagger = VisionTagger(client);
    final task = AiTask<List<String>>('批量打标（${entries.length} 张）', [
      for (final e in entries)
        TaskItem(e.path, e.displayName, () async {
          final bytes = await tools.visionImageOfPath(e.path);
          final r = await tagger.tagImage(bytes);
          if (r == null) throw Exception('图片读取失败');
          for (final t in r.tags) {
            tools.library.addTag(e.path, t);
          }
          if (r.title.isNotEmpty) {
            tools.library.setVirtualName(e.path, r.title);
          }
          return r.tags;
        }),
    ]);
    yield AgentTaskCard(task);
    await task.run();
    await tools.library.flush();
    final fail = task.failedCount;
    yield AgentText(fail == 0
        ? '批量打标完成：${task.successCount}/${entries.length} 张成功。'
        : '批量打标完成：成功 ${task.successCount}，失败 $fail（可在任务卡片中重试）。');
  }

  Future<AgentToolResult> _executeTool(ToolCall call) async {
    try {
      if (call.name == 'describe_image' || call.name == 'ocr_image') {
        return await _vision(call.name, call.arguments);
      }
      if (call.name == 'ai_edit') {
        return await _aiEdit(call.arguments);
      }
      return await tools.dispatch(call.name, call.arguments);
    } catch (e) {
      return AgentToolResult.error('工具执行失败：$e');
    }
  }

  Future<AgentToolResult> _vision(String name, Map<String, Object?> args) async {
    final path = args['path'] as String? ?? '';
    try {
      final bytes = await tools.visionImageOfPath(path);
      final prompt = name == 'describe_image'
          ? '请描述这张图片：主体、场景、风格、可见文字。'
          : '提取图片中所有可见文字，按原文返回，不要解释。';
      final resp = await client.chat(messages: [
        ChatMessage.user(prompt, images: [bytes]),
      ]);
      return AgentToolResult.ok(resp.message.text);
    } catch (e) {
      return AgentToolResult.error('视觉模型调用失败：$e');
    }
  }

  EditPlan _compileEdit(Map<String, Object?> args) {
    final instruction = args['instruction'] as String? ?? '';
    final nodes = <({String op, Map<String, Object?> params})>[];
    final ins = instruction.toLowerCase();

    // 简单规则编译：关键词 → 节点参数（S4 范围；复杂指令由对话模型给出 JSON，后续迭代）
    void add(String op, Map<String, Object?> params) =>
        nodes.add((op: op, params: params));

    if (ins.contains('黑白')) add('preset', {'name': 'bw'});
    if (ins.contains('复古')) add('preset', {'name': 'sepia'});
    if (ins.contains('胶片')) add('preset', {'name': 'film'});
    if (ins.contains('日系')) {
      add('preset', {'name': 'cool'});
      add('adjust', {'brightness': 0.06, 'saturation': -0.1});
    } else if (ins.contains('冷调') || ins.contains('冷色')) {
      add('preset', {'name': 'cool'});
    } else if (ins.contains('暖调') || ins.contains('暖色')) {
      add('preset', {'name': 'warm'});
    }
    if (ins.contains('亮度')) add('adjust', {'brightness': 0.1});
    if (ins.contains('对比')) add('adjust', {'contrast': 0.15});
    if (ins.contains('锐化') || ins.contains('清晰')) {
      return EditPlan(nodes, '清晰度增强暂不支持，已忽略该子指令');
    }

    if (nodes.isEmpty) {
      return EditPlan(const [], '无法把指令「$instruction」编译为本地编辑操作');
    }
    return EditPlan(nodes, '已编译为 ${nodes.length} 个本地编辑节点');
  }

  /// ai_edit：先尝试本地编译；生成式指令走云端（需配置 + 用户确认上传）。
  Future<AgentToolResult> _aiEdit(Map<String, Object?> args) async {
    final path = args['path'] as String? ?? '';
    final instruction = args['instruction'] as String? ?? '';

    if (!isGenerativeInstruction(instruction)) {
      final plan = _compileEdit(args);
      return AgentToolResult.ok(
          '${plan.explanation}${plan.nodes.isEmpty ? '' : '：${plan.nodes.map((n) => n.op).join(' → ')}'}');
    }

    final gen = generative;
    if (gen == null) {
      return AgentToolResult.ok('生成式改图（$instruction）需要先在「设置 → AI 设置」配置图像编辑模型。');
    }

    // 出确认卡前先校验目标：不让用户确认一个注定失败的操作
    if (!File(path).existsSync()) {
      return AgentToolResult.error('生成式改图失败：文件不存在（$path）。请确认图片路径。');
    }

    return AgentToolResult.confirm(PendingAction(
      toolName: 'ai_edit_generative',
      summary: '生成式改图需要把「$path」上传到 ${gen.config.baseUrl} '
          '（模型 ${gen.config.model}）执行：「$instruction」。\n'
          '上传后图片将由该服务处理，结果保存为副本，不覆盖原图。是否继续？',
      execute: () async {
        final bytes = await File(path).readAsBytes();
        final result = await gen.editImage(imageBytes: bytes, prompt: instruction);
        final dir = path.substring(0, path.lastIndexOf(Platform.pathSeparator));
        final base = path
            .substring(path.lastIndexOf(Platform.pathSeparator) + 1)
            .replaceAll(RegExp('[.][^.]+\$'), '');
        final target = '$dir${Platform.pathSeparator}${base}_ai.png';
        await File(target).writeAsBytes(result.pngBytes, flush: true);
        return '生成完成，已保存副本：$target';
      },
    ));
  }

  /// 用户在确认卡片点击「确认」后由 UI 调用；结果回填会话。
  Future<String> resolveConfirmation(PendingAction action, {required bool approved}) async {
    if (!approved) {
      _history.add(ChatMessage.user('（用户拒绝了上述写操作）'));
      return '已取消';
    }
    try {
      final result = await action.execute();
      _history.add(ChatMessage.user('（用户确认执行了上述写操作，结果：$result）'));
      return result;
    } catch (e) {
      _history.add(ChatMessage.user('（用户确认执行上述写操作时失败：$e）'));
      return '执行失败：$e';
    }
  }

  String dumpHistory() =>
      const JsonEncoder.withIndent('  ').convert([for (final m in _history) m.toJson()]);
}
