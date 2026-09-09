import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/pipeline/render.dart';
import 'package:agent_image_viewer/core/viewer/slideshow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('幻灯片下一张索引（设计书 2.2：间隔可选/随机/循环）', () {
    test('顺序播放前进并在末尾循环', () {
      expect(
          nextSlideIndex(current: 0, count: 3, random: false, loop: true), 1);
      expect(
          nextSlideIndex(current: 2, count: 3, random: false, loop: true), 0);
    });

    test('非循环时末尾返回 null（播放结束）', () {
      expect(
          nextSlideIndex(current: 2, count: 3, random: false, loop: false),
          isNull);
      expect(
          nextSlideIndex(current: 1, count: 3, random: false, loop: false), 2);
    });

    test('随机不重复当前张', () {
      final rng = math.Random(42);
      for (var i = 0; i < 50; i++) {
        final next = nextSlideIndex(
            current: 1, count: 4, random: true, loop: true, rng: rng);
        expect(next, isNot(1));
        expect(next, inInclusiveRange(0, 3));
      }
    });

    test('边界：空图库与单张', () {
      expect(nextSlideIndex(current: 0, count: 0, random: false, loop: true),
          isNull);
      // 单张循环播放恒为 0；非循环停止
      expect(nextSlideIndex(current: 0, count: 1, random: false, loop: true), 0);
      expect(
          nextSlideIndex(current: 0, count: 1, random: false, loop: false),
          isNull);
    });
  });

  group('自由旋转（设计书 表 2-3）', () {
    test('节点校验：deg 限 -180~180', () {
      FilterNode.fromJson({
        'op': 'free_rotate',
        'params': {'deg': 15.5},
      });
      expect(
        () => FilterNode.fromJson(
            {'op': 'free_rotate', 'params': {'deg': 181}}),
        throwsArgumentError,
      );
      expect(
        () => FilterNode.fromJson({'op': 'free_rotate', 'params': {}}),
        throwsArgumentError,
      );
    });

    test('序列化 round-trip', () {
      final node = FilterNode.fromJson(
          {'op': 'free_rotate', 'params': {'deg': -12.5}});
      final restored = FilterNode.fromJson(node.toJson());
      expect(restored.params['deg'], -12.5);
    });

    test('sizeAfter 按旋转包围盒扩展', () {
      // 30° 旋转 1000x1000 → 约 1366x1366
      final out = sizeAfter([
        FilterNode(op: 'free_rotate', params: {'deg': 30}),
      ], 1000, 1000);
      expect(out.w, closeTo(1366, 2));
      expect(out.h, closeTo(1366, 2));

      // 90° 等价于宽高互换
      final q = sizeAfter([
        FilterNode(op: 'free_rotate', params: {'deg': 90}),
      ], 2000, 1000);
      expect(q.w, closeTo(1000, 2));
      expect(q.h, closeTo(2000, 2));

      // 0° 不变
      final z = sizeAfter([
        FilterNode(op: 'free_rotate', params: {'deg': 0}),
      ], 800, 600);
      expect((z.w, z.h), (800, 600));
    });

    testWidgets('渲染：包围盒尺寸正确且不抛异常', (tester) async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec, ui.Offset.zero & const ui.Size(400, 300));
      c.drawRect(ui.Offset.zero & const ui.Size(400, 300),
          ui.Paint()..color = const ui.Color(0xFF3366AA));
      final src = await rec.endRecording().toImage(400, 300);

      final out = await renderPipeline(src, [
        FilterNode(op: 'free_rotate', params: {'deg': 30}),
      ]);
      // 400x300 旋转 30°：w = 400*cos30+300*sin30 ≈ 496, h = 400*sin30+300*cos30 ≈ 460
      expect(out.width, closeTo(496, 2));
      expect(out.height, closeTo(460, 2));
    });
  });
}
