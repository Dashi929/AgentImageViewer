/// 设置存储（settings.json，设计书 4.3.5）：AI / 性能 / 系统三组。
/// API Key 只落本机 settings.json，不上传、不写日志（设计书 6.3）。
library;

import 'json_store.dart';

class Settings {
  Settings({Map<String, Object?>? data})
      : data = _mutable(data ?? _defaults);

  static const _defaults = {
    'ai': {
      'baseUrl': 'https://open.bigmodel.cn/api/paas/v4',
      'apiKey': '',
      'chatModel': 'glm-4-flash',
      'visionModel': 'glm-4v-flash',
      'imageEditModel': '',
    },
    'perf': {'thumbSize': 320, 'cacheMB': 512},
    'system': {'assocEnabled': false},
  };

  /// 深拷贝为可变结构（const 默认值不可修改）。
  static Map<String, Object?> _mutable(Map<String, Object?> src) => {
        for (final e in src.entries)
          e.key: e.value is Map
              ? Map<String, Object?>.of((e.value as Map).cast<String, Object?>())
              : e.value,
      };

  Map<String, Object?> data;

  // ---- AI ----
  String get aiBaseUrl => _aiStr('baseUrl');
  set aiBaseUrl(String v) => _aiSet('baseUrl', v);
  String get apiKey => _aiStr('apiKey');
  set apiKey(String v) => _aiSet('apiKey', v);
  String get chatModel => _aiStr('chatModel');
  set chatModel(String v) => _aiSet('chatModel', v);
  String get visionModel => _aiStr('visionModel');
  set visionModel(String v) => _aiSet('visionModel', v);

  /// 生成式图像编辑模型（背景替换/消除/扩图）；为空表示未启用。
  String get imageEditModel => _aiStr('imageEditModel');
  set imageEditModel(String v) => _aiSet('imageEditModel', v);
  bool get generativeEnabled => imageEditModel.isNotEmpty;

  // ---- 系统 ----
  bool get assocEnabled => ((data['system'] as Map?)?['assocEnabled'] as bool?) ?? false;
  set assocEnabled(bool v) {
    final sys = Map<String, Object?>.of((data['system'] as Map? ?? {}).cast<String, Object?>());
    sys['assocEnabled'] = v;
    data['system'] = sys;
  }

  bool get aiConfigured => apiKey.isNotEmpty;

  // ---- 性能 ----
  int get thumbSize => ((data['perf'] as Map?)?['thumbSize'] as num?)?.toInt() ?? 320;
  set thumbSize(int v) => _perfSet('thumbSize', v);
  int get cacheMB => ((data['perf'] as Map?)?['cacheMB'] as num?)?.toInt() ?? 512;
  set cacheMB(int v) => _perfSet('cacheMB', v);

  String _aiStr(String key) =>
      ((data['ai'] as Map?)?[key] as String?) ?? '';
  void _aiSet(String key, String v) {
    final ai = Map<String, Object?>.of((data['ai'] as Map? ?? {}).cast<String, Object?>());
    ai[key] = v;
    data['ai'] = ai;
  }

  void _perfSet(String key, num v) {
    final perf =
        Map<String, Object?>.of((data['perf'] as Map? ?? {}).cast<String, Object?>());
    perf[key] = v;
    data['perf'] = perf;
  }
}

class SettingsStore {
  SettingsStore(this._store);

  final JsonStore _store;

  Future<Settings> load() async {
    final raw = await _store.load('settings.json');
    final s = Settings();
    if (raw != null) {
      s.data = Settings._mutable(Map<String, Object?>.of(raw));
      // 合并缺省组，避免旧版本数据缺字段
      final defaults = Settings._defaults;
      s.data['ai'] = Settings._mutable({
        ...(defaults['ai'] as Map<String, Object?>),
        ...((raw['ai'] as Map? ?? {}).cast<String, Object?>()),
      });
      s.data['perf'] = Settings._mutable({
        ...(defaults['perf'] as Map<String, Object?>),
        ...((raw['perf'] as Map? ?? {}).cast<String, Object?>()),
      });
      s.data['system'] = Settings._mutable({
        ...(defaults['system'] as Map<String, Object?>),
        ...((raw['system'] as Map? ?? {}).cast<String, Object?>()),
      });
    }
    return s;
  }

  Future<void> save(Settings s) => _store.save('settings.json', s.data);
}
