import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/pipeline/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FilterNode 序列化（与 3.4 节操作栈格式互认）', () {
    test('设计书示例栈可完整 round-trip', () {
      const sample = [
        {'op': 'rotate', 'params': {'deg': 90}},
        {'op': 'crop', 'params': {'x': 0.06, 'y': 0.04, 'w': 0.8, 'h': 0.6}},
        {
          'op': 'adjust',
          'params': {'brightness': 0.06, 'contrast': 0.12, 'saturation': -0.05},
        },
        {
          'op': 'annotate',
          'params': {'kind': 'text', 'text': 'sample', 'x': 0.62, 'y': 0.08, 'size': 48},
        },
        {'op': 'resize', 'params': {'width': 1600}},
      ];

      final p = ImagePipeline.fromJson(sample);
      expect(p.nodes.map((n) => n.op).toList(),
          ['rotate', 'crop', 'adjust', 'annotate', 'resize']);

      final json = p.toJson();
      final restored = ImagePipeline.fromJson(json);
      expect(restored.toJson(), json);
      // 坐标保持相对比例，不被换算
      expect((json[1]['params'] as Map)['x'], 0.06);
    });

    test('未知 op 与非法参数被拒绝', () {
      expect(() => FilterNode.fromJson({'op': 'nope'}),
          throwsA(isA<FormatException>()));
      expect(
          () => FilterNode.fromJson(
              {'op': 'crop', 'params': {'x': 20, 'y': 0, 'w': 0.5, 'h': 0.5}}),
          throwsArgumentError); // 像素坐标不允许，必须 0~1
      expect(
          () => FilterNode.fromJson(
              {'op': 'rotate', 'params': {'deg': 45}}),
          throwsArgumentError);
    });

    test('节点参数不可变', () {
      final n = FilterNode(op: Ops.adjust, params: {'brightness': 0.1});
      expect(() => n.params['brightness'] = 0.9, throwsUnsupportedError);
    });
  });

  group('历史栈', () {
    test('add/undo/redo 与重做栈失效语义', () {
      final p = ImagePipeline();
      p.add(FilterNode(op: Ops.rotate, params: {'deg': 90}));
      p.add(FilterNode(op: Ops.flip, params: {'axis': 'h'}));
      expect(p.nodes.length, 2);

      expect(p.undo(), isTrue);
      expect(p.nodes.length, 1);
      expect(p.redo(), isTrue);
      expect(p.nodes.length, 2);

      p.undo();
      p.add(FilterNode(op: Ops.resize, params: {'width': 800}));
      expect(p.canRedo, isFalse, reason: '新操作后重做栈必须清空');
      expect(p.nodes.map((n) => n.op), ['rotate', 'resize']);
    });

    test('reset 回到原图后仍可撤销', () {
      final p = ImagePipeline.fromJson([
        {'op': 'adjust', 'params': {'brightness': 0.2}},
      ]);
      p.reset(null);
      expect(p.isEmpty, isTrue);
      expect(p.undo(), isTrue);
      expect(p.nodes.length, 1);
    });

    test('insert 支持在序列中间插入节点', () {
      final p = ImagePipeline.fromJson([
        {'op': 'rotate', 'params': {'deg': 90}},
        {'op': 'resize', 'params': {'width': 800}},
      ]);
      p.insert(1, FilterNode(op: Ops.preset, params: {'name': 'bw'}));
      expect(p.nodes.map((n) => n.op).toList(), ['rotate', 'preset', 'resize']);
      expect(() => p.insert(9, FilterNode(op: Ops.flip, params: {'axis': 'v'})),
          throwsRangeError);
    });
  });
}
