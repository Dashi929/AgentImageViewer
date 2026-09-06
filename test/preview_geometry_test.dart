/// 预览 painter 几何回归：旋转/翻转后内容方位必须与导出管线一致
/// （回归背景：绕旧中心旋转 + 目标矩形拉伸导致旋转后图片错位变形）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/core/pipeline/preview_painter.dart';
import 'package:flutter_test/flutter_test.dart';

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
      (horizontal ? ui.Offset(split, 0) : ui.Offset(0, split)) &
          (horizontal
              ? ui.Size(w - split, h.toDouble())
              : ui.Size(w.toDouble(), h - split)),
      ui.Paint()..color = const ui.Color(_blue));
  return rec.endRecording().toImage(w, h);
}

/// 以恰好等于输出尺寸的画布绘制预览（fit=1、off=0），返回像素。
Future<Uint8List> _paintPreview(ui.Image src, List<FilterNode> nodes,
    {required int w, required int h}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  EditorPreviewPainter(source: src, nodes: nodes, generation: 1)
      .paint(canvas, ui.Size(w.toDouble(), h.toDouble()));
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return d!.buffer.asUint8List();
}

int _at(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return (px[i + 3] << 24) | (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('预览 rotate 90：左红右蓝 → 上红下蓝，充满输出画布不偏移', () async {
    final src = await _twoTone(64, 32, horizontal: true);
    final px = await _paintPreview(
        src, [FilterNode(op: Ops.rotate, params: {'deg': 90})],
        w: 32, h: 64);
    expect(_at(px, 32, 8, 8), _red, reason: '左上角应为红（旋转后充满画布，无偏移空边）');
    expect(_at(px, 32, 24, 8), _red);
    expect(_at(px, 32, 8, 56), _blue, reason: '左下角应为蓝');
    expect(_at(px, 32, 24, 56), _blue);
  });

  test('预览 rotate 180：上红下蓝 → 上蓝下红，尺寸不变且居中不偏移', () async {
    final src = await _twoTone(40, 30, horizontal: false);
    final px = await _paintPreview(
        src, [FilterNode(op: Ops.rotate, params: {'deg': 180})],
        w: 40, h: 30);
    expect(_at(px, 40, 20, 4), _blue);
    expect(_at(px, 40, 20, 26), _red);
  });

  test('预览 flip v/h 内容方位正确', () async {
    final vSrc = await _twoTone(40, 30, horizontal: false);
    final vpx = await _paintPreview(
        vSrc, [FilterNode(op: Ops.flip, params: {'axis': 'v'})],
        w: 40, h: 30);
    expect(_at(vpx, 40, 20, 4), _blue);
    expect(_at(vpx, 40, 20, 26), _red);

    final hSrc = await _twoTone(40, 30, horizontal: true);
    final hpx = await _paintPreview(
        hSrc, [FilterNode(op: Ops.flip, params: {'axis': 'h'})],
        w: 40, h: 30);
    expect(_at(hpx, 40, 4, 15), _blue);
    expect(_at(hpx, 40, 36, 15), _red);
  });

  test('预览 freeRotate 90 等价 rotate 90（包围盒重定位正确）', () async {
    final src = await _twoTone(64, 32, horizontal: true);
    final px = await _paintPreview(
        src, [FilterNode(op: Ops.freeRotate, params: {'deg': 90})],
        w: 32, h: 64);
    expect(_at(px, 32, 8, 8), _red, reason: 'freeRotate 90 应与 rotate 90 同方位');
    expect(_at(px, 32, 8, 56), _blue);
  });

  test('预览先裁剪后旋转：组合变换与导出一致', () async {
    final src = await _twoTone(64, 32, horizontal: true);
    final px = await _paintPreview(src, [
      FilterNode(op: Ops.crop, params: {'x': 0, 'y': 0, 'w': 0.5, 'h': 1}),
      FilterNode(op: Ops.rotate, params: {'deg': 90}),
    ], w: 32, h: 32);
    // 裁掉右半（只剩红）再旋转 90°：整幅应为红
    expect(_at(px, 32, 8, 8), _red);
    expect(_at(px, 32, 24, 24), _red);
    expect(_at(px, 32, 4, 28), _red);
  });
}
