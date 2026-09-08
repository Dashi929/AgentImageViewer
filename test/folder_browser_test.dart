/// 即时浏览核心单测：路径工具、目录列举、相邻文件夹决议。
library;

import 'dart:io';

import 'package:agent_image_viewer/core/browser/folder_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('路径工具（纯函数）', () {
    test('normalize 去尾分隔符但保留盘根与根', () {
      expect(FolderBrowser.normalize(r'C:\a\b\'), r'C:\a\b');
      expect(FolderBrowser.normalize('C:/a/b/'), 'C:/a/b');
      expect(FolderBrowser.normalize(r'C:\'), r'C:\');
      expect(FolderBrowser.normalize(r'C:\\'), r'C:\');
      expect(FolderBrowser.normalize('/'), '/');
      expect(FolderBrowser.normalize('/home/user/'), '/home/user');
    });

    test('parentOf：根的父是自身，普通目录取上一级', () {
      expect(FolderBrowser.parentOf(r'C:\a\b'), r'C:\a');
      expect(FolderBrowser.parentOf(r'C:\a'), r'C:\');
      expect(FolderBrowser.parentOf(r'C:\'), r'C:\');
      expect(FolderBrowser.parentOf('/home'), '/');
      expect(FolderBrowser.parentOf('/'), '/');
    });

    test('nameOf 取末段', () {
      expect(FolderBrowser.nameOf(r'C:\a\b\c.png'), 'c.png');
      expect(FolderBrowser.nameOf('/x/y.jpg'), 'y.jpg');
    });
  });

  group('neighborImageFolder（纯函数）', () {
    final ordered = [r'E:\p\a', r'E:\p\b', r'E:\p\c'];
    test('向前/向后取相邻', () {
      expect(neighborImageFolder(ordered, r'E:\p\b', forward: true), r'E:\p\c');
      expect(neighborImageFolder(ordered, r'E:\p\b', forward: false), r'E:\p\a');
      expect(neighborImageFolder(ordered, r'E:\p\c', forward: true), isNull);
      expect(neighborImageFolder(ordered, r'E:\p\a', forward: false), isNull);
    });
    test('不含当前项返回 null', () {
      expect(neighborImageFolder(ordered, r'E:\p\z', forward: true), isNull);
    });
  });

  group('目录扫描（IO）', () {
    late Directory tmp;
    late String root;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('aiv_browser_test');
      root = '${tmp.path}${Platform.pathSeparator}pics';
      await Directory('$root${Platform.pathSeparator}sub').create(recursive: true);
      await Directory('$root${Platform.pathSeparator}b_dir').create();
      await Directory('$root${Platform.pathSeparator}.hidden_dir').create();
      for (final f in ['$root${Platform.pathSeparator}img10.png',
        '$root${Platform.pathSeparator}img2.png',
        '$root${Platform.pathSeparator}note.txt',
        '$root${Platform.pathSeparator}.a.png']) {
        await File(f).writeAsBytes([1]);
      }
      await File('$root${Platform.pathSeparator}b_dir${Platform.pathSeparator}b1.jpg')
          .writeAsBytes([1]);
      await File('$root${Platform.pathSeparator}sub${Platform.pathSeparator}s1.gif')
          .writeAsBytes([1]);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('listImages：直接子文件、自然排序、跳过隐藏与非图片', () async {
      final list = await FolderBrowser.listImages(root);
      expect(list.map((e) => e.name).toList(), ['img2.png', 'img10.png']);
    });

    test('listImages：hidden 集合剔除', () async {
      final p2 = '$root${Platform.pathSeparator}img2.png';
      final list = await FolderBrowser.listImages(root, hidden: {p2});
      expect(list.map((e) => e.name).toList(), ['img10.png']);
    });

    test('imageFoldersAround：只留含图文件夹、含自身、自然排序', () async {
      final folders = await FolderBrowser.imageFoldersAround(
          '$root${Platform.pathSeparator}sub');
      // sub 本身无图但应包含自身；b_dir 有图；.hidden_dir 与空目录剔除
      expect(folders, contains('$root${Platform.pathSeparator}sub'));
      expect(folders, contains('$root${Platform.pathSeparator}b_dir'));
      expect(folders, isNot(contains('$root${Platform.pathSeparator}.hidden_dir')));
      final iSub = folders.indexOf('$root${Platform.pathSeparator}sub');
      final iB = folders.indexOf('$root${Platform.pathSeparator}b_dir');
      expect(iB, lessThan(iSub), reason: 'b_dir 自然排序在 sub 之前');
    });

    test('neighborImageFolder：到头返回 null（配合扫描）', () async {
      final folders = await FolderBrowser.imageFoldersAround(
          '$root${Platform.pathSeparator}b_dir');
      expect(neighborImageFolder(folders, '$root${Platform.pathSeparator}b_dir',
              forward: false), isNull);
      final next = neighborImageFolder(
          folders, '$root${Platform.pathSeparator}b_dir',
          forward: true);
      expect(next, '$root${Platform.pathSeparator}sub');
    });
  });
}
