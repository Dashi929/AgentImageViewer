// 真机集成测试：自由旋转/调整滑杆「拖动即时预览、松手提交、多次合并」。
// 回归背景：滑杆原本要点「应用」按钮才生效；自由旋转多次应用会重复烘焙
// 包围盒导致内容越转越小。
// 运行: flutter test integration_test/editor_slider_live_test.dart -d windows
import 'dart:io';
import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/editor/editor_controller.dart';
import 'package:agent_image_viewer/core/pipeline/node.dart';
import 'package:agent_image_viewer/main.dart' as app;
import 'package:agent_image_viewer/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('滑杆即时预览与合并提交（真实引擎）', (tester) async {
    await app.appMain(const []);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));

    final ctx = tester.element(find.byType(HomePage));
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

    // ---- 自由旋转：拖动即时预览 ----
    await tester.tap(find.byTooltip('裁剪'));
    await tester.pump(const Duration(milliseconds: 300));

    final frSlider = tester.widget<Slider>(find.byType(Slider).first);
    final center = tester.getCenter(find.byWidget(frSlider));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 拖动中：预览生效但未入栈
    expect(c.freeRotatePreview, isNotNull,
        reason: '拖动中应有实时预览角度');
    expect(c.pipeline.nodes, isEmpty, reason: '拖动中不产生节点');
    final genDuring = c.generation;
    expect(genDuring, greaterThan(0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    // 松手：落栈为单个 free_rotate 节点
    expect(c.freeRotatePreview, isNull);
    expect(c.pipeline.nodes.map((n) => n.op), ['free_rotate']);
    final deg1 = (c.pipeline.nodes.single.params['deg'] as num).toDouble();
    expect(deg1, greaterThan(0), reason: '右拖应产生正向角度');

    // ---- 第二轮：合并为单节点（不越转越少的关键） ----
    // 滑杆现在显示已提交的累计角度；从滑杆中心再拖（绝对语义下即从 0 附近开始）
    final frSlider2 = tester.widget<Slider>(find.byType(Slider).first);
    final center2 = tester.getCenter(find.byWidget(frSlider2));
    final gesture2 = await tester.startGesture(center2);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 2; i++) {
      await gesture2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await gesture2.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(c.pipeline.nodes.map((n) => n.op), ['free_rotate'],
        reason: '多次自由旋转必须合并为栈尾单节点，避免重复烘焙');
    final deg2 = (c.pipeline.nodes.single.params['deg'] as num).toDouble();
    expect(deg2, lessThanOrEqualTo(180), reason: '归一化边界');
    // 滑杆显示已生效值：标签文本应与提交后的累计角度一致
    expect(find.text('${deg2.round()}°'), findsWidgets,
        reason: '提交后滑杆应显示当前生效角度而不是归 0');
    // 撤销回上一轮角度
    await c.undo();
    expect((c.pipeline.nodes.single.params['deg'] as num).toDouble(), deg1);

    // ---- 调整滑杆：即时预览 ----
    await tester.tap(find.byTooltip('调整'));
    await tester.pump(const Duration(milliseconds: 300));
    final sliders = find.byType(Slider);
    expect(tester.widgetList<Slider>(sliders).length, 5, reason: '五个调整滑杆');

    final bCenter = tester.getCenter(sliders.first);
    final g3 = await tester.startGesture(bCenter);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 4; i++) {
      await g3.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(c.adjustPreview, isNotNull, reason: '调整滑杆拖动中应即时预览');
    expect(c.pipeline.nodes.where((n) => n.op == Ops.adjust), isEmpty,
        reason: '拖动中不产生 adjust 节点');
    await g3.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.adjustPreview, isNull);
    expect(c.pipeline.nodes.where((n) => n.op == Ops.adjust).length, 1,
        reason: '松手提交调整节点');

    // 真实帧压力：无异常、无卡死
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
