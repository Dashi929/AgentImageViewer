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
      expect(defaultAssocExtensions.where((e) => e == '.svg'), isEmpty,
          reason: '设计书 6.2：svg 默认不注册');
      expect(defaultAssocExtensions.where((e) => e == '.heic'), isEmpty,
          reason: 'heic 不在 MVP 范围');
      // 每个扩展名都有一条 OpenWithProgids
      for (final ext in defaultAssocExtensions) {
        expect(all, contains('\\Software\\Classes$ext\\OpenWithProgids'));
      }
    });

    test('取消注册：清理 ProgID 与全部扩展名，不留残留', () {
      final cmds = buildUnregisterCommands(
        exeName: 'AgentImageViewer',
        extensions: defaultAssocExtensions,
      );
      final all = cmds.map((c) => c.join(' ')).join('\n');
      expect(all, contains('delete HKCU\\Software\\Classes\\AgentImageViewer.ImageViewer /f'));
      for (final ext in defaultAssocExtensions) {
        expect(all, contains('delete HKCU\\Software\\Classes$ext\\OpenWithProgids /v AgentImageViewer.ImageViewer'));
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
}
