/// OpenAI 兼容客户端（设计书 3.7）：多模态消息、指数退避重试、错误归一。
///
/// 以 OpenAI chat/completions 为唯一契约（表 8-1：AI 服务商差异对策）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 一条多模态消息。content 可为纯文本或 文本+图片(base64) 组合。
class ChatMessage {
  ChatMessage.system(this.text)
      : role = 'system',
        images = const [],
        toolCalls = const [],
        toolCallId = null;
  ChatMessage.user(this.text, {this.images = const []})
      : role = 'user',
        toolCalls = const [],
        toolCallId = null;
  ChatMessage.assistant(this.text, {this.toolCalls = const []})
      : role = 'assistant',
        images = const [],
        toolCallId = null;
  ChatMessage.tool(this.toolCallId, this.text)
      : role = 'tool',
        images = const [],
        toolCalls = const [];

  final String role;
  final String text;
  final List<List<int>> images; // 原始字节（JPEG/PNG）
  final List<ToolCall> toolCalls;
  final String? toolCallId;

  /// OpenAI content 结构：纯文本或 image_url 数组。
  Object toContentJson() {
    if (images.isEmpty) return text;
    return [
      {'type': 'text', 'text': text},
      for (final img in images)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/jpeg;base64,${base64Encode(img)}',
          },
        },
    ];
  }

  Map<String, Object?> toJson() => {
        'role': role,
        'content': toContentJson(),
        if (toolCalls.isNotEmpty)
          'tool_calls': [for (final t in toolCalls) t.toJson()],
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

/// 兼容类型：接受 Uint8List 或 Int8List 等定长字节容器。
class ToolCall {
  ToolCall({required this.id, required this.name, required this.argumentsJson});

  final String id;
  final String name;
  final String argumentsJson; // 原始 JSON 字符串

  Map<String, Object?> get arguments =>
      jsonDecode(argumentsJson) as Map<String, Object?>? ?? {};

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': argumentsJson},
      };
}

class AiConfig {
  AiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 120),
    this.maxRetries = 2,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final int maxRetries;
}

class AiException implements Exception {
  AiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? 'AI 错误：$message' : 'AI 错误($statusCode)：$message';
}

class ChatResponse {
  ChatResponse({required this.message, required this.finishReason});
  final ChatMessage message;
  final String finishReason; // stop | tool_calls | length
}

/// 对话后端接口（AgentSession 依赖此抽象，测试可注入桩）。
abstract class ChatBackend {
  Future<ChatResponse> chat({
    required List<ChatMessage> messages,
    List<Map<String, Object?>> tools = const [],
    double temperature = 0.4,
  });

  void dispose();
}

class AiClient implements ChatBackend {
  AiClient(this.config);

  final AiConfig config;
  HttpClient? _client;

  HttpClient get _http => _client ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);

  Uri get _uri {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return Uri.parse('$base/chat/completions');
  }

  @override
  Future<ChatResponse> chat({
    required List<ChatMessage> messages,
    List<Map<String, Object?>> tools = const [],
    double temperature = 0.4,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      }
      try {
        return await _once(messages, tools, temperature);
      } on SocketException catch (e) {
        lastError = AiException('网络连接失败：${e.message}');
      } on HttpException catch (e) {
        lastError = AiException('网络请求失败：${e.message}');
      } on TimeoutException {
        lastError = AiException('请求超时（${config.timeout.inSeconds}s）');
      } on AiException catch (e) {
        // 4xx 语义错误不重试
        if (e.statusCode != null && e.statusCode! < 500) rethrow;
        lastError = e;
      }
    }
    throw lastError ?? AiException('未知错误');
  }

  Future<ChatResponse> _once(List<ChatMessage> messages,
      List<Map<String, Object?>> tools, double temperature) async {
    final body = jsonEncode({
      'model': config.model,
      'messages': [for (final m in messages) m.toJson()],
      if (tools.isNotEmpty) 'tools': tools,
      'temperature': temperature,
    });

    final req = await _http.postUrl(_uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
    req.contentLength = utf8.encode(body).length;
    req.add(utf8.encode(body));

    final resp = await req.close().timeout(config.timeout);
    final text = await resp.transform(utf8.decoder).join();

    if (resp.statusCode != 200) {
      throw AiException(_normalizeError(text),
          statusCode: resp.statusCode);
    }

    Map<String, Object?> json;
    try {
      json = jsonDecode(text) as Map<String, Object?>;
    } on FormatException {
      throw AiException('响应不是合法 JSON：${text.substring(0, math.min(120, text.length))}');
    }

    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw AiException('响应缺少 choices：${json['error'] ?? text}');
    }
    final choice = choices.first as Map;
    final msg = choice['message'] as Map? ?? {};
    final rawCalls = msg['tool_calls'] as List? ?? const [];
    return ChatResponse(
      finishReason: (choice['finish_reason'] as String?) ?? 'stop',
      message: ChatMessage.assistant(
        (msg['content'] as String?) ?? '',
        toolCalls: [
          for (final tc in rawCalls)
            ToolCall(
              id: ((tc as Map)['id'] as String?) ?? '',
              name: ((((tc)['function'] as Map?) ?? {})['name'] as String?) ?? '',
              argumentsJson:
                  ((((tc)['function'] as Map?) ?? {})['arguments'] as String?) ?? '{}',
            ),
        ],
      ),
    );
  }

  String _normalizeError(String body) {
    try {
      final j = jsonDecode(body) as Map;
      final err = j['error'];
      if (err is Map) return (err['message'] as String?) ?? '服务返回错误';
      if (err is String) return err;
    } catch (_) {}
    if (body.length > 200) return '${body.substring(0, 200)}…';
    return body;
  }

  @override
  void dispose() {
    _client?.close();
    _client = null;
  }
}
