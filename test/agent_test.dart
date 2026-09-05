import 'dart:convert';
import 'dart:io';

import 'package:agent_image_viewer/core/ai/agent_session.dart';
import 'package:agent_image_viewer/core/ai/agent_tools.dart';
import 'package:agent_image_viewer/core/ai/ai_client.dart';
import 'test_utils.dart' show deleteDirWithRetry;
import 'package:agent_image_viewer/core/ai/queue.dart';
import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/db/library.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_client_test.dart' show FakeChat;

// deleteDirWithRetry

ChatResponse resp(Map<String, Object?> message) => ChatResponse(
      finishReason: message['tool_calls'] != null ? 'tool_calls' : 'stop',
      message: ChatMessage.assistant(
        (message['content'] as String?) ?? '',
        toolCalls: (message['tool_calls'] as List? ?? [])
            .map((t) => ToolCall(
                  id: ((t as Map)['id'] as String?) ?? '',
                  name: (((t)['function'] as Map)['name'] as String?) ?? '',
                  argumentsJson: (((t)['function'] as Map)['arguments'] as String?) ?? '{}',
                ))
            .toList(),
      ),
    );

Future<LibraryIndex> libOf(Directory tmp, String dir) async {
  final lib = LibraryIndex(JsonStore(baseDir: tmp));
  await lib.addFolder(dir);
  // 建立真实文件（rename 等真实写操作需要）
  await File('$dir${Platform.pathSeparator}a.jpg').writeAsBytes([1]);
  await File('$dir${Platform.pathSeparator}b.jpg').writeAsBytes([1]);
  lib.upsertAll([
    ImageEntry(path: '$dir${Platform.pathSeparator}a.jpg', name: 'a.jpg', sizeBytes: 1, mtimeMs: 1),
    ImageEntry(path: '$dir${Platform.pathSeparator}b.jpg', name: 'b.jpg', sizeBytes: 1, mtimeMs: 2),
  ]);
  return lib;
}

void main() {
  late Directory tmp;
  late String dir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_agent_test');
    dir = '${tmp.path}${Platform.pathSeparator}pics';
    await Directory(dir).create();
  });
  tearDown(() => deleteDirWithRetry(tmp));

  test('工具循环：模型决议 tag_image → 结果回填 → 最终回复', () async {
    final lib = await libOf(tmp, dir);
    final fake = FakeChat([
      resp({
        'content': '',
        'tool_calls': [
          {
            'id': 'c1',
            'type': 'function',
            'function': {
              'name': 'tag_image',
              'arguments': jsonEncode({
                  'path': '$dir${Platform.pathSeparator}a.jpg',
                  'tags': ['风景'],
                  'title': '山间',
                }),
            },
          }
        ],
      }),
      resp({'content': '已打好标签。'}),
    ]);
    final session = AgentSession(
      client: fake,
      tools: AgentTools(library: lib, visionImageOfPath: (_) async => []),
    );

    final events = <AgentEvent>[];
    await for (final e in session.send('给 a.jpg 打标签')) {
      events.add(e);
    }

    expect(events.whereType<AgentToolRun>(), isNotEmpty);
    expect(events.whereType<AgentText>().last.text, '已打好标签。');
    final entry = lib.entryAt('$dir${Platform.pathSeparator}a.jpg')!;
    expect(entry.tags, ['风景']);
    expect(entry.virtualName, '山间');
    // 工具结果应回填进历史（role=tool）
    expect(fake.lastMessages.any((m) => m.role == 'tool'), isTrue);
  });

  test('rename_batch 生成确认卡片，确认后真实重命名', () async {
    final lib = await libOf(tmp, dir);
    final file = File('$dir${Platform.pathSeparator}a.jpg');
    final fake = FakeChat([
      resp({
        'content': '',
        'tool_calls': [
          {
            'id': 'c2',
            'type': 'function',
            'function': {
              'name': 'rename_batch',
              'arguments': jsonEncode({
                  'renames': [
                    {'path': file.path, 'newName': 'sunset.jpg'},
                  ],
                }),
            },
          }
        ],
      }),
    ]);
    final session = AgentSession(
      client: fake,
      tools: AgentTools(library: lib, visionImageOfPath: (_) async => []),
    );

    PendingAction? action;
    await for (final e in session.send('把它重命名')) {
      if (e is AgentConfirmNeeded) action = e.action;
    }
    expect(action, isNotNull);
    expect(action!.summary, contains('sunset.jpg'));

    final result = await session.resolveConfirmation(action, approved: true);
    expect(result, contains('1 个'));
    expect(file.existsSync(), isFalse);
    expect(File('$dir${Platform.pathSeparator}sunset.jpg').existsSync(), isTrue);
  });

  test('拒绝确认时不改文件', () async {
    final lib = await libOf(tmp, dir);
    final file = File('$dir${Platform.pathSeparator}a.jpg');
    final fake = FakeChat([
      resp({
        'content': '',
        'tool_calls': [
          {
            'id': 'c3',
            'type': 'function',
            'function': {
              'name': 'rename_batch',
              'arguments': jsonEncode({
                  'renames': [
                    {'path': file.path, 'newName': 'x.jpg'},
                  ],
                }),
            },
          }
        ],
      }),
    ]);
    final session = AgentSession(
      client: fake,
      tools: AgentTools(library: lib, visionImageOfPath: (_) async => []),
    );
    PendingAction? action;
    await for (final e in session.send('改名')) {
      if (e is AgentConfirmNeeded) action = e.action;
    }
    final result = await session.resolveConfirmation(action!, approved: false);
    expect(result, '已取消');
    expect(file.existsSync(), isTrue);
  });

  test('ai_edit 编译：风格关键词 → 本地节点；生成式指令被拒绝', () async {
    final lib = await libOf(tmp, dir);
    final tools = AgentTools(library: lib, visionImageOfPath: (_) async => []);

    final warm = tools; // 编译逻辑在 AgentSession._compileEdit，经 dispatch 暴露
    // 直接走会话路径验证
    final fake = FakeChat([
      resp({
        'content': '',
        'tool_calls': [
          {
            'id': 'c4',
            'type': 'function',
            'function': {
              'name': 'ai_edit',
              'arguments': jsonEncode({'path': 'x.jpg', 'instruction': '调成日系冷调'}),
            },
          }
        ],
      }),
      resp({
        'content': '',
        'tool_calls': [
          {
            'id': 'c5',
            'type': 'function',
            'function': {
              'name': 'ai_edit',
              'arguments': jsonEncode({'path': 'x.jpg', 'instruction': '把背景替换成沙滩'}),
            },
          }
        ],
      }),
    ]);
    final session = AgentSession(
      client: fake,
      tools: warm,
    );
    final texts = <String>[];
    await for (final e in session.send('处理')) {
      if (e is AgentToolResult) {}
      if (e is AgentText) texts.add(e.text);
    }
    // 两轮工具后到达最大轮次前结束：验证历史中的工具结果文本
    final toolMsgs =
        fake.lastMessages.where((m) => m.role == 'tool').map((m) => m.text).join('\n');
    expect(toolMsgs, contains('preset'), reason: '日系冷调应编译出 preset 节点');
    expect(toolMsgs, contains('不支持'), reason: '生成式指令应明确拒绝');
  });

  test('AI 任务队列：单张失败不中断，失败可重试，汇总正确', () async {
    var failFirst = true;
    final task = AiTask<String>('批量识别', [
      for (var i = 0; i < 5; i++)
        TaskItem('id$i', 'img$i.png', () async {
          if (i == 0 && failFirst) throw Exception('网络抖动');
          return 'desc$i';
        }),
    ]);

    await task.run();
    expect(task.successCount, 4);
    expect(task.failedCount, 1);
    expect(task.isFinished, isTrue);
    expect(task.summary(), '5/5，失败 1');

    failFirst = false;
    await task.retryFailed();
    expect(task.successCount, 5);
    expect(task.failedCount, 0);
    expect(task.failedItems, isEmpty);
  });
}

extension on AiTask<String> {}
