// 一次性注册脚本：以最新代码把 AgentImageViewer 写入「打开方式」。
// 用法: dart run tool/register_assoc.dart
import 'package:agent_image_viewer/platform/file_assoc.dart';

void main() async {
  const exePath = r'E:\SoftwareProjects\AgentImageViewer\dist\AgentImageViewer\agent_image_viewer.exe';
  final assoc = FileAssoc(
    exeName: 'AgentImageViewer',
    exePath: exePath,
    iconPath: exePath,
  );
  final ok = await assoc.register(defaultAssocExtensions);
  // ignore: avoid_print
  print(ok ? 'REGISTER-OK' : 'REGISTER-FAILED');
}
