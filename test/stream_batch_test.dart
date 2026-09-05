import 'package:agent_image_viewer/core/ai/agent_session.dart';
import 'package:agent_image_viewer/core/ai/chat_stream.dart';
import 'package:agent_image_viewer/core/ai/queue.dart';
import 'package:agent_image_viewer/core/ai/vision_tagger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SSE 流解析（设计书 4.3.4 流式输出）', () {
    test('文本增量按序合并', () {
      final acc = SseAccumulator();
      final deltas = [
        acc.feed('data: {"choices":[{"delta":{"content":"你"}}]}'),
        acc.feed(''),
        acc.feed('data: {"choices":[{"delta":{"content":"好"}}]}'),
        acc.feed('data: [DONE]'),
      ];
      expect(deltas.join(), '你好');
      expect(acc.fullText, '你好');
      expect(acc.done, isTrue);
      expect(acc.takeToolCalls(), isEmpty);
    });

    test('tool_calls 增量按 index 合并 arguments 分片', () {
      final acc = SseAccumulator();
      acc.feed(
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"tag_image","arguments":""}}]}}]}');
      acc.feed(
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\""}}]}}]}');
      acc.feed(
          'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"a.jpg\\"}"}}]}}]}');
      acc.feed('data: [DONE]');

      final calls = acc.takeToolCalls();
      expect(calls.length, 1);
      expect(calls.first.name, 'tag_image');
      expect(calls.first.arguments['path'], 'a.jpg');
    });

    test('非 JSON 心跳行被忽略', () {
      final acc = SseAccumulator();
      expect(acc.feed(': keep-alive'), '');
      expect(acc.feed('data: {bad json'), '');
      expect(acc.done, isFalse);
    });
  });

  group('批量打标意图（isBatchTagIntent）', () {
    test('设计书场景三指令命中', () {
      expect(isBatchTagIntent('给所有截图打上标签'), isTrue);
      expect(isBatchTagIntent('批量整理这个文件夹'), isTrue);
      expect(isBatchTagIntent('把全部图片打标签'), isTrue);
    });

    test('单图指令与无关文本不命中', () {
      expect(isBatchTagIntent('给这张图打标签'), isFalse, reason: '单图不批量');
      expect(isBatchTagIntent('描述一下这张图'), isFalse);
      expect(isBatchTagIntent(''), isFalse);
    });
  });

  group('视觉打标 JSON 解析（parseTagJson）', () {
    test('裸 JSON', () {
      final r = parseTagJson('{"tags":["风景","日落"],"title":"黄昏"}');
      expect(r.tags, ['风景', '日落']);
      expect(r.title, '黄昏');
    });

    test('markdown 围栏包裹', () {
      final r = parseTagJson('```json\n{"tags":["猫"],"title":"一只猫"}\n```');
      expect(r.tags, ['猫']);
    });

    test('前后夹杂说明文字时取最外层花括号', () {
      final r = parseTagJson('识别结果：{"tags":["山"]} 以上。');
      expect(r.tags, ['山']);
    });

    test('空标签抛 FormatException', () {
      expect(() => parseTagJson('{"tags":[],"title":""}'),
          throwsFormatException);
      expect(() => parseTagJson('没有 JSON'), throwsFormatException);
    });
  });

  group('AiTask 进度通知（任务卡片数据源）', () {
    test('run 过程中 notifyListeners 触发', () async {
      int notified = 0;
      final task = AiTask<String>('t', [
        TaskItem('1', 'a', () async => 'x'),
        TaskItem('2', 'b', () async => 'y'),
      ]);
      task.addListener(() => notified++);
      await task.run();
      expect(notified, greaterThanOrEqualTo(3));
      expect(task.doneCount, 2);
    });

    test('retryFailed 只重跑失败项', () async {
      var failOnce = true;
      final task = AiTask<String>('t', [
        TaskItem('1', 'a', () async {
          if (failOnce) throw Exception('x');
          return 'ok';
        }),
        TaskItem('2', 'b', () async => 'ok2'),
      ]);
      await task.run();
      expect(task.failedCount, 1);
      failOnce = false;
      await task.retryFailed();
      expect(task.successCount, 2);
    });
  });
}
