import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/pipeline/render.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _solidImage(int w, int h, int color) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(
      ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()
        ..color = ui.Color(color)
        ..style = ui.PaintingStyle.fill);
  return rec.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('presetExpansion 预设展开', () {
    test('全部已知预设可展开且参数在合法区间', () {
      for (final name in knownPresets) {
        final p = presetExpansion(name);
        expect(p, isNotEmpty);
        expect(p.values.every((v) => v >= -1 && v <= 1), isTrue);
      }
    });

    test('未知预设抛 ArgumentError', () {
      expect(() => presetExpansion('nope'), throwsArgumentError);
    });
  });

  group('sizeAfter 尺寸推演', () {
    test('rotate 交换宽高、crop 缩小、resize 缩放', () {
      expect(sizeAfter([FilterNode(op: 'rotate', params: {'deg': 90})], 2000, 1000),
          (w: 1000, h: 2000));
      expect(
          sizeAfter([
            FilterNode(
                op: 'crop', params: {'x': 0, 'y': 0, 'w': 0.5, 'h': 0.5}),
          ], 2000, 1000),
          (w: 1000, h: 500));
      // 相对比例坐标在推演中保持闭环：先裁剪后旋转，像素尺寸等价重排
      expect(
          sizeAfter([
            FilterNode(op: 'crop', params: {'x': 0, 'y': 0, 'w': 0.5, 'h': 0.5}),
            FilterNode(op: 'rotate', params: {'deg': 90}),
            FilterNode(op: 'resize', params: {'width': 1600}),
          ], 2000, 1000),
          (w: 1600, h: 3200));
    });

    test('resize 单边参数保持纵横比，最小尺寸 1', () {
      expect(sizeAfter([FilterNode(op: 'resize', params: {'width': 1600})], 800, 400),
          (w: 1600, h: 800));
      expect(sizeAfter([FilterNode(op: 'resize', params: {'height': 100})], 800, 400),
          (w: 200, h: 100));
      expect(sizeAfter(const [], 0, 0), (w: 1, h: 1));
    });
  });

  group('renderPipeline 像素求值', () {
    test('空管线返回原图尺寸', () async {
      final src = await _solidImage(64, 32, 0xFF00FF00);
      final out = await renderPipeline(src, []);
      expect(out.width, 64);
      expect(out.height, 32);
    });

    test('rotate 90 交换宽高；flip 不改变尺寸', () async {
      final src = await _solidImage(64, 32, 0xFF00FF00);
      final rot = await renderPipeline(
          src, [FilterNode(op: 'rotate', params: {'deg': 90})]);
      expect((rot.width, rot.height), (32, 64));

      final flip = await renderPipeline(
          src, [FilterNode(op: 'flip', params: {'axis': 'h'})]);
      expect((flip.width, flip.height), (64, 32));
    });

    test('crop 按相对比例输出对应像素尺寸', () async {
      final src = await _solidImage(100, 100, 0xFF00FF00);
      final out = await renderPipeline(src, [
        FilterNode(op: 'crop', params: {'x': 0.1, 'y': 0.1, 'w': 0.5, 'h': 0.5}),
      ]);
      expect((out.width, out.height), (50, 50));
    });

    test('adjust/preset/annotate 求值不改变尺寸且不抛异常', () async {
      final src = await _solidImage(80, 60, 0xFF204080);
      final out = await renderPipeline(src, [
        FilterNode(op: 'adjust', params: {
          'brightness': 0.1,
          'contrast': 0.1,
          'saturation': -0.2,
          'temperature': 0.2,
          'vignette': 0.3,
        }),
        FilterNode(op: 'preset', params: {'name': 'bw'}),
        FilterNode(op: 'annotate', params: {
          'kind': 'text',
          'text': 'hello',
          'x': 0.1,
          'y': 0.1,
          'size': 12,
        }),
        FilterNode(op: 'annotate', params: {
          'kind': 'rect',
          'x': 0.1,
          'y': 0.1,
          'x2': 0.5,
          'y2': 0.5,
        }),
        FilterNode(op: 'annotate', params: {
          'kind': 'mosaic',
          'x': 0.5,
          'y': 0.5,
          'x2': 0.9,
          'y2': 0.9,
        }),
      ]);
      expect((out.width, out.height), (80, 60));
    });

    test('resize 双线性输出目标尺寸', () async {
      final src = await _solidImage(800, 400, 0xFF204080);
      final out = await renderPipeline(
          src, [FilterNode(op: 'resize', params: {'width': 200})]);
      expect((out.width, out.height), (200, 100));
    });

    test('非破坏性：求值后原图仍然有效（尺寸不变）', () async {
      final src = await _solidImage(64, 64, 0xFF204080);
      await renderPipeline(src, [
        FilterNode(op: 'rotate', params: {'deg': 90}),
        FilterNode(op: 'adjust', params: {'brightness': 0.5}),
      ]);
      expect(src.width, 64, reason: '原图不被修改');
    });
  });
}
