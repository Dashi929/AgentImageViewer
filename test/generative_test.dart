import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_image_viewer/core/ai/agent_session.dart';
import 'package:agent_image_viewer/core/ai/agent_tools.dart';
import 'package:agent_image_viewer/core/ai/generative.dart';
import 'package:agent_image_viewer/core/ai/queue.dart';
import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/db/library.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:agent_image_viewer/core/ai/ai_client.dart';

import 'ai_client_test.dart' show FakeChat;
import 'package:agent_image_viewer/core/image/heic_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generative：multipart 构建', () {
    test('字段齐全、图片二进制完整、边界一致', () {
      final mp = buildEditMultipart(
        boundary: 'BND',
        model: 'img-edit-1',
        prompt: '把背景替换成纯白',
        imageBytes: [1, 2, 3, 4],
      );
      final body = utf8.decode(mp.body, allowMalformed: true);
      expect(mp.contentType, 'multipart/form-data; boundary=BND');
      expect(body, contains('name="model"'));
      expect(body, contains('img-edit-1'));
      expect(body, contains('name="prompt"'));
      expect(body, contains('把背景替换成纯白'));
      expect(body, contains('name="image"; filename="image.png"'));
      expect(body, contains('--BND--'));
      expect(mp.body, containsAllInOrder([1, 2, 3, 4]));
    });

    test('isGenerativeInstruction 与本地编译互斥', () {
      expect(isGenerativeInstruction('把背景替换成纯白'), isTrue);
      expect(isGenerativeInstruction('对象消除'), isTrue);
      expect(isGenerativeInstruction('向两边扩图'), isTrue);
      expect(isGenerativeInstruction('调成日系冷调'), isFalse);
      expect(isGenerativeInstruction('黑白滤镜'), isFalse);
    });
  });

  group('generative：端到端（本地 HttpServer 桩）', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        expect(req.uri.path, endsWith('/images/edits'));
        expect(body, contains('name="model"'));
        expect(req.headers.value('authorization'), 'Bearer sk-gen');
        // 返回 2x2 红色 PNG（b64）
        final pngB64 = base64Encode(_tinyPng());
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'data': [
          {'b64_json': pngB64}
        ]}));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('editImage 提交 multipart 并解析 b64_json', () async {
      final gen = GenerativeClient(GenerativeConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'sk-gen',
        model: 'img-edit-1',
      ));
      final result = await gen.editImage(imageBytes: [1, 2, 3], prompt: '去背景');
      expect(result.pngBytes.sublist(0, 8),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // PNG 签名
      gen.dispose();
    });
  });

  group('上下文联动 resolveTargetPath', () {
    const current = r'E:\pics\cat.jpg';
    test('「这张图」注入当前路径', () {
      expect(resolveTargetPath('描述一下这张图', current), current);
      expect(resolveTargetPath('把当前图调成黑白', current), current);
    });
    test('明确路径时不注入', () {
      expect(
          resolveTargetPath(r'描述一下 E:\other\dog.jpg', current), isNull);
    });
    test('无当前图或无指代时不注入', () {
      expect(resolveTargetPath('描述一下这张图', null), isNull);
      expect(resolveTargetPath('给这个文件夹打标签', current), isNull);
    });
  });

  group('生成式会话流程', () {
    late HttpServer server;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('aiv_gen_session');
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'data': [
          {'b64_json': base64Encode(_tinyPng())}
        ]}));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    test('ai_edit 生成式：确认卡片披露上传 → 确认后副本落盘', () async {
      final dir = '${tmp.path}${Platform.pathSeparator}pics';
      await Directory(dir).create();
      final img = File('$dir${Platform.pathSeparator}photo.jpg');
      await img.writeAsBytes([1, 2, 3]);

      final lib = LibraryIndex(JsonStore(baseDir: tmp));
      await lib.addFolder(dir);
      lib.upsert(ImageEntry(
          path: img.path, name: 'photo.jpg', sizeBytes: 3, mtimeMs: 1));

      final fake = FakeChat([
        resp({
          'content': '',
          'tool_calls': [
            {
              'id': 'g1',
              'type': 'function',
              'function': {
                'name': 'ai_edit',
                'arguments': jsonEncode({
                  'path': img.path,
                  'instruction': '把背景替换成沙滩',
                }),
              },
            }
          ],
        }),
      ]);
      final session = AgentSession(
        client: fake,
        tools: AgentTools(library: lib, visionImageOfPath: (_) async => []),
        generative: GenerativeClient(GenerativeConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'sk-gen',
          model: 'img-edit-1',
        )),
      );

      PendingAction? action;
      await for (final e in session.send('处理这张图')) {
        if (e is AgentConfirmNeeded) action = e.action;
      }
      expect(action, isNotNull, reason: '生成式改图必须先出确认卡');
      expect(action!.summary, contains('上传'));
      expect(action.summary, contains('img-edit-1'));

      final result = await session.resolveConfirmation(action, approved: true);
      expect(result, contains('_ai.png'));
      expect(File('$dir${Platform.pathSeparator}photo_ai.png').existsSync(),
          isTrue);
    });

    test('未配置生成式模型时明确拒绝', () async {
      final fake = FakeChat([
        resp({
          'content': '',
          'tool_calls': [
            {
              'id': 'g2',
              'type': 'function',
              'function': {
                'name': 'ai_edit',
                'arguments': jsonEncode({
                  'path': 'x.jpg',
                  'instruction': '消除路人',
                }),
              },
            }
          ],
        }),
      ]);
      final session = AgentSession(
        client: fake,
        tools: AgentTools(
            library: LibraryIndex(JsonStore(baseDir: tmp)),
            visionImageOfPath: (_) async => []),
      );
      final texts = <String>[];
      await for (final e in session.send('处理')) {
        if (e is AgentText) texts.add(e.text);
      }
      final toolMsgs = fake.lastMessages
          .where((m) => m.role == 'tool')
          .map((m) => m.text)
          .join();
      expect(toolMsgs, contains('配置图像编辑模型'));
    });
  });

  group('HEIC 引导', () {
    test('检测命令与商店 URI 构建', () {
      expect(buildHeifDetectCommand().join(' '),
          contains('Microsoft.HEIFImageExtension'));
      expect(heifStoreUri().toString(), contains('ms-windows-store'));
      expect(heicGuidanceText(HeicSupport.missing), contains('HEIF 图像扩展'));
      expect(heicGuidanceText(HeicSupport.supported), isEmpty);
    });
  });
}

ChatResponse resp(Map<String, Object?> message) => ChatResponse(
      finishReason: message['tool_calls'] != null ? 'tool_calls' : 'stop',
      message: ChatMessage.assistant(
        (message['content'] as String?) ?? '',
        toolCalls: (message['tool_calls'] as List? ?? [])
            .map((t) => ToolCall(
                  id: ((t as Map)['id'] as String?) ?? '',
                  name: (((t)['function'] as Map)['name'] as String?) ?? '',
                  argumentsJson:
                      (((t)['function'] as Map)['arguments'] as String?) ?? '{}',
                ))
            .toList(),
      ),
    );

/// 最小 PNG：8 字节签名 + 垫片（测试只校验签名与落盘）。
Uint8List _tinyPng() => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0,
    ]);
