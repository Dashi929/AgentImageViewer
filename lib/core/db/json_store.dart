/// JSON 数据存储：图库索引、编辑栈、设置（设计书 3.5 节表 3-3）。
///
/// 落盘采用「临时文件 + 原子替换」，避免写入中断损坏数据。
/// 目录由调用方注入（桌面 userData / 移动沙盒），core 层不依赖平台 API。
library;

import 'dart:convert';
import 'dart:io';

/// 单个 JSON 文件的原子读写。
class JsonStore {
  JsonStore({required this.baseDir});

  final Directory baseDir;

  File _file(String name) => File('${baseDir.path}${Platform.pathSeparator}$name');

  Future<Map<String, Object?>?> load(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      final text = await f.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      return null;
    } on FormatException {
      // 数据损坏时不覆盖现场：交给上层提示重建，本层只保证不抛穿。
      return null;
    }
  }

  /// 原子写：先写 `<name>.tmp`，再替换目标文件。
  Future<void> save(String name, Map<String, Object?> data) async {
    final f = _file(name);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      // Windows 上目标存在时 rename 可能失败，退化为删除后替换。
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }

  /// 编辑栈文件名：`edits/<imageId>.json`。
  Future<Map<String, Object?>?> loadEditStack(String imageId) =>
      load('edits${Platform.pathSeparator}$imageId.json');

  Future<void> saveEditStack(String imageId, List<Map<String, Object?>> ops) =>
      save('edits${Platform.pathSeparator}$imageId.json', {'ops': ops});
}
