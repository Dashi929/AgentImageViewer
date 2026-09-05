import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_image_viewer/core/ai/ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late List<Map<String, Object?>> requests;

  setUp(() async {
    requests = [];
    server = await HttpServer.bind('127.0.0.1', 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 按脚本依次响应请求
  void enqueue(List<Object Function(Map<String, Object?>)> handlers) {
    var i = 0;
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      requests.add(json);
      final handler = handlers[i.clamp(0, handlers.length - 1)];
      i++;
      final statusOrBody = handler(json);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
          statusOrBody is String ? statusOrBody : jsonEncode(statusOrBody));
      await req.response.close();
    });
  }

  Map<String, Object?> okBody(Map<String, Object?> message) => {
        'choices': [
          {'message': message, 'finish_reason': message['tool_calls'] != null ? 'tool_calls' : 'stop'},
        ],
      };

  AiClient clientOf() => AiClient(AiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v4',
        apiKey: 'sk-test',
        model: 'test-model',
        maxRetries: 0,
      ));

  test('消息序列化：文本与 base64 图片（多模态）', () async {
    enqueue([(json) => okBody({'content': 'ok'})]);
    final c = clientOf();
    final resp = await c.chat(messages: [
      ChatMessage.user('描述图片', images: [Uint8List.fromList([1, 2, 3])]),
    ]);
    expect(resp.message.text, 'ok');

    final sent = requests.first['messages'] as List;
    final content = (sent.first as Map)['content'] as List;
    expect(content[0]['type'], 'text');
    expect(content[1]['type'], 'image_url');
    expect(content[1]['image_url']['url'], startsWith('data:image/jpeg;base64,'));
    expect(requests.first['model'], 'test-model');
    c.dispose();
  });

  test('tool_calls 响应被正确解析', () async {
    enqueue([
      (json) => okBody({
            'content': '',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'tag_image', 'arguments': '{"path":"a.jpg","tags":["风景"]}'},
              }
            ],
          }),
    ]);
    final c = clientOf();
    final resp = await c.chat(messages: [ChatMessage.user('打标')]);
    expect(resp.finishReason, 'tool_calls');
    expect(resp.message.toolCalls.first.name, 'tag_image');
    expect(resp.message.toolCalls.first.arguments['tags'], ['风景']);
    c.dispose();
  });

  test('4xx 语义错误不重试，错误归一', () async {
    server.listen((req) async {
      await utf8.decoder.bind(req).join();
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': {'message': '密钥无效'}}));
      await req.response.close();
    });
    final c = clientOf();
    await expectLater(
      c.chat(messages: [ChatMessage.user('hi')]),
      throwsA(isA<AiException>().having((e) => e.message, 'message', contains('密钥无效'))),
    );
    c.dispose();
  });

  test('5xx 按指数退避重试后成功', () async {
    var hits = 0;
    server.listen((req) async {
      await utf8.decoder.bind(req).join();
      hits++;
      if (hits < 3) {
        req.response.statusCode = 503;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(okBody({'content': '重试成功'})));
      await req.response.close();
    });
    final c = AiClient(AiConfig(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'k',
      model: 'm',
      maxRetries: 2,
    ));
    final resp = await c.chat(messages: [ChatMessage.user('hi')]);
    expect(resp.message.text, '重试成功');
    expect(hits, 3);
    c.dispose();
  });
}

/// ChatBackend 桩：脚本化决议序列（供 AgentSession 测试使用）
class FakeChat extends ChatBackend {
  FakeChat(this.script);

  final List<ChatResponse> script;
  List<ChatMessage> lastMessages = [];
  int calls = 0;

  @override
  Future<ChatResponse> chat({
    required List<ChatMessage> messages,
    List<Map<String, Object?>> tools = const [],
    double temperature = 0.4,
  }) async {
    lastMessages = messages;
    calls++;
    if (calls > script.length) throw AiException('脚本耗尽');
    return script[calls - 1];
  }

  @override
  void dispose() {}
}
