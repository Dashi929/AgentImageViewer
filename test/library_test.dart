import 'dart:io';

import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/db/library.dart';
import 'package:agent_image_viewer/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String pics;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_lib_test');
    pics = '${tmp.path}${Platform.pathSeparator}pics';
    await Directory('$pics/sub').create(recursive: true);
    await File('$pics/b.jpg').writeAsBytes([1]);
    await File('$pics/a.png').writeAsBytes([2]);
    await File('$pics/sub/c.gif').writeAsBytes([3]);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('addFolder + rescan 建立索引并落盘，重启后可恢复', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    final entries = await lib.rescan();
    expect(entries.map((e) => e.name).toList(), ['a.png', 'b.jpg', 'c.gif']);

    // 模拟重启
    final lib2 = LibraryIndex(store);
    await lib2.load();
    expect(lib2.folders, [pics]);
    expect(lib2.entries.length, 3);
  });

  test('文件消失后 rescan 清理对应条目', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    await lib.rescan();
    expect(lib.entries.length, 3);

    await File('$pics/b.jpg').delete();
    await lib.rescan();
    expect(lib.entries.map((e) => e.name), ['a.png', 'c.gif']);
  });

  test('removeFolder 移除该目录下全部条目', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    await lib.rescan();
    await lib.removeFolder(pics);
    expect(lib.entries, isEmpty);
    await lib.flush();
    final lib2 = LibraryIndex(store);
    await lib2.load();
    expect(lib2.entries, isEmpty);
  });

  test('外部登记的条目（不在监控目录内）在 rescan 后保留', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    await lib.rescan();
    final outside = '${tmp.path}${Platform.pathSeparator}desktop_open.png';
    await File(outside).writeAsBytes([9]);
    lib.upsertAll(await scanDirectory(tmp.path)); // 便捷构造外部条目
    await lib.rescan();
    expect(lib.entryAt(outside), isNotNull,
        reason: '外部打开的图片自动登记进图库且不被监控目录 rescan 清掉');
  });

  test('hideEntry 从图库移除：本地文件不动，rescan 不再收录', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    await lib.rescan();

    // 索引键为 dir.list() 的原生路径（Windows 反斜杠），与 UI 传入的 e.path 同源
    final bPath = '$pics${Platform.pathSeparator}b.jpg';
    lib.hideEntry(bPath);
    await lib.flush();
    expect(lib.entries.map((e) => e.name), ['a.png', 'c.gif']);
    expect(File('$pics/b.jpg').existsSync(), isTrue,
        reason: '虚拟删除不触碰本地文件');

    // 重扫后不复活；重启后隐藏列表持久
    await lib.rescan();
    expect(lib.entryAt(bPath), isNull);
    final lib2 = LibraryIndex(store);
    await lib2.load();
    await lib2.rescan();
    expect(lib2.entries.map((e) => e.name), ['a.png', 'c.gif']);
  });

  test('hideEntry 幂等：重复移除同一不存在的路径不误标脏', () async {
    final store = JsonStore(baseDir: tmp);
    final lib = LibraryIndex(store);
    await lib.addFolder(pics);
    await lib.rescan();
    await lib.flush();

    final bPath = '$pics${Platform.pathSeparator}b.jpg';
    lib.hideEntry(bPath);
    lib.hideEntry(bPath);
    await lib.flush();
    expect(lib.entries.map((e) => e.name), ['a.png', 'c.gif']);
  });
}
