/// 测试工具：Windows 上临时目录可能被杀毒/索引服务短暂锁定，删除带重试。
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

Future<void> deleteDirWithRetry(Directory dir,
    {int attempts = 6, Duration delay = const Duration(milliseconds: 60)}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future.delayed(delay);
    }
  }
  // 最终仍失败则保留现场（不污染测试结果）
}
