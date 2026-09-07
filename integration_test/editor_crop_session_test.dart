// 真机集成测试：裁剪两阶段流程（PS 式预览 → 用户确认才生效）。
// 回归背景：裁剪曾拖完直接入栈；比例预设按钮挂在未接线的 GlobalKey 上完全无效。
// 运行: flutter test integration_test/editor_crop_session_test.dart -d windows
import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/gallery/gallery_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('裁剪：预览→确认/取消（比例预设 + 自由裁剪 + Enter/Esc）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final ctx = tester.element(find.byType(GalleryPage));
    final state = AppStateScope.of(ctx, listen: false);
    expect(state.library.entries, isNotEmpty);
    final entry = state.library.entries.first;
    NavigatorStateEx.editor.value = entry;

    EditorController? ctrl;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      ctrl = EditorController.controllerFor(
          entry.path.hashCode.toUnsigned(32).toString());
      if (ctrl != null) break;
    }
    expect(ctrl, isNotNull);
    final c = ctrl!;
    final canvasCenter = tester.getCenter(find.byType(EditorPage));

    int cropCount() =>
        c.pipeline.nodes.where((n) => n.op == Ops.crop).length;

    await tester.tap(find.byTooltip('裁剪'));
    await tester.pump(const Duration(milliseconds: 300));

    // 面板含「自由裁剪」入口与三个比例预设
    expect(find.text('自由裁剪'), findsOneWidget);
    expect(find.text('1:1'), findsOneWidget);
    expect(find.text('4:3'), findsOneWidget);
    expect(find.text('16:9'), findsOneWidget);

    // ---- 比例预设：进入预览，不入栈 ----
    await tester.tap(find.text('4:3'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('应用裁剪 (Enter)'), findsOneWidget, reason: '比例选区应进入待确认预览');
    expect(cropCount(), 0, reason: '确认前不得入栈');

    // 取消 → 无副作用
    await tester.tap(find.text('取消 (Esc)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('应用裁剪 (Enter)'), findsNothing);
    expect(cropCount(), 0);

    // ---- 比例预设 + Enter 确认 ----
    await tester.tap(find.text('16:9'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(cropCount(), 1, reason: 'Enter 应确认裁剪');
    expect(find.text('应用裁剪 (Enter)'), findsNothing);

    // ---- 自由裁剪：拖拽出选区 → 预览 → 确认 ----
    await tester.tap(find.text('自由裁剪'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.dragFrom(canvasCenter - const Offset(150, 100),
        const Offset(220, 150));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('应用裁剪 (Enter)'), findsOneWidget,
        reason: '自由拖拽后应进入待确认预览');
    expect(cropCount(), 1, reason: '预览阶段不入栈');

    await tester.tap(find.text('应用裁剪 (Enter)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cropCount(), 2, reason: '确认后入栈');

    // ---- Esc 优先取消选区，而不是退出编辑器 ----
    await tester.tap(find.text('1:1'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditorPage), findsOneWidget,
        reason: 'Esc 应先取消裁剪选区而非退出编辑');
    expect(cropCount(), 2, reason: '取消不入栈');

    // Esc 再按一次 → 退出编辑器
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EditorPage), findsNothing, reason: '无选区时 Esc 退出编辑');

    // 真实帧压力
    await tester.pump(const Duration(seconds: 1));
  });
}
