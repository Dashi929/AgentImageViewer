/// 编辑器预览 painter：屏幕画布直绘（源位图 drawImage + 矢量叠加）。
///
/// 不生成中间位图（绕开离屏合成在各后端的显示问题），
/// 滑杆/标注实时无位图分配；导出仍走离屏管线精确合成。
/// 几何变换与导出管线（render.dart）逐节点同构：以「源像素 → 输出画布」
/// 内容映射矩阵（[nodeGeometryMatrix]）变换后 1:1 绘制源图。标注矢量绘制在
/// 输出画布坐标系（fit 缩放 + off 平移已应用），马赛克以图像滤镜真实
/// 像素化，与导出观感一致。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'node.dart';
import 'render.dart';

/// 一个几何节点的作用前帧 (ow, oh) 与作用后帧 (nw, nh)。
class _GeoStep {
  _GeoStep(this.node, this.ow, this.oh, this.nw, this.nh);

  final FilterNode node;
  final double ow, oh, nw, nh;
}

class EditorPreviewPainter extends CustomPainter {
  EditorPreviewPainter({
    required this.source,
    required this.nodes,
    required this.generation,
  });

  final ui.Image source;
  final List<FilterNode> nodes;
  final int generation; // 节点/历史代数：变化即重绘

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
        ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xFF101216));

    final out = sizeAfter(nodes, source.width, source.height);
    final fit = math.min(size.width / out.w, size.height / out.h);
    final drawW = out.w * fit, drawH = out.h * fit;
    final off = Offset((size.width - drawW) / 2, (size.height - drawH) / 2);

    // 前向记录每个几何节点的作用前/后帧尺寸（构建内容映射矩阵时需要）。
    final geo =
        nodeGeometryMatrix(nodes, source.width.toDouble(), source.height.toDouble());

    canvas.save();
    canvas.translate(off.dx, off.dy);
    canvas.scale(fit);

    // 源图经「源像素 → 输出画布」映射矩阵 1:1 绘制（与导出逐节点同构）
    canvas.save();
    canvas.transform(geo.storage);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    canvas.drawImage(source, ui.Offset.zero, paint);
    canvas.restore(); // 撤几何变换，回到输出画布坐标系

    // 标注矢量叠加（相对比例 × 输出画布）。绘制上下文必须保留 fit/off
    // （曾整层 restore 回控件坐标系，导致标注按输出像素尺度直绘、
    // 落点整体向右下偏移）。新标注总是入栈尾、以最终帧为参照；
    // 「先标注后几何」的旧栈序与导出存在既有差异。
    final outSize = ui.Size(out.w.toDouble(), out.h.toDouble());
    for (final n in nodes) {
      if (n.op != Ops.annotate) continue;
      if (n.params['kind'] == AnnotateKinds.mosaic) {
        _paintMosaic(canvas, source, geo, outSize, n.params);
      } else {
        paintAnnotateVectors(canvas, outSize, n.params);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EditorPreviewPainter old) =>
      old.generation != generation;
}

/// 90° 倍数旋转的帧尺寸：90/270 交换，180/0 不交换。
(double, double) _rotatedSize(double w, double h, int deg) {
  final d = ((deg % 360) + 360) % 360;
  return (d == 90 || d == 270) ? (h, w) : (w, h);
}

/// 节点序列的「源像素 → 输出画布」内容映射矩阵。预览 painter 与
/// 标注拖拽实时预览（editor_page）共用。
Matrix4 nodeGeometryMatrix(List<FilterNode> nodes, double srcW, double srcH) {
  // 前向记录每个几何节点的作用前/后帧尺寸
  final steps = <_GeoStep>[];
  var cw = srcW, ch = srcH;
  for (final n in nodes) {
    final (double, double)? next = switch (n.op) {
      Ops.rotate => _rotatedSize(cw, ch, (n.params['deg'] as num).toInt()),
      Ops.freeRotate => _freeRotatedSize(cw, ch, (n.params['deg'] as num).toDouble()),
      Ops.flip => (cw, ch),
      Ops.crop => (
          cw * (n.params['w'] as num).toDouble(),
          ch * (n.params['h'] as num).toDouble(),
        ),
      Ops.resize => _resizedSize(n, cw, ch),
      _ => null, // 非几何节点不产生变换
    };
    if (next == null) continue;
    steps.add(_GeoStep(n, cw, ch, next.$1, next.$2));
    (cw, ch) = next;
  }

  final m = Matrix4.identity();
  for (var i = steps.length - 1; i >= 0; i--) {
    final s = steps[i];
    switch (s.node.op) {
      case Ops.rotate:
        final d = ((s.node.params['deg'] as num).toInt() % 360 + 360) % 360;
        switch (d) {
          case 90:
            m.translateByDouble(s.oh, 0, 0.0, 1.0);
            m.rotateZ(math.pi / 2);
          case 180:
            m.translateByDouble(s.ow, s.oh, 0.0, 1.0);
            m.rotateZ(math.pi);
          case 270:
            m.translateByDouble(0.0, s.ow, 0.0, 1.0);
            m.rotateZ(3 * math.pi / 2);
        }
      case Ops.freeRotate:
        final rad = (s.node.params['deg'] as num).toDouble() * math.pi / 180;
        m.translateByDouble(s.nw / 2, s.nh / 2, 0.0, 1.0);
        m.rotateZ(rad);
        m.translateByDouble(-s.ow / 2, -s.oh / 2, 0.0, 1.0);
      case Ops.flip:
        if ((s.node.params['axis'] as String) == 'h') {
          m.translateByDouble(s.ow, 0, 0.0, 1.0);
          m.scaleByDouble(-1.0, 1.0, 1.0, 1.0);
        } else {
          m.translateByDouble(0.0, s.oh, 0.0, 1.0);
          m.scaleByDouble(1.0, -1.0, 1.0, 1.0);
        }
      case Ops.crop:
        m.translateByDouble(
            -(s.node.params['x'] as num).toDouble() * s.ow,
            -(s.node.params['y'] as num).toDouble() * s.oh,
            0.0,
            1.0);
      case Ops.resize:
        m.scaleByDouble(s.nw / s.ow, s.nh / s.oh, 1.0, 1.0);
    }
  }
  return m;
}

/// 矩阵列向量的 2D 长度（axis: 0=x 基, 1=y 基）＝该轴的总缩放。
/// 旋转不改列长，含自由旋转的链同样适用。
double _columnScale(Matrix4 m, int axis) {
  final s = m.storage;
  final x = s[axis * 4], y = s[axis * 4 + 1];
  return math.sqrt(x * x + y * y);
}

/// 马赛克预览：与导出一致的块状像素化（块边长以输出画布像素计）。
void _paintMosaic(ui.Canvas canvas, ui.Image source, Matrix4 geo,
    ui.Size out, Map<String, Object?> params) {
  final x = ((params['x'] as num?) ?? 0).toDouble() * out.width;
  final y = ((params['y'] as num?) ?? 0).toDouble() * out.height;
  final x2 = ((params['x2'] as num?) ?? x).toDouble() * out.width;
  final y2 = ((params['y2'] as num?) ?? y).toDouble() * out.height;
  final rect = ui.Rect.fromPoints(ui.Offset(x, y), ui.Offset(x2, y2))
      .intersect(ui.Offset.zero & out);
  if (rect.width < 1 || rect.height < 1) return;
  paintMosaicRegion(canvas, source: source, geo: geo, rect: rect, out: out);
}

/// 在「输出画布坐标系」的画布上绘制马赛克像素化区域（提交预览与
/// 拖拽实时预览共用）。实现：clip 到矩形后把源图经几何映射重画一遍，
/// 绘制时叠加「缩小(双线性)→放大(无插值)」复合图像滤镜——纯画布操作，
/// 无离屏位图，块内容取样自真实像素，与导出观感一致。
void paintMosaicRegion(ui.Canvas canvas,
    {required ui.Image source,
    required Matrix4 geo,
    required ui.Rect rect,
    required ui.Size out}) {
  final bs = mosaicBlockSize(out.width, out.height).toDouble();
  final bsx = math.max(1.0, bs / _columnScale(geo, 0)); // 源像素块边长
  final bsy = math.max(1.0, bs / _columnScale(geo, 1));
  final pixelate = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..imageFilter = ui.ImageFilter.compose(
      outer: _scaleImageFilter(bsx, bsy, ui.FilterQuality.none),
      inner: _scaleImageFilter(1 / bsx, 1 / bsy, ui.FilterQuality.medium),
    );

  canvas.save();
  canvas.clipRect(rect);
  canvas.save();
  canvas.transform(geo.storage);
  canvas.drawImage(source, ui.Offset.zero, pixelate);
  canvas.restore();
  canvas.restore();
}

/// 纯缩放矩阵图像滤镜（本 SDK 无 ImageFilter.scale，用 matrix 等价）。
ui.ImageFilter _scaleImageFilter(double sx, double sy, ui.FilterQuality q) =>
    ui.ImageFilter.matrix((Matrix4.identity()..scaleByDouble(sx, sy, 1.0, 1.0)).storage,
        filterQuality: q);

/// 任意角度旋转的包围盒帧尺寸。
(double, double) _freeRotatedSize(double w, double h, double deg) {
  final rad = deg * math.pi / 180;
  final cos = math.cos(rad).abs(), sin = math.sin(rad).abs();
  return (w * cos + h * sin, w * sin + h * cos);
}

/// resize 节点的目标帧尺寸。
(double, double) _resizedSize(FilterNode n, double w, double h) {
  final t = sizeAfter([n], w.round(), h.round());
  return (t.w.toDouble(), t.h.toDouble());
}
