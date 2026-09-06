// 真机集成测试：完整复现「图库→浏览→编辑→标注」流程（Windows 桌面引擎）。
// 运行: flutter test integration_test/editor_annot_flow_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('标注全流程：编辑器→标注→拖拽→连续标注', (tester) async {
    // 记录渲染管线异常
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) => errors.add(d);

    await app.appMain(const []);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 1) 图库：按文件名文本定位第一张缩略图卡片并点击
    final nameFinder = find.textContaining('.jpg');
    expect(nameFinder, findsWidgets, reason: '图库应有卡片');
    final card = find.ancestor(
        of: nameFinder.first, matching: find.byType(InkWell));
    await tester.tap(card, warnIfMissed: true);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 2) 浏览视图 → Ctrl+E 进编辑器
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE, platform: 'windows');
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 3) 编辑器就绪
    expect(find.text('标注'), findsOneWidget, reason: '编辑器工具箱应含标注');
    await tester.tap(find.text('标注'));
    await tester.pumpAndSettle();

    // 4) 画布拖拽矩形标注 ×3（用户操作强度）
    final canvasCenter = tester.getCenter(find.byType(Scaffold).first);
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(
        canvasCenter - Offset(80 + i * 10, 60),
        const Offset(160, 100),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
    }

    // 5) 断言：控制器存活、预览有效、无未捕获异常
    final controllers = EditorController.activeControllers;
    expect(controllers, isNotEmpty, reason: '编辑器控制器应存活');
    for (final c in controllers.values) {
      expect(c.preview, isNotNull, reason: '标注后预览必须有效');
    }
    expect(errors.where((e) => e.exception is! FlutterError), isEmpty,
        reason: '不应有渲染层异常');
  });
}
