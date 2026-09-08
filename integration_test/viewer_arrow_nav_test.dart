/// 回归：浏览视图 ←/→ 普通翻页（非边界）在真实 Windows 引擎下可用。
/// 运行: flutter test integration_test/viewer_arrow_nav_test.dart -d windows
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 1×1 红色 PNG（合法文件头，解码器可解）。
final Uint8List kPng1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

// ignore: avoid_print
void log(String m) => print('[arrow-nav] $m');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('←/→ 在文件夹内前后翻页', (tester) async {
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) => errors.add(d);

    final tmp = await Directory.systemTemp.createTemp('aiv_arrow_nav');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}pics';
    await Directory(dir).create();
    for (final n in ['img1.png', 'img2.png', 'img3.png']) {
      await File('$dir${Platform.pathSeparator}$n').writeAsBytes(kPng1x1);
    }

    await app.appMain(['$dir${Platform.pathSeparator}img1.png']);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    // 初始：img1
    expect(find.textContaining('img1.png'), findsWidgets,
        reason: '双击 img1 应直接进入所在文件夹浏览');
    log('opened img1 ok');

    // → ：翻到 img2
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('img2.png'), findsWidgets,
        reason: '→ 应翻到下一张 img2');
    log('arrowRight -> img2 ok');

    // → ：翻到 img3
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('img3.png'), findsWidgets, reason: '→ 应翻到 img3');
    log('arrowRight -> img3 ok');

    // ← ：回到 img2
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('img2.png'), findsWidgets, reason: '← 应回到 img2');
    log('arrowLeft -> img2 ok');

    // ←×2 ：回到 img1
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('img1.png'), findsWidgets, reason: '←×2 应回到 img1');
    log('arrowLeft x2 -> img1 ok');

    if (errors.isNotEmpty) {
      for (final e in errors.take(3)) {
        log('flutter error: ${e.exception}');
      }
      fail('捕获到 ${errors.length} 个 Flutter 错误');
    }
  });
}
