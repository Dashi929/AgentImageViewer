/// 快捷键速查面板（设计书 5.3 表 5-3：按 ? 呼出）。
library;

import 'package:flutter/material.dart';

import 'theme.dart';

const _rows = <(String, String, String)>[
  ('浏览', '← / →', '上一张 / 下一张'),
  ('浏览', 'Home / End', '第一张 / 最后一张'),
  ('浏览', '+ / -', '放大 / 缩小'),
  ('浏览', '0 / 1', '适应窗口 / 实际大小'),
  ('浏览', 'F', '全屏切换'),
  ('浏览', 'Space', '幻灯片播放/暂停（动图暂停帧）'),
  ('浏览', 'Del', '从图库删除（本地文件保留）'),
  ('浏览', '双击', '适应窗口 ↔ 100%'),
  ('浏览', '鼠标侧键', '下一张 / 上一张'),
  ('通用', 'Ctrl+O', '打开文件'),
  ('通用', 'Ctrl+E', '进入编辑视图'),
  ('通用', 'Ctrl+S', '导出当前编辑'),
  ('通用', 'Ctrl+Z / Ctrl+Y', '撤销 / 重做'),
  ('通用', 'Ctrl+F', '聚焦搜索框'),
  ('通用', 'Ctrl+K', '打开 AI 助手'),
  ('通用', 'F2', '虚拟重命名（不修改真实文件）'),
  ('通用', 'Esc', '退出全屏 / 关闭浮层 / 返回图库'),
  ('通用', '?', '快捷键速查'),
];

/// 呼出快捷键速查。
Future<void> showShortcutSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('快捷键'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final group in const {'浏览', '通用'})
              ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(group,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent)),
                ),
                for (final (g, key, desc) in _rows)
                  if (g == group)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 130,
                            child: Text(key,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textPrimary,
                                    fontFamily: 'monospace')),
                          ),
                          Expanded(
                            child: Text(desc,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary)),
                          ),
                        ],
                      ),
                    ),
              ],
          ],
        ),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('知道了')),
      ],
    ),
  );
}
