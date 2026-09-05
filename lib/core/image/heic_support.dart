/// HEIC/HEIF 解码支持检测与引导（设计书 2.2 表 2-2 / 8-1）。
///
/// Windows 依赖系统「HEIF 图像扩展」，缺失时给出引导提示；
/// iOS 原生支持；Android 视设备（API 28+ 多数支持）。
library;

import 'dart:io';

enum HeicSupport { unknown, supported, missing, notApplicable }

/// 构建 Windows HEIF 扩展检测命令（纯函数，可单测）。
List<String> buildHeifDetectCommand() => [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Get-AppxPackage Microsoft.HEIFImageExtension | Select-Object -ExpandProperty Version',
    ];

/// 构建打开系统商店 HEIF 扩展页的 URI（纯函数）。
Uri heifStoreUri() => Uri.parse('ms-windows-store://pdp/?ProductId=9n4wgh0z6vhq');

/// 检测当前平台 HEIC 支持。检测失败返回 unknown，不抛异常。
Future<HeicSupport> detectHeicSupport() async {
  try {
    if (Platform.isIOS) return HeicSupport.supported; // iOS 原生解码
    if (Platform.isAndroid) return HeicSupport.supported; // API 28+ 主流支持
    if (Platform.isWindows) {
      final r = await Process.run('powershell.exe', buildHeifDetectCommand());
      final version = (r.stdout as String).trim();
      return version.isEmpty ? HeicSupport.missing : HeicSupport.supported;
    }
    return HeicSupport.notApplicable;
  } catch (_) {
    return HeicSupport.unknown;
  }
}

/// 引导文案（设计书：检测缺失时给出引导提示）。
String heicGuidanceText(HeicSupport support) => switch (support) {
      HeicSupport.missing =>
        '无法解码 HEIC：系统缺少「HEIF 图像扩展」。'
            '请到 Microsoft Store 安装「HEIF 图像扩展」（免费），安装后重新打开图片即可。',
      HeicSupport.unknown =>
        '无法解码 HEIC：当前系统不支持该格式，或文件已损坏。',
      _ => '',
    };
