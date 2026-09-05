import 'dart:io';

import 'package:agent_image_viewer/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('自然排序', () {
    test('数字段按数值比较', () {
      final names = ['img10.jpg', 'img2.jpg', 'img1.jpg', 'IMG3.jpg'];
      final sorted = names..sort(naturalCompare);
      expect(sorted, ['img1.jpg', 'img2.jpg', 'IMG3.jpg', 'img10.jpg']);
    });

    test('多位数字与前导零稳定', () {
      expect(naturalCompare('a007.jpg', 'a8.jpg'), lessThan(0),
          reason: '数值 7 < 8，前导零不影响数值比较');
      expect(naturalCompare('a07.jpg', 'a07.jpg'), 0);
    });

    test('纯文本段大小写不敏感，耗尽者在前', () {
      expect(naturalCompare('abc.jpg', 'ABD.jpg'), lessThan(0));
      expect(naturalCompare('ab.jpg', 'abc.jpg'), lessThan(0));
    });
  });

  group('格式判定', () {
    test('支持核心与动图格式，大小写不敏感', () {
      expect(SupportedFormats.isSupported(r'E:\a.JPG'), isTrue);
      expect(SupportedFormats.isSupported(r'E:\a.WebP'), isTrue);
      expect(SupportedFormats.isSupported(r'E:\a.txt'), isFalse);
      expect(SupportedFormats.isSupported(r'E:\noext'), isFalse);
    });
  });

  group('目录扫描', () {
    late String root;

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('aiv_scan');
      root = tmp.path;
      await Directory('$root/sub').create();
      await File('$root/img10.jpg').writeAsBytes([1]);
      await File('$root/img2.png').writeAsBytes([1]);
      await File('$root/.hidden.jpg').writeAsBytes([1]);
      await File('$root/notes.txt').writeAsBytes([1]);
      await File('$root/sub/photo.gif').writeAsBytes([1]);
    });

    tearDown(() async {
      await Directory(root).delete(recursive: true);
    });

    test('递归扫描受支持格式、跳过隐藏与不支持文件、自然排序', () async {
      final entries = await scanDirectory(root);
      expect(entries.map((e) => e.name).toList(),
          ['img2.png', 'img10.jpg', 'photo.gif']);
      final sizes = entries.map((e) => e.sizeBytes).toList();
      expect(sizes, everyElement(1));
    });

    test('不存在的目录返回空', () async {
      expect(await scanDirectory('$root/__nope__'), isEmpty);
    });

    test('pendingThumbTasks 只列未缓存条目', () {
      final entries = [
        ImageEntry(path: 'a', name: 'a', sizeBytes: 1, mtimeMs: 1),
        ImageEntry(path: 'b', name: 'b', sizeBytes: 1, mtimeMs: 2),
      ];
      final tasks = pendingThumbTasks(entries, {'k_b'}, (e) => 'k_${e.name}');
      expect(tasks.map((e) => e.name), ['a']);
    });
  });
}
