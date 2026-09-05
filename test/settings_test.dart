import 'dart:io';

import 'package:agent_image_viewer/core/db/json_store.dart';
import 'package:agent_image_viewer/core/db/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_utils.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aiv_settings_test');
  });
  tearDown(() => deleteDirWithRetry(tmp));

  test('默认设置：AI 未配置时核心功能不受影响（本地优先）', () async {
    final store = JsonStore(baseDir: tmp);
    final s = await SettingsStore(store).load();
    expect(s.aiConfigured, isFalse, reason: '未配置密钥不影响浏览/编辑');
    expect(s.thumbSize, 320);
    expect(s.cacheMB, 512);
  });

  test('保存后重载一致，且旧数据缺字段时与默认值合并', () async {
    final store = JsonStore(baseDir: tmp);
    final st = SettingsStore(store);
    final s = await st.load();
    s.apiKey = 'sk-test';
    s.chatModel = 'glm-4-plus';
    s.cacheMB = 256;
    await st.save(s);

    final s2 = await st.load();
    expect(s2.apiKey, 'sk-test');
    expect(s2.chatModel, 'glm-4-plus');
    expect(s2.cacheMB, 256);
    expect(s2.aiBaseUrl, isNotEmpty, reason: '默认 baseUrl 被保留');
    expect(s2.thumbSize, 320);
  });

  test('部分数据（仅 ai 组）载入时补齐 perf 组', () async {
    final store = JsonStore(baseDir: tmp);
    await store.save('settings.json', {
      'ai': {'apiKey': 'sk-partial'},
    });
    final s = await SettingsStore(store).load();
    expect(s.apiKey, 'sk-partial');
    expect(s.cacheMB, 512);
    expect(s.thumbSize, 320);
  });
}
