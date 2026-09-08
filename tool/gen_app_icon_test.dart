// 应用图标生成器（AIV_ICON=1 flutter test tool/gen_app_icon_test.dart 触发）：
// 矢量绘制 → 多尺寸 PNG（Windows ICO + Android 各密度启动图标）。
// 设计：深色圆角底 + 蓝紫渐变相框（山与太阳）+ AI 四芒星。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 品牌色与主题一致（theme.dart accent/aiAccent）。
const _bgTop = ui.Color(0xFF232A3A);
const _bgBottom = ui.Color(0xFF12151D);
const _frameTop = ui.Color(0xFF4C9BE8);
const _frameBottom = ui.Color(0xFF8B7CF6);

Future<Uint8List> _renderPng(int size) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Offset.zero & ui.Size(256, 256));
  final scale = size / 256.0;
  canvas.scale(scale);
  _draw(canvas, 256);
  final img = await rec.endRecording().toImage(size, size);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void _draw(ui.Canvas canvas, double size) {
  final s = size / 256.0;
  final rRect = ui.Rect.fromLTWH(0, 0, size, size);
  final radius = ui.Radius.circular(56 * s);

  // 深色圆角底
  canvas.drawRRect(
      ui.RRect.fromRectAndCorners(rRect,
          topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius),
      ui.Paint()
        ..shader = ui.Gradient.linear(
            ui.Offset(0, 0), ui.Offset(0, size), [_bgTop, _bgBottom]));

  // 细边框（提亮轮廓）
  canvas.drawRRect(
      ui.RRect.fromRectAndCorners(rRect.deflate(3 * s),
          topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius),
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..color = const ui.Color(0x33FFFFFF));

  // 相框（蓝→紫渐变）
  const inset = 44.0;
  final frame = ui.Rect.fromLTWH(
      inset * s, inset * s, size - 2 * inset * s, size - 2 * inset * s);
  final frameR = ui.RRect.fromRectAndCorners(frame,
      topLeft: ui.Radius.circular(28 * s),
      topRight: ui.Radius.circular(28 * s),
      bottomLeft: ui.Radius.circular(28 * s),
      bottomRight: ui.Radius.circular(28 * s));
  canvas.drawRRect(
      frameR,
      ui.Paint()
        ..shader = ui.Gradient.linear(frame.topLeft, frame.bottomRight,
            [_frameTop, _frameBottom]));

  canvas.save();
  canvas.clipRRect(frameR);

  // 太阳
  canvas.drawCircle(
      ui.Offset(frame.left + frame.width * 0.28, frame.top + frame.height * 0.26),
      20 * s,
      ui.Paint()..color = const ui.Color(0xFFFFE9B8));

  // 双层山（白色剪影）
  final mountain = ui.Path()
    ..moveTo(ui.Offset(frame.left, frame.bottom).dx,
        ui.Offset(frame.left, frame.bottom).dy)
    ..lineTo(frame.left + frame.width * 0.38, frame.top + frame.height * 0.38)
    ..lineTo(frame.left + frame.width * 0.62, frame.bottom)
    ..close();
  canvas.drawPath(mountain, ui.Paint()..color = const ui.Color(0xF2FFFFFF));

  final mountain2 = ui.Path()
    ..moveTo(frame.left + frame.width * 0.34, frame.bottom)
    ..lineTo(frame.left + frame.width * 0.68, frame.top + frame.height * 0.52)
    ..lineTo(frame.right, frame.bottom)
    ..close();
  canvas.drawPath(
      mountain2, ui.Paint()..color = const ui.Color(0xCCFFFFFF));

  canvas.restore();

  // AI 四芒星（右上角）
  _drawSparkle(canvas,
      ui.Offset(size - 46 * s, 46 * s), 30 * s, const ui.Color(0xFFFFFFFF));
}

void _drawSparkle(ui.Canvas canvas, ui.Offset c, double r, ui.Color color) {
  final q = r * 0.22; // 凹腰比例
  final path = ui.Path()
    ..moveTo(c.dx, c.dy - r)
    ..cubicTo(c.dx + q, c.dy - q, c.dx + q, c.dy - q, c.dx + r, c.dy)
    ..cubicTo(c.dx + q, c.dy + q, c.dx + q, c.dy + q, c.dx, c.dy + r)
    ..cubicTo(c.dx - q, c.dy + q, c.dx - q, c.dy + q, c.dx - r, c.dy)
    ..cubicTo(c.dx - q, c.dy - q, c.dx - q, c.dy - q, c.dx, c.dy - r)
    ..close();
  canvas.drawPath(path, ui.Paint()..color = color);
}

/// 极简 ICO 装配：PNG 直嵌条目（Vista+ 支持）。
Uint8List _assembleIco(List<int> sizes, Map<int, Uint8List> pngs) {
  final head = BytesBuilder();
  head.add([0, 0, 1, 0, sizes.length, 0]);
  var offset = 6 + 16 * sizes.length;
  final dir = BytesBuilder();
  final blobs = BytesBuilder();
  for (final size in sizes) {
    final png = pngs[size]!;
    dir.add([size >= 256 ? 0 : size, size >= 256 ? 0 : size, 0, 0, 1, 0, 32, 0]);
    final bytes = png.length;
    dir.add([bytes & 255, (bytes >> 8) & 255, (bytes >> 16) & 255, (bytes >> 24) & 255]);
    dir.add([offset & 255, (offset >> 8) & 255, (offset >> 16) & 255, (offset >> 24) & 255]);
    blobs.add(png);
    offset += bytes;
  }
  final out = BytesBuilder();
  out.add(head.toBytes());
  out.add(dir.toBytes());
  out.add(blobs.toBytes());
  return out.toBytes();
}

void main() {
  test('生成应用图标（AIV_ICON=1 触发）', () async {
    if (Platform.environment['AIV_ICON'] != '1') {
      return; // 常规测试跳过（不产文件）
    }
    final sizes = [16, 32, 48, 64, 72, 96, 128, 144, 192, 256];
    final pngs = <int, Uint8List>{};
    for (final s in sizes) {
      pngs[s] = await _renderPng(s);
    }

    final outDir = Directory('build${Platform.pathSeparator}app_icon')
      ..createSync(recursive: true);
    for (final e in pngs.entries) {
      File('${outDir.path}${Platform.pathSeparator}icon_${e.key}.png')
          .writeAsBytesSync(e.value);
    }

    // Windows ICO：16/32/48/256 足够（Explorer 各视图）
    File('windows${Platform.pathSeparator}runner${Platform.pathSeparator}resources'
            '${Platform.pathSeparator}app_icon.ico')
        .writeAsBytesSync(_assembleIco([16, 32, 48, 256], pngs));

    // Android 各密度启动图标
    final densities = <String, int>{
      'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192,
    };
    for (final e in densities.entries) {
      File('android${Platform.pathSeparator}app${Platform.pathSeparator}src'
              '${Platform.pathSeparator}main${Platform.pathSeparator}res'
              '${Platform.pathSeparator}mipmap-${e.key}'
              '${Platform.pathSeparator}ic_launcher.png')
          .writeAsBytesSync(pngs[e.value]!);
    }
    // ignore: avoid_print
    print('[icon] 生成完成：ico + ${sizes.join("/")} png + android 密度图标');
  });
}
