/// 图库右键菜单回归：回收站项已移除、「从图库删除」入口与确认弹窗正确
/// （组件级验证，不依赖桌面环境）。
library;

import 'dart:io';

import 'package:agent_image_viewer/app_state.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:agent_image_viewer/ui/gallery/gallery_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_gallery_menu_test');
    app = AppState.forTest(tmp);
  });

  tearDown(() async {
    app.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> pumpGallery(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppStateScope(
          state: app,
          child: const GalleryPage(),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('右键菜单含「从图库删除」，不再有「移入回收站」；确认弹窗文案正确',
      (tester) async {
    final img = '${tmp.path}${Platform.pathSeparator}a.png';
    app.library.upsert(ImageEntry(
      path: img,
      name: 'a.png',
      sizeBytes: 123,
      mtimeMs: 1,
    ));
    await pumpGallery(tester);

    expect(find.text('a.png'), findsOneWidget);

    // 右键缩略图卡呼出上下文菜单
    await tester.tap(find.text('a.png'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('从图库删除'), findsOneWidget);
    expect(find.text('移入回收站'), findsNothing,
        reason: '回收站功能已整体移除');

    // 点「从图库删除」→ 确认弹窗，文案说明不删除本地文件
    await tester.tap(find.text('从图库删除'));
    await tester.pumpAndSettle();
    expect(find.text('仅从图库移除此图，不删除本地文件。'), findsOneWidget);
    expect(find.text('从图库删除'), findsWidgets); // 菜单项（已关）+ 弹窗标题

    // 取消不产生任何副作用
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.library.entryAt(img), isNotNull, reason: '取消后条目保留');
  });
}
