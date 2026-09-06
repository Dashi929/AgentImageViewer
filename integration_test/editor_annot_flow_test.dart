// 真机集成测试：直入编辑器复现「标注→图片消失→卡死」（Windows 桌面引擎）。
// 运行: flutter test integration_test/editor_annot_flow_test.dart -d windows
import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/gallery/gallery_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('标注全流程（直入编辑器）', (tester) async {
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) => errors.add(d);

    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    // 从图库取第一张图，直接打开编辑器（绕过浏览视图键盘依赖）
    final ctx = tester.element(find.byType(GalleryPage));
    final state = AppStateScope.of(ctx, listen: false);
    expect(state.library.entries, isNotEmpty, reason: '图库应有图片');
    final entry = state.library.entries.first;
    NavigatorStateEx.editor.value = entry;

    // 等控制器就绪（真实解码）
    EditorController? ctrl;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      ctrl = EditorController.controllerFor(
          entry.path.hashCode.toUnsigned(32).toString());
      if (ctrl != null && ctrl.preview != null) break;
    }
    expect(ctrl, isNotNull, reason: '编辑器控制器应就绪');
    expect(ctrl!.preview, isNotNull);
    final previewBefore = ctrl.preview;

    // 切换到「标注」工具
    await tester.tap(find.text('标注'));
    await tester.pump(const Duration(milliseconds: 300));

    // 画布上拖拽矩形标注 ×3（复现用户操作强度）
    final canvasCenter = tester.getCenter(find.byType(EditorPage));
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(
        canvasCenter - Offset(80 + i * 10, 60),
        const Offset(160, 100),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    // 断言：预览持续有效（旧 bug 下为 null/被释放）
    expect(ctrl.preview, isNotNull, reason: '标注后预览必须有效');
    expect(identical(ctrl.preview, previewBefore), isFalse,
        reason: '标注后应重新求值');

    // 真实帧再走几轮，确认渲染稳定
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ctrl.preview, isNotNull);

    final realErrors = errors
        .where((e) => e.exception.toString().contains('RenderFlex') == false)
        .toList();
    expect(realErrors, isEmpty, reason: '不应有未捕获异常');
  });
}
