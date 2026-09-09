// 回归：浏览视图 AI 侧板开关（Ctrl+K）与幻灯片弹窗（间隔自由输入）。
// 运行: flutter test integration_test/viewer_ai_slideshow_test.dart -d windows
import 'dart:convert';
import 'dart:io';

import 'package:agent_image_viewer/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// ignore: avoid_print
void log(String m) => print('[ai-slide] $m');

/// 1×1 PNG。
final Uint8List kPng1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

Future<void> _ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

/// 控件 2 秒自动淡出：先点画布唤醒再点底栏按钮。
/// [wakeAt] 每次换坐标，避免与上次点按构成双击缩放。
Future<void> _wakeAndTap(WidgetTester tester, Finder finder,
    {Offset wakeAt = const Offset(400, 300)}) async {
  await tester.tapAt(wakeAt);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder, warnIfMissed: true);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 100));
}

/// 集成测试按键/点击偶发丢失：最多重试 3 次，真坏仍会失败。
Future<void> _ctrlKUntil(WidgetTester tester, bool wantOpen) async {
  for (var i = 0; i < 3; i++) {
    final open = find.text('AI 助手').evaluate().isNotEmpty;
    if (open == wantOpen) return;
    await _ctrlK(tester);
  }
}

Future<void> _openSlideshowDialog(WidgetTester tester,
    {Offset wakeAt = const Offset(400, 300)}) async {
  for (var i = 0; i < 3; i++) {
    await _wakeAndTap(tester, find.byIcon(Icons.slideshow), wakeAt: wakeAt);
    if (find.text('间隔（秒，可小数）').evaluate().isNotEmpty) return;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('AI 侧板开关 + 幻灯片自由间隔', (tester) async {
    final tmp = await Directory.systemTemp.createTemp('aiv_ai_slide');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final dir = '${tmp.path}${Platform.pathSeparator}pics';
    await Directory(dir).create();
    for (final n in ['img1.png', 'img2.png']) {
      await File('$dir${Platform.pathSeparator}$n').writeAsBytes(kPng1x1);
    }

    await app.appMain(['$dir${Platform.pathSeparator}img1.png']);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    log('viewer open');

    // Ctrl+K 唤出 AI 侧板（浏览视图中 shell 未渲染，出现即侧板）
    await _ctrlKUntil(tester, true);
    expect(find.text('AI 助手'), findsWidgets, reason: 'Ctrl+K 应唤出 AI 侧板');
    log('ai panel open');

    // 再按 Ctrl+K 关闭
    await _ctrlKUntil(tester, false);
    expect(find.text('AI 助手'), findsNothing, reason: '再次 Ctrl+K 应收起侧板');
    log('ai panel closed');

    // 底栏幻灯片按钮 → 弹窗 → 输入 0.5 秒 → 开始
    await _wakeAndTap(tester, find.byIcon(Icons.slideshow));
    expect(find.text('间隔（秒，可小数）'), findsOneWidget,
        reason: '幻灯片按钮应弹出设置+启停合一弹窗');
    await tester.enterText(find.byType(TextField), '0.5');
    await tester.pump();
    await tester.tap(find.text('开始幻灯片'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('幻灯片开始'), findsOneWidget,
        reason: '开始后应有 OSD 提示');
    log('slideshow started with custom 0.5s interval');

    // 等 OSD 消失（悬浮 SnackBar 会挡住底栏按钮），再开弹窗
    await tester.pump(const Duration(milliseconds: 1400));
    await _openSlideshowDialog(tester, wakeAt: const Offset(600, 260));
    expect(find.text('停止'), findsOneWidget, reason: '播放中弹窗应可停止');
    expect(find.text('0.5'), findsOneWidget, reason: '间隔应回显当前值 0.5');
    await tester.tap(find.text('停止'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('幻灯片暂停'), findsOneWidget,
        reason: '停止后应有 OSD 提示');
    log('slideshow stopped');
  });
}
