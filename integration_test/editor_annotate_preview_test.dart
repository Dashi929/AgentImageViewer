// 真机集成测试：标注拖拽预览应与类型一致（箭头/线条/虚线文字框等），
// 且各类型提交参数正确。
// 回归背景：所有标注拖动时都显示同一个矩形框，无法区分类型。
// 运行: flutter test integration_test/editor_annotate_preview_test.dart -d windows
import 'dart:io';
import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/editor/editor_page.dart';
import 'package:agent_image_viewer/ui/gallery/gallery_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _previewPainter = find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_AnnotateDragPainter',
    description: '标注拖拽预览 painter');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('标注拖拽预览与提交类型一致（真实引擎）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final ctx = tester.element(find.byType(GalleryPage));
    final state = AppStateScope.of(ctx, listen: false);
    expect(state.library.entries, isNotEmpty);
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
    expect(ctrl, isNotNull);
    final c = ctrl!;
    final canvasCenter = tester.getCenter(find.byType(EditorPage));

    await tester.tap(find.byTooltip('标注'));
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> dragKind(String label, Offset from) async {
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 300));
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.moveBy(const Offset(40, 25));
      await tester.pump(const Duration(milliseconds: 60));
      await gesture.moveBy(const Offset(50, 15));
      await tester.pump(const Duration(milliseconds: 60));
      expect(_previewPainter, findsOneWidget,
          reason: '$label 拖动中应显示对应类型的预览');
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    }

    var from = canvasCenter - const Offset(160, 60);
    await dragKind('矩形', from);
    expect(c.pipeline.nodes.last.params['kind'], AnnotateKinds.rect);

    from += const Offset(30, 40);
    await dragKind('椭圆', from);
    expect(c.pipeline.nodes.last.params['kind'], AnnotateKinds.ellipse);

    from += const Offset(30, 40);
    await dragKind('箭头', from);
    expect(c.pipeline.nodes.last.params['kind'], AnnotateKinds.arrow);

    from += const Offset(30, 40);
    await dragKind('马赛克', from);
    expect(c.pipeline.nodes.last.params['kind'], AnnotateKinds.mosaic);

    // 文字：拖出虚线框后弹输入框，取消不提交
    from += const Offset(30, 40);
    await dragKind('文字', from);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加文字标注'), findsOneWidget, reason: '文字拖拽后应弹出输入框');
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.pipeline.nodes.where((n) => n.params['kind'] == AnnotateKinds.text),
        isEmpty, reason: '取消输入不提交文字标注');

    // 涂鸦：折线预览 + 多点提交
    from += const Offset(30, 40);
    await tester.tap(find.text('涂鸦'));
    await tester.pump(const Duration(milliseconds: 300));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 80));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(20, i.isEven ? 12 : -8));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(_previewPainter, findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    final doodle = c.pipeline.nodes.last;
    expect(doodle.params['kind'], AnnotateKinds.doodle);
    expect((doodle.params['points'] as List).length, greaterThanOrEqualTo(3),
        reason: '涂鸦应记录拖动轨迹多点');

    // 真实帧压力
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
