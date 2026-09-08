import 'dart:typed_data';
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

    test('rotate 180/270 尺寸推演：180 不交换、270 交换', () {
      expect(sizeAfter([FilterNode(op: 'rotate', params: {'deg': 180})], 2000, 1000),
          (w: 2000, h: 1000), reason: '180° 不交换宽高');
      expect(sizeAfter([FilterNode(op: 'rotate', params: {'deg': 270})], 2000, 1000),
          (w: 1000, h: 2000));
      expect(sizeAfter([FilterNode(op: 'rotate', params: {'deg': -90})], 2000, 1000),
          (w: 1000, h: 2000));
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
        // 回归：涂鸦节点无 x/y 锚点，渲染不得抛 Null 转型异常
        FilterNode(op: 'annotate', params: {
          'kind': 'doodle',
          'points': [
            {'x': 0.1, 'y': 0.1},
            {'x': 0.3, 'y': 0.4},
            {'x': 0.6, 'y': 0.2},
          ],
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

    test('rotate 90 内容方位正确：左红右蓝 → 上红下蓝', () async {
      final src = await _twoTone(64, 32, horizontal: true);
      final out = await renderPipeline(
          src, [FilterNode(op: 'rotate', params: {'deg': 90})]);
      expect((out.width, out.height), (32, 64));
      final px = await _pixels(out);
      expect(_at(px, out.width, 8, 8), _red, reason: '上半应为红（源左半）');
      expect(_at(px, out.width, 24, 8), _red);
      expect(_at(px, out.width, 8, 56), _blue, reason: '下半应为蓝（源右半）');
      expect(_at(px, out.width, 24, 56), _blue);
    });

    test('rotate 180 内容方位正确：上红下蓝 → 上蓝下红，尺寸不变', () async {
      final src = await _twoTone(40, 30, horizontal: false);
      final out = await renderPipeline(
          src, [FilterNode(op: 'rotate', params: {'deg': 180})]);
      expect((out.width, out.height), (40, 30));
      final px = await _pixels(out);
      expect(_at(px, out.width, 20, 4), _blue, reason: '180° 后上蓝');
      expect(_at(px, out.width, 20, 26), _red, reason: '180° 后下红');
    });

    test('flip 垂直/水平镜像内容正确且不越出画布', () async {
      final vSrc = await _twoTone(40, 30, horizontal: false);
      final vOut = await renderPipeline(
          vSrc, [FilterNode(op: 'flip', params: {'axis': 'v'})]);
      expect((vOut.width, vOut.height), (40, 30));
      final vpx = await _pixels(vOut);
      expect(_at(vpx, vOut.width, 20, 4), _blue, reason: '垂直翻转后上蓝');
      expect(_at(vpx, vOut.width, 20, 26), _red, reason: '垂直翻转后下红');

      final hSrc = await _twoTone(40, 30, horizontal: true);
      final hOut = await renderPipeline(
          hSrc, [FilterNode(op: 'flip', params: {'axis': 'h'})]);
      final hpx = await _pixels(hOut);
      expect(_at(hpx, hOut.width, 4, 15), _blue, reason: '水平翻转后左蓝');
      expect(_at(hpx, hOut.width, 36, 15), _red, reason: '水平翻转后右红');
    });
    test('annotate mosaic 导出为真实像素化：块内均匀、区域位置正确', () async {
      // 旧实现只画半透明黑块——在棋盘源上半透明叠加仍呈交替条纹，
      // 「块内均匀」断言必然失败
      final src = await _checker(200, 100);
      final out = await renderPipeline(src, [
        FilterNode(op: Ops.annotate, params: {
          'kind': 'mosaic', 'x': 0.4, 'y': 0.4, 'x2': 0.8, 'y2': 0.8,
        }),
      ]);
      expect((out.width, out.height), (200, 100));
      final px = await _pixels(out);
      int at(int x, int y) => _at(px, out.width, x, y);
      // bs = clamp(min(200,100)/40 = 6)：矩形输出 (80..160, 40..80)，
      // 块自矩形起点铺（13×7 网格），取样点均落在块内部
      expect(at(100, 50), at(101, 50), reason: '块内横向均匀');
      expect(at(100, 49), at(100, 50), reason: '块内纵向均匀');
      expect(at(82, 41), at(83, 41), reason: '左上角块内均匀');
      expect(at(69, 50), isNot(at(70, 50)), reason: '矩形左外侧保持棋盘');
      expect(at(169, 50), isNot(at(170, 50)), reason: '矩形右外侧保持棋盘');
      expect(at(99, 30), isNot(at(100, 30)), reason: '矩形上外侧保持棋盘');
    });
  });
}

/// 2px 白/黑交替竖条（源像素级棋盘）。
Future<ui.Image> _checker(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000));
  for (var x = 0; x < w; x += 4) {
    c.drawRect(
        ui.Offset(x.toDouble(), 0) & ui.Size(2, h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  }
  return rec.endRecording().toImage(w, h);
}

const _red = 0xFFE60000;
const _blue = 0xFF0000E6;

/// 双色测试图：horizontal=true 左红右蓝（按 x 分），否则上红下蓝（按 y 分）。
Future<ui.Image> _twoTone(int w, int h, {required bool horizontal}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  final split = horizontal ? w / 2 : h / 2;
  c.drawRect(
      ui.Offset.zero &
          (horizontal
              ? ui.Size(split, h.toDouble())
              : ui.Size(w.toDouble(), split)),
      ui.Paint()..color = const ui.Color(_red));
  c.drawRect(
      (horizontal
              ? ui.Offset(split, 0)
              : ui.Offset(0, split)) &
          (horizontal
              ? ui.Size(w - split, h.toDouble())
              : ui.Size(w.toDouble(), h - split)),
      ui.Paint()..color = const ui.Color(_blue));
  return rec.endRecording().toImage(w, h);
}

Future<Uint8List> _pixels(ui.Image img) async {
  final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return d!.buffer.asUint8List();
}

/// 取像素并打包为 AARRGGBB（rawRgba 字节序为 R,G,B,A）。
int _at(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return (px[i + 3] << 24) | (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
}
