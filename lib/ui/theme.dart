/// 深色主题（设计书 4.1 节表 4-1 色板）。
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  static const mainBg = Color(0xFF14161A); // 主背景
  static const panel = Color(0xFF1D2026); // 面板/卡片
  static const overlay = Color(0xFF16181D); // 悬浮层（半透明用 withValues）
  static const textPrimary = Color(0xFFE8EAED);
  static const textSecondary = Color(0xFF9AA0A6);
  static const accent = Color(0xFF4C9BE8); // 强调色
  static const aiAccent = Color(0xFF8B7CF6); // AI 专属
  static const danger = Color(0xFFE5615C);
}

abstract final class AppTheme {
  static const motionDuration = Duration(milliseconds: 160); // 120~200ms 区间
  static const curve = Curves.easeOut;

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.mainBg,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        secondary: AppColors.aiAccent,
        error: AppColors.danger,
        surface: AppColors.panel,
        onSurface: AppColors.textPrimary,
        surfaceContainerHighest: AppColors.panel,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      dividerColor: Colors.white.withValues(alpha: 0.08),
      cardTheme: CardThemeData(
        color: AppColors.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
