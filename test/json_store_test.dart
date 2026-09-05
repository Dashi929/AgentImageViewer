import 'dart:io';

import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/pipeline/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_store_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('save/load round-trip 且落盘为合法 JSON', () async {
    final store = JsonStore(baseDir: tmp);
    await store.save('library.json', {
      'version': 1,
      'items': [
        {'id': 'a1', 'path': r'E:\pics\a.jpg', 'tags': ['风景']},
      ],
    });

    final data = await store.load('library.json');
    expect(data?['version'], 1);
    expect((data?['items'] as List).first['tags'], ['风景']);
  });

  test('临时文件在写入后不残留', () async {
    final store = JsonStore(baseDir: tmp);
    await store.save('settings.json', {'theme': 'dark'});
    expect(tmp.listSync().whereType<File>().map((f) => f.path.endsWith('.tmp')),
        everyElement(isFalse));
  });

  test('损坏的 JSON 返回 null 而不抛异常，且不覆盖现场', () async {
    final f = File('${tmp.path}${Platform.pathSeparator}library.json');
    await tmp.create(recursive: true);
    await f.writeAsString('{"broken');
    final store = JsonStore(baseDir: tmp);
    expect(await store.load('library.json'), isNull);
    expect(await f.exists(), isTrue, reason: '损坏文件应保留给上层诊断');
  });

  test('编辑栈原子替换：二次保存后读到最新内容', () async {
    final store = JsonStore(baseDir: tmp);
    final stack = ImagePipeline.fromJson([
      {'op': 'rotate', 'params': {'deg': 90}},
    ]).toJson();
    await store.saveEditStack('img42', stack);

    final stack2 = [...stack,
      {'op': 'flip', 'params': {'axis': 'v'}},
    ];
    await store.saveEditStack('img42', stack2);

    final loaded = await store.loadEditStack('img42');
    expect((loaded?['ops'] as List).length, 2);
  });
}
