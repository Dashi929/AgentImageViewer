// 回归：浏览视图顶栏与元数据显示原图固有尺寸（解码只缩不放大）。
// 曾因 instantiateImageCodec(targetWidth) 强制放大小图，400×300 显示成 2024×1518，
// 「100% 实际大小」实为放大图（2026-09-09 用户反馈）。
// 运行: flutter test integration_test/viewer_true_dims_test.dart -d windows
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: avoid_print
void log(String m) => print('[true-dims] $m');

Future<Uint8List> _renderPng(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()));
  canvas.drawRect(
      ui.Offset.zero & ui.Size(w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3366CC));
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('顶栏显示原图尺寸而非解码放大尺寸', (tester) async {
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) => errors.add(d);

    final tmp = await Directory.systemTemp.createTemp('aiv_dims_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}pics';
    await Directory(dir).create();
    final img1 = '$dir${Platform.pathSeparator}a_400x300.png';
    final img2 = '$dir${Platform.pathSeparator}b_500x250.png';
    await File(img1).writeAsBytes(await _renderPng(400, 300));
    await File(img2).writeAsBytes(await _renderPng(500, 250));

    await app.appMain([img1]);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('400×300'), findsWidgets,
        reason: '顶栏应显示原图 400×300（而非解码目标宽如 2024×1518）');
    log('400x300 ok');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('500×250'), findsWidgets,
        reason: '切到下一张后尺寸应跟随其原图');
    log('500x250 ok');

    if (errors.isNotEmpty) {
      for (final e in errors.take(3)) {
        log('flutter error: ${e.exception}');
      }
      fail('捕获到 ${errors.length} 个 Flutter 错误');
    }
  });
}
