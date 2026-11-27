import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// 三档配色：护眼（浅绿，当前默认）、纯白（最早的版本）、深色。
enum AppThemeMode { eyeCare, pureWhite, dark }

/// 一整套语义色。页面里不再写死色值，全部从这里取，切换主题时整体替换。
class Palette {
  const Palette({
    required this.scaffold,
    required this.card,
    required this.cardAlt,
    required this.primary,
    required this.primaryDeep,
    required this.onPrimary,
    required this.title,
    required this.body,
    required this.muted,
    required this.faint,
    required this.accentSoft,
    required this.border,
    required this.chip,
    required this.chipAlt,
    required this.danger,
    required this.dangerBg,
    required this.warn,
    required this.warnDeep,
    required this.warnDeep2,
    required this.isDark,
  });

  final Color scaffold; // 页面底色
  final Color card; // 卡片、输入框底
  final Color cardAlt; // 更淡的填充底
  final Color primary; // 主色
  final Color primaryDeep; // 主色的深一档
  final Color onPrimary; // 主色底上的文字
  final Color title; // 标题、大数字
  final Color body; // 正文
  final Color muted; // 次要说明
  final Color faint; // 最弱的提示、图标
  final Color accentSoft; // 浅主色底（标签、选中态）
  final Color border; // 分割线、描边
  final Color chip; // 输入框、提示条底色
  final Color chipAlt; // 换一档的浅底（释义块等）
  final Color danger; // 忘记、错误
  final Color dangerBg; // 危险提示底
  final Color warn; // 模糊、警告
  final Color warnDeep; // 警告深一档
  final Color warnDeep2; // 警告深一档（词形提示）
  final bool isDark;
}

const Palette _eyeCare = Palette(
  scaffold: Color(0xFFF2F9F4),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFF8FCF9),
  primary: Color(0xFF3A9D6E),
  primaryDeep: Color(0xFF2E7D32),
  onPrimary: Color(0xFFFFFFFF),
  title: Color(0xFF20302A),
  body: Color(0xFF52655B),
  muted: Color(0xFF66796F),
  faint: Color(0xFF93A79B),
  accentSoft: Color(0xFFBFE6CF),
  border: Color(0xFFDEEDE4),
  chip: Color(0xFFEAF7EF),
  chipAlt: Color(0xFFF0F7F2),
  danger: Color(0xFFB91C1C),
  dangerBg: Color(0xFFFEF2F2),
  warn: Color(0xFFB45309),
  warnDeep: Color(0xFF92400E),
  warnDeep2: Color(0xFF9A3412),
  isDark: false,
);

const Palette _pureWhite = Palette(
  scaffold: Color(0xFFF6F7F9),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFF9FAFB),
  primary: Color(0xFF0F766E),
  primaryDeep: Color(0xFF166534),
  onPrimary: Color(0xFFFFFFFF),
  title: Color(0xFF1F2937),
  body: Color(0xFF4B5563),
  muted: Color(0xFF6B7280),
  faint: Color(0xFF9CA3AF),
  accentSoft: Color(0xFF99F6E4),
  border: Color(0xFFE5E7EB),
  chip: Color(0xFFF0FDF4),
  chipAlt: Color(0xFFF3F4F6),
  danger: Color(0xFFB91C1C),
  dangerBg: Color(0xFFFEF2F2),
  warn: Color(0xFFB45309),
  warnDeep: Color(0xFF92400E),
  warnDeep2: Color(0xFF9A3412),
  isDark: false,
);

// 深色档：底色走中性黑灰，只有主色保留品牌绿。早先按「墨绿 + 深灰绿」配，
// 大面积上了一层黄绿色相，屏幕上看起来整片泛绿光，改成纯黑 + 白字。
const Palette _dark = Palette(
  scaffold: Color(0xFF000000),
  card: Color(0xFF121212),
  cardAlt: Color(0xFF1C1C1C),
  primary: Color(0xFF4ED69B),
  primaryDeep: Color(0xFF8CE9BC),
  onPrimary: Color(0xFF06110B),
  title: Color(0xFFFFFFFF),
  body: Color(0xFFE6E6E6),
  muted: Color(0xFFA6A6A6),
  faint: Color(0xFF6E6E6E),
  accentSoft: Color(0xFF1F3A2C),
  border: Color(0xFF2B2B2B),
  chip: Color(0xFF1A1A1A),
  chipAlt: Color(0xFF151515),
  danger: Color(0xFFFF6B6B),
  dangerBg: Color(0xFF2A1212),
  warn: Color(0xFFFFB05C),
  warnDeep: Color(0xFFFFC98A),
  warnDeep2: Color(0xFFFFC07A),
  isDark: true,
);

/// 三档色板。做成常量表，避免每次取用时新建 Map。
const Map<AppThemeMode, Palette> palettes = {
  AppThemeMode.eyeCare: _eyeCare,
  AppThemeMode.pureWhite: _pureWhite,
  AppThemeMode.dark: _dark,
};

/// 当前生效的色板。页面直接读 P.xxx，切换时整体替换后重建。
class P {
  static Palette _current = _eyeCare;

  static Color get scaffold => _current.scaffold;
  static Color get card => _current.card;
  static Color get cardAlt => _current.cardAlt;
  static Color get primary => _current.primary;
  static Color get primaryDeep => _current.primaryDeep;
  static Color get onPrimary => _current.onPrimary;
  static Color get title => _current.title;
  static Color get body => _current.body;
  static Color get muted => _current.muted;
  static Color get faint => _current.faint;
  static Color get accentSoft => _current.accentSoft;
  static Color get border => _current.border;
  static Color get chip => _current.chip;
  static Color get chipAlt => _current.chipAlt;
  static Color get danger => _current.danger;
  static Color get dangerBg => _current.dangerBg;
  static Color get warn => _current.warn;
  static Color get warnDeep => _current.warnDeep;
  static Color get warnDeep2 => _current.warnDeep2;
  static bool get isDark => _current.isDark;

  static void apply(AppThemeMode mode) {
    _current = palettes[mode] ?? _eyeCare;
  }
}

/// 主题状态：记住用户的选择，并通知界面重建。
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const String _metaKey = 'theme_mode';

  AppThemeMode _mode = AppThemeMode.eyeCare;
  AppThemeMode get mode => _mode;

  /// 启动时读回上次选择；库还没开好或没存过就保持默认的护眼。
  Future<void> load() async {
    try {
      final raw = await Api.instance.metaGet(_metaKey);
      final mode = AppThemeMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => AppThemeMode.eyeCare,
      );
      if (mode != _mode) {
        _mode = mode;
        P.apply(mode);
        notifyListeners();
      }
    } catch (_) {
      // 读不到就用默认值，不影响启动
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    P.apply(mode);
    notifyListeners();
    try {
      await Api.instance.metaSet(_metaKey, mode.name);
    } catch (_) {
      // 存失败只影响下次启动的默认值，不打扰用户
    }
  }
}

/// 各档的显示名、一句说明、图标，给切换按钮和选择弹窗用。
String themeLabel(AppThemeMode m) => switch (m) {
      AppThemeMode.eyeCare => '护眼',
      AppThemeMode.pureWhite => '纯白',
      AppThemeMode.dark => '深色',
    };

String themeHint(AppThemeMode m) => switch (m) {
      AppThemeMode.eyeCare => '浅绿底，长时间看眼不累',
      AppThemeMode.pureWhite => '白底深墨绿，最早的版本配色',
      AppThemeMode.dark => '纯黑底白字，晚上关灯也能看清',
    };

IconData themeIcon(AppThemeMode m) => switch (m) {
      AppThemeMode.eyeCare => Icons.spa_outlined,
      AppThemeMode.pureWhite => Icons.light_mode_outlined,
      AppThemeMode.dark => Icons.dark_mode_outlined,
    };

/// 由当前色板生成 ThemeData，Material 组件（AppBar、导航栏、弹窗）跟着走。
ThemeData buildAppTheme() {
  final dark = P.isDark;
  var scheme = ColorScheme.fromSeed(
    seedColor: P.primary,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: P.primary,
    onPrimary: P.onPrimary,
    surface: P.scaffold,
    onSurface: P.body,
    error: P.danger,
  );
  // fromSeed 会按种子色算出整套带绿的容器色，深色档整片泛绿就是它。
  // 容器层全换成中性灰，绿色只留在主色上。
  if (dark) {
    scheme = scheme.copyWith(
      surfaceContainerLowest: const Color(0xFF0A0A0A),
      surfaceContainerLow: const Color(0xFF101010),
      surfaceContainer: const Color(0xFF161616),
      surfaceContainerHigh: const Color(0xFF1C1C1C),
      surfaceContainerHighest: const Color(0xFF242424),
      secondaryContainer: const Color(0xFF232323),
      onSecondaryContainer: const Color(0xFFE6E6E6),
    );
  }

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: P.scaffold,
    canvasColor: P.scaffold,
    cardColor: P.card,
    dividerColor: P.border,
    hintColor: P.faint,
    appBarTheme: AppBarTheme(
      elevation: 0,
      backgroundColor: P.scaffold,
      foregroundColor: P.title,
      surfaceTintColor: Colors.transparent,
      // 深色档要给系统状态栏换成浅色图标，否则白底深图标压在近黑底上看不见
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(color: P.title, fontSize: 20, fontWeight: FontWeight.w700),
      iconTheme: IconThemeData(color: P.title),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: P.card,
      indicatorColor: P.accentSoft,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected) ? P.primary : P.muted,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? P.primary : P.muted,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: P.cardAlt,
      hintStyle: TextStyle(color: P.faint),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    textTheme: Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(bodyColor: P.body, displayColor: P.title),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: P.primary,
      // 深色档 accentSoft 是暗绿，做选区底色在纯黑上看不出来，统一用主色半透明
      selectionColor: dark ? P.primary.withValues(alpha: 0.28) : P.accentSoft,
      selectionHandleColor: P.primary,
    ),
    dividerTheme: DividerThemeData(color: P.border, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: P.title,
      contentTextStyle: TextStyle(color: P.card),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: P.card,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(color: P.title, fontSize: 18, fontWeight: FontWeight.w700),
      contentTextStyle: TextStyle(color: P.body, fontSize: 14),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: P.card,
      surfaceTintColor: Colors.transparent,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: P.primary,
      foregroundColor: P.onPrimary,
    ),
  );
}
