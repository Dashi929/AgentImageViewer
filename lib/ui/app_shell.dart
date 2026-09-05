/// 应用外壳：桌面「侧边栏 + 内容区」双栏（设计书 4.2 节）。
///
/// S0 阶段各导航页为占位，随后续里程碑逐个落地。
library;

import 'package:flutter/material.dart';

import 'theme.dart';

enum NavTab { gallery, tags, ai, settings }

class AppShell extends StatelessWidget {
  const AppShell({super.key, this.desktop = true});

  final bool desktop;
  final _items = const [
    (NavTab.gallery, Icons.photo_library_outlined, '图库'),
    (NavTab.tags, Icons.label_outline, '标签'),
    (NavTab.ai, Icons.auto_awesome_outlined, 'AI 助手'),
    (NavTab.settings, Icons.settings_outlined, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NavTab>(
      valueListenable: currentTab,
      builder: (context, tab, _) {
        final content = _pageFor(tab);
        if (!desktop) return content;
        return Row(
          children: [
            _Sidebar(items: _items, current: tab, onSelect: (t) => currentTab.value = t),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _pageFor(NavTab tab) => switch (tab) {
        NavTab.gallery => const _Placeholder('图库 — S1/S2 落地'),
        NavTab.tags => const _Placeholder('标签 — S2 落地'),
        NavTab.ai => const _Placeholder('AI 助手 — S4 落地'),
        NavTab.settings => const _Placeholder('设置 — S3 落地'),
      };
}

/// 全局当前导航页（S0 简单实现；接入状态管理后收敛进 AppState）。
final currentTab = ValueNotifier<NavTab>(NavTab.gallery);

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.items, required this.current, required this.onSelect});

  final List<(NavTab, IconData, String)> items;
  final NavTab current;
  final ValueChanged<NavTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 208, // 固定 208px（表 4-2）
      color: AppColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
            child: Text(
              'AgentImageViewer',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textSecondary,
                    letterSpacing: 0.3,
                  ),
            ),
          ),
          for (final (tab, icon, label) in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: _NavItem(
                icon: icon,
                label: label,
                selected: tab == current,
                onTap: () => onSelect(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Material(
      color: selected ? AppColors.accent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(color: color, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: const TextStyle(color: AppColors.textSecondary)),
    );
  }
}
