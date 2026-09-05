/// 流式对话（设计书 4.3.4：模型回复流式输出）。
///
/// OpenAI SSE 契约：`data: {chunk}` 行流，`data: [DONE]` 结束。
/// 工具调用增量按 index 合并后一次性回调。
library;

import 'dart:convert';

import 'ai_client.dart';

class StreamChunk {
  StreamChunk.text(this.textDelta) : toolCalls = const [];
  StreamChunk.toolCalls(this.toolCalls) : textDelta = '';

  /// 增量文本（可为空串）。
  final String textDelta;

  /// 流结束后合并完成的工具调用（仅最后一个 chunk 携带）。
  final List<ToolCall> toolCalls;
}

class StreamOptions {
  StreamOptions({this.tools = const [], this.temperature = 0.4});
  final List<Map<String, Object?>> tools;
  final double temperature;
}

/// 解析 SSE 数据行累积出 chunk（纯函数集合，可单测）。
class SseAccumulator {
  final _content = StringBuffer();
  final _tools = <int, _ToolAccum>{};
  bool done = false;

  String get fullText => _content.toString();

  /// 喂入一行（不含换行）。返回文本增量（无增量返回空串）。
  String feed(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.startsWith('data:')) return '';
    final payload = trimmed.substring(5).trim();
    if (payload == '[DONE]') {
      done = true;
      return '';
    }
    try {
      final json = jsonDecode(payload) as Map;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) return '';
      final delta = (choices.first as Map)['delta'] as Map? ?? {};
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        _content.write(content);
        return content;
      }
      final rawCalls = delta['tool_calls'] as List?;
      if (rawCalls != null) {
        for (final rc in rawCalls) {
          final m = rc as Map;
          final idx = (m['index'] as num?)?.toInt() ?? 0;
          final acc = _tools.putIfAbsent(idx, () => _ToolAccum());
          if (m['id'] is String) acc.id = m['id'] as String;
          final fn = m['function'] as Map?;
          if (fn?['name'] is String) acc.name = fn!['name'] as String;
          if (fn?['arguments'] is String) {
            acc.arguments.write(fn!['arguments'] as String);
          }
        }
      }
    } on FormatException {
      // 非 JSON 行（心跳/注释）忽略
    }
    return '';
  }

  /// 流结束后取合并完成的工具调用。
  List<ToolCall> takeToolCalls() {
    final calls = [
      for (final idx in _tools.keys.toList()..sort())
        ToolCall(
          id: _tools[idx]!.id ?? 'call_$idx',
          name: _tools[idx]!.name ?? '',
          argumentsJson: _tools[idx]!.arguments.toString(),
        ),
    ];
    _tools.clear();
    return calls;
  }
}

class _ToolAccum {
  String? id, name;
  final arguments = StringBuffer();
}
