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

  test('预览 crop 保留区域与导出一致：右半（蓝）充满输出，不放大错位', () async {
    // 四竖条 R,G,B,Y 各 16px；裁掉左半 → 输出应恰好是 B,Y 两条各占一半
    final src = await _bands(64, 32);
    final px = await _paintPreview(src, [
      FilterNode(op: Ops.crop, params: {'x': 0.5, 'y': 0, 'w': 0.5, 'h': 1}),
    ], w: 32, h: 32);
    expect(_at(px, 32, 4, 16), _blue, reason: '输出左半应为大面积蓝（源 32~48px 列）');
    expect(_at(px, 32, 28, 16), _yellow, reason: '输出右半应为黄（源 48~64px 列）');
  });

  test('标注预览绘制在输出画布坐标系：fit≠1 时不向右下偏移', () async {
    // 画布恰为输出一半（fit=0.5, off=0）：rect 描边 16 输出px → 8 控件px，
    // 左边带应落在控件 x∈[16,24]；曾整层 restore 回控件坐标系，
    // 标注按输出像素尺度直绘（左边带落到 x∈[32,48]）
    final src = await _solid(200, 100, _blue);
    final px = await _paintPreview(src, [
      FilterNode(op: Ops.annotate, params: {
        'kind': 'rect', 'x': 0.2, 'y': 0.2, 'x2': 0.8, 'y2': 0.8, 'size': 200,
        'color': 0xFFE60000,
      }),
    ], w: 100, h: 50);
    expect(_at(px, 100, 20, 25), _red, reason: 'rect 左描边应在控件 x=20 处');
    expect(_at(px, 100, 50, 25), _blue, reason: '矩形内部镂空应为底图蓝色');
    expect(_at(px, 100, 10, 25), _blue, reason: '矩形外侧应为底图蓝色');
  });

  test('马赛克预览为真实像素化：块内均匀、区域位置正确', () async {
    // 2px 白/黑竖条源 + fit=0.5：马赛克块（8 输出px = 4 控件px，网格锚在
    // 区域起点控件 x=30）内相邻控件像素必须相等；区域（控件
    // [30..70]×[5..45]）外保持原图棋盘。旧半透明黑块近似与偏移直绘在
    // 「块内相等」断言上必然失败。
    final src = await _checker(200, 100);
    final px = await _paintPreview(src, [
      FilterNode(op: Ops.annotate, params: {
        'kind': 'mosaic', 'x': 0.3, 'y': 0.1, 'x2': 0.7, 'y2': 0.9,
      }),
    ], w: 100, h: 50);
    // 区域内：同一马赛克块内相邻像素相等
    expect(_at(px, 100, 34, 25), _at(px, 100, 35, 25));
    expect(_at(px, 100, 40, 25), _at(px, 100, 41, 25));
    expect(_at(px, 100, 47, 25), _at(px, 100, 48, 25));
    expect(_at(px, 100, 31, 25), _at(px, 100, 32, 25));
    expect(_at(px, 100, 34, 7), _at(px, 100, 35, 7), reason: '上边缘内侧同为块内');
    // 区域外：原图 2px 棋盘经 0.5 缩放后相邻控件像素必不同
    expect(_at(px, 100, 26, 25), isNot(_at(px, 100, 27, 25)), reason: '左缘外应保持棋盘');
    expect(_at(px, 100, 72, 25), isNot(_at(px, 100, 73, 25)), reason: '右缘外应保持棋盘');
    expect(_at(px, 100, 34, 2), isNot(_at(px, 100, 35, 2)), reason: '上缘外应保持棋盘');
  });
}

const _yellow = 0xFFE6E600;

Future<ui.Image> _solid(int w, int h, int color) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  c.drawRect(ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = ui.Color(color));
  return rec.endRecording().toImage(w, h);
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

/// 四竖条测试图：每条 w/4 宽，依次 红绿蓝黄。
Future<ui.Image> _bands(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  final colors = [const ui.Color(_red), const ui.Color(0xFF00E600), const ui.Color(_blue), const ui.Color(_yellow)];
  final bw = w / 4;
  for (var i = 0; i < 4; i++) {
    c.drawRect(
        ui.Offset(bw * i, 0) & ui.Size(bw, h.toDouble()),
        ui.Paint()..color = colors[i]);
  }
  return rec.endRecording().toImage(w, h);
}
