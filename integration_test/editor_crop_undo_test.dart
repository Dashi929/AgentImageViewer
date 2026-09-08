// 真机集成测试：复现「裁剪之后不能撤销，然后整个应用卡死」（Windows 桌面引擎）。
// 回归背景：自绘标题栏曾悬浮覆盖窗口顶部 36px，编辑器顶栏按钮（撤销/重做/导出）
// 鼠标永远点不到（Stack 命中测试被标题栏拖拽区截停）；改为标题栏独占一行后必须保持可点。
// 运行: flutter test integration_test/editor_crop_undo_test.dart -d windows
import 'dart:io';
import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('裁剪→撤销（按钮/键盘）循环（真实引擎）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final ctx = tester.element(find.byType(HomePage));
    final state = AppStateScope.of(ctx, listen: false);
    expect(state.library.entries, isNotEmpty, reason: '图库应有图片');
    // 图库可能含已移出盘的失效条目（文件不存在 decode 会抛异常）：只取真实存在的
    final entry = state.library.entries.firstWhere((e) => File(e.path).existsSync());
    NavigatorStateEx.editor.value = entry;

    EditorController? ctrl;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      ctrl = EditorController.controllerFor(
          entry.path.hashCode.toUnsigned(32).toString());
      if (ctrl != null) break;
    }
    expect(ctrl, isNotNull, reason: '编辑器控制器应就绪');
    final canvasCenter = tester.getCenter(find.byType(EditorPage));

    Future<void> doCrop(int i) async {
      final c = ctrl!;
      await tester.tap(find.byTooltip('裁剪'));
      await tester.pump(const Duration(milliseconds: 300));
      final genBefore = c.generation;
      // 两阶段裁剪：先「自由裁剪」进入选区模式，拖拽出预览，再确认
      await tester.tap(find.text('自由裁剪'));
      await tester.pump(const Duration(milliseconds: 300));
      final cropsBefore = c.pipeline.nodes.where((n) => n.op == Ops.crop).length;
      await tester.dragFrom(
        canvasCenter - Offset(120 + i * 5, 80),
        const Offset(200, 140),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('应用裁剪 (Enter)'), findsOneWidget,
          reason: '拖拽后应有待确认选区预览');
      expect(c.pipeline.nodes.where((n) => n.op == Ops.crop).length,
          cropsBefore,
          reason: '确认前不新增裁剪节点');
      await tester.tap(find.text('应用裁剪 (Enter)'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.pipeline.nodes.last.op, Ops.crop,
          reason: '确认后裁剪入栈');
      expect(c.generation, greaterThan(genBefore), reason: '裁剪后应重绘');
    }

    // 轮 1：撤销按钮（严格命中测试——被遮挡会失败）
    await doCrop(0);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final undoBtn = find.byTooltip('撤销 (Ctrl+Z)');
    expect(undoBtn, findsOneWidget);
    await tester.tap(undoBtn, warnIfMissed: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ctrl!.pipeline.nodes.where((n) => n.op == Ops.crop), isEmpty,
        reason: '点击撤销按钮后 crop 应被撤销');

    // 轮 2：Ctrl+Z 键盘路径（回归：焦点曾被根壳 autofocus 抢占导致快捷键全灭）
    await doCrop(1);
    await tester.pump(const Duration(milliseconds: 300));
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    expect(focusCtx?.findAncestorWidgetOfExactType<EditorPage>() != null,
        isTrue,
        reason: '焦点必须在编辑器子树内，否则 Ctrl+Z/Y/S、Esc 全部失效');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ctrl.pipeline.nodes.where((n) => n.op == Ops.crop), isEmpty,
        reason: 'Ctrl+Z 应撤销 crop');

    // 轮 3：连续 裁剪×2 → 撤销×2
    await doCrop(2);
    await doCrop(3);
    await tester.tap(undoBtn);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(undoBtn);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ctrl.pipeline.nodes.where((n) => n.op == Ops.crop), isEmpty);

    // 真实帧再走一轮：若存在卡死/异常风暴在此暴露
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
