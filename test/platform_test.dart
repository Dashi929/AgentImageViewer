import 'dart:io';

import 'package:agent_image_viewer/platform/file_assoc.dart';
import 'package:agent_image_viewer/platform/trash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('文件关联命令构建（纯函数）', () {
    test('注册：ProgID + OpenWithProgids，默认七种格式', () {
      final cmds = buildRegisterCommands(
        exeName: 'AgentImageViewer',
        exePath: r'C:\apps\AgentImageViewer.exe',
        iconPath: r'C:\apps\AgentImageViewer.exe',
        extensions: defaultAssocExtensions,
      );
      final all = cmds.map((c) => c.join(' ')).join('\n');

      expect(all, contains(r'HKCU\Software\Classes\AgentImageViewer.ImageViewer'), reason: 'HKCU 无需管理员');
      expect(all, contains('"C:\\apps\\AgentImageViewer.exe" "%1"'));
      expect(all, contains(r'.jpg'));
      expect(all, contains(r'.avif'));
      // 「打开方式」完整体验（设计书 6.1）：应用列表 + MuiCache 友好名/厂商
      expect(all, contains(r'Applications\AgentImageViewer.exe\shell\open\command'),
          reason: '「打开方式 → 其他应用」应用列表');
      expect(all, contains('FriendlyAppName'));
      expect(all, contains('.FriendlyAppName'), reason: 'MuiCache 友好名条目');
      expect(all, contains('.ApplicationCompany'), reason: 'MuiCache 厂商条目');
      expect(all, contains('AgentImageViewer 图像文件'));
      expect(defaultAssocExtensions.where((e) => e == '.svg'), isEmpty,
          reason: '设计书 6.2：svg 默认不注册');
      expect(defaultAssocExtensions.where((e) => e == '.heic'), isEmpty,
          reason: 'heic 不在 MVP 范围');
      // 每个扩展名都有一条 OpenWithProgids
      for (final ext in defaultAssocExtensions) {
        expect(all, contains('\\Software\\Classes\\$ext\\OpenWithProgids'));
      }
    });

    test('取消注册：清理 ProgID、应用列表与全部扩展名，不留残留', () {
      final cmds = buildUnregisterCommands(
        exeName: 'AgentImageViewer',
        exePath: r'C:\apps\AgentImageViewer.exe',
        extensions: defaultAssocExtensions,
      );
      final all = cmds.map((c) => c.join(' ')).join('\n');
      expect(all, contains('delete HKCU\\Software\\Classes\\AgentImageViewer.ImageViewer /f'));
      expect(all, contains(r'Applications\AgentImageViewer.exe'),
          reason: '应用列表项一并清理');
      expect(all, contains('.FriendlyAppName'), reason: 'MuiCache 友好名清理');
      for (final ext in defaultAssocExtensions) {
        expect(all,
            contains('delete HKCU\\Software\\Classes\\$ext\\OpenWithProgids /v AgentImageViewer.ImageViewer'));
      }
    });

    test('无点扩展名自动补点', () {
      final cmds = buildRegisterCommands(
        exeName: 'X',
        exePath: 'x.exe',
        iconPath: 'x.exe',
        extensions: ['jpg'],
      );
      expect(cmds.map((c) => c.join(' ')).join(), contains('.jpg'));
    });
  });

  group('回收站命令构建（纯函数）', () {
    test('路径被安全转义并指定 SendToRecycleBin', () {
      final cmd = buildRecycleCommand(r"C:\pics\my 'photo'.jpg").join(' ');
      expect(cmd, contains("my ''photo''"));
      expect(cmd, contains('SendToRecycleBin'));
      expect(cmd, isNot(contains('PermanentlyDelete')));
    });
  });

/// 真实注册表写入/清理（仅本机验证，AIV_ASSOC=1 时执行）。
/// 写入 HKCU 无需管理员，测试结束后完整清理。
test('真实注册表端到端（AIV_ASSOC=1 时执行）', () async {
  if (!Platform.isWindows || Platform.environment['AIV_ASSOC'] != '1') return;
  const exe = r'C:\test\AgentImageViewer.exe';
  final assoc = FileAssoc(
      exeName: 'AgentImageViewer', exePath: exe, iconPath: exe);
  final progId = progIdFor('AgentImageViewer');

  // 注册
  expect(await assoc.register(defaultAssocExtensions), isTrue);
  final q1 = await Process.run(
      'reg', ['query', r'HKCU\Software\Classes\.jpg\OpenWithProgids', '/v', progId]);
  expect(q1.exitCode, 0, reason: '.jpg OpenWithProgids 应已写入');
  final q2 = await Process.run('reg',
      ['query', r'HKCU\Software\Classes\Applications\AgentImageViewer.exe']);
  expect(q2.exitCode, 0, reason: '「打开方式→其他应用」列表项应已写入');
  final q3 = await Process.run('reg', [
    'query',
    r'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache',
    '/v', '$exe.FriendlyAppName',
  ]);
  expect(q3.exitCode, 0, reason: 'MuiCache 友好名应已写入');

  // 清理
  expect(await assoc.unregister(defaultAssocExtensions), isTrue);
  final q4 = await Process.run(
      'reg', ['query', r'HKCU\Software\Classes\.jpg\OpenWithProgids', '/v', progId]);
  expect(q4.exitCode, isNot(0), reason: '取消注册后不残留');
  final q5 = await Process.run(
      'reg', ['query', r'HKCU\Software\Classes\Applications\AgentImageViewer.exe']);
  expect(q5.exitCode, isNot(0), reason: '应用列表项不残留');
});
}
