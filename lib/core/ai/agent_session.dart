/// Agent 会话（设计书 2.4）：模型决议 → 本地工具执行 → 结果回填 → 继续推理。
///
/// 事件流驱动 UI 面板：文本增量、任务卡片、确认卡片、错误与重试。
library;

import 'dart:convert';

import 'ai_client.dart';
import 'agent_tools.dart';

sealed class AgentEvent {}

class AgentText extends AgentEvent {
  AgentText(this.text);
  final String text; // 模型回复（整段）
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
    this.maxTurns = 8,
  });

  final ChatBackend client;
  final AgentTools tools;

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
    _history.add(ChatMessage.user(userText));

    for (var turn = 0; turn < maxTurns; turn++) {
      final ChatResponse resp;
      try {
        resp = await client.chat(messages: _history, tools: [
          for (final s in tools.specs) s.toOpenAiJson(),
        ]);
      } catch (e) {
        yield AgentError(e.toString());
        return;
      }

      if (resp.finishReason == 'tool_calls' || resp.message.toolCalls.isNotEmpty) {
        _history.add(resp.message);
        for (final call in resp.message.toolCalls) {
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

      final text = resp.message.text;
      _history.add(resp.message);
      if (text.isNotEmpty) yield AgentText(text);
      return;
    }
    yield AgentError('达到最大工具轮次（$maxTurns），任务中止。');
  }

  Future<AgentToolResult> _executeTool(ToolCall call) async {
    try {
      if (call.name == 'describe_image' || call.name == 'ocr_image') {
        return await _vision(call.name, call.arguments);
      }
      if (call.name == 'ai_edit') {
        final plan = _compileEdit(call.arguments);
        return AgentToolResult.ok(
            '${plan.explanation}${plan.nodes.isEmpty ? '' : '：${plan.nodes.map((n) => n.op).join(' → ')}'}');
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
    if (ins.contains('冷调') || ins.contains('冷色')) add('preset', {'name': 'cool'});
    if (ins.contains('暖调') || ins.contains('暖色')) add('preset', {'name': 'warm'});
    if (ins.contains('日系')) {
      add('preset', {'name': 'cool'});
      add('adjust', {'brightness': 0.06, 'saturation': -0.1});
    }
    if (ins.contains('亮度')) add('adjust', {'brightness': 0.1});
    if (ins.contains('对比')) add('adjust', {'contrast': 0.15});
    if (ins.contains('锐化') || ins.contains('清晰')) {
      return EditPlan(nodes, '清晰度增强暂不支持，已忽略该子指令');
    }
    if (ins.contains('背景') || ins.contains('消除') || ins.contains('扩图')) {
      return EditPlan(const [], '该指令涉及生成式云端处理，当前版本不支持（执行前会上传图片，需要更多授权）。');
    }

    if (nodes.isEmpty) {
      return EditPlan(const [], '无法把指令「$instruction」编译为本地编辑操作');
    }
    return EditPlan(nodes, '已编译为 ${nodes.length} 个本地编辑节点');
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
