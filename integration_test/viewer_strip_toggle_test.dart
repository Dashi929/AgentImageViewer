// 回归：浏览视图单击图片切换缩略图条显示/隐藏（2026-10-29 用户需求）。
// 同时验证不误触场景：拖拽平移不切换、双击缩放（适应↔100%）不切换——
// 单击必须延迟到 320ms 双击窗口结束后才生效，否则双击的第一击会先把条隐藏。
// 运行: flutter test integration_test/viewer_strip_toggle_test.dart -d windows
import 'dart:convert';
import 'dart:io';

import 'package:agent_image_viewer/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 1×1 红色 PNG（合法文件头，解码器可解）。
final kPng1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

AnimatedOpacity _stripOf(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('thumbStrip')));

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('单击切换缩略图条；拖拽/双击不切换', (tester) async {
    final tmp = await Directory.systemTemp.createTemp('aiv_strip_toggle');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final sep = Platform.pathSeparator;
    final dir = '${tmp.path}${sep}pics';
    await Directory(dir).create();
    for (final n in ['a.png', 'b.png', 'c.png']) {
      await File('$dir$sep$n').writeAsBytes(kPng1x1);
    }

    await app.appMain(['$dir${sep}a.png']);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('a.png'), findsWidgets,
        reason: '带图启动应直接进入所在文件夹浏览');

    // 画布中上部：避开底部 84~160px 的缩略图条与底栏
    const tap = Offset(400, 300);

    // 拖拽平移：抬起时不构成单击（位移 > 10px），条保持显示
    final drag = await tester.startGesture(tap);
    await drag.moveBy(const Offset(80, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripOf(tester).opacity, 1.0, reason: '拖拽不应切换缩略图条');

    // 双击（间隔 120ms < 320ms 窗口）：走缩放路径，条不切换
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripOf(tester).opacity, 1.0, reason: '双击缩放不应隐藏缩略图条');

    // 单击第 1 次：320ms 后隐藏
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 550));
    expect(_stripOf(tester).opacity, 0.0, reason: '单击应隐藏缩略图条');

    // 单击第 2 次：恢复显示
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 550));
    expect(_stripOf(tester).opacity, 1.0, reason: '再单击应显示缩略图条');
  });
}
