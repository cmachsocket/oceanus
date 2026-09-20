import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

class ThemeController extends GetxController {
  static const _modeKey = 'themeMode';
  static const _accentKey = 'accentColor';
  static const neteaseRed = Color(0xFFEC4141);

  final _box = GetStorage();

  late final Rx<ThemeMode> mode;
  late final Rx<Color> accent;

  @override
  void onInit() {
    super.onInit();

    // 亮暗模式：存 name（String），读回来还原
    final savedMode = _box.read<String>(_modeKey);
    mode =
        (savedMode == null
                ? ThemeMode.system
                : ThemeMode.values.firstWhere(
                    (e) => e.name == savedMode,
                    orElse: () => ThemeMode.system,
                  ))
            .obs;

    // 强调色：存 int（ARGB），读回来还原成 Color
    final savedArgb = _box.read<int>(_accentKey);
    accent = (savedArgb != null ? Color(savedArgb) : neteaseRed).obs;
  }

  // ── 亮暗模式 ────────────────────────────────────────────

  Future<void> setMode(ThemeMode m) async {
    if (mode.value == m) return;
    mode.value = m;
    await _box.write(_modeKey, m.name);
    Get.changeThemeMode(m); // 切换 theme / darkTheme 的选择
  }

  // ── 强调色 ─────────────────────────────────────────────

  /// 用户确认选色：持久化 + 换肤
  Future<void> setAccent(Color c) async {
    accent.value = c;
    await _box.write(_accentKey, c.toARGB32()); // Flutter <3.27 用 c.value
  }

  /// 对话框实时预览：只改内存，不写 storage
  void setAccentPreview(Color c) {
    if (accent.value == c) return;
    accent.value = c;
  }

  ThemeData get lightTheme => FlexThemeData.light(
    keyColors: FlexKeyColors(keyPrimary: accent.value),
    appBarStyle: FlexAppBarStyle.background,
  );
  ThemeData get darkTheme => FlexThemeData.dark(
    keyColors: FlexKeyColors(keyPrimary: accent.value),
    appBarStyle: FlexAppBarStyle.background,
  );

  /// 注意：不重建 App，只替换 ThemeData，导航栈保留。

  // ── 颜色选择对话框 ─────────────────────────────────────

  Future<void> openColorPickerDialog() async {
    final original = accent.value;
    Color picked = original;

    final confirmed =
        await ColorPicker(
          color: original,
          enableTonalPalette: true,
          pickersEnabled: const <ColorPickerType, bool>{
            ColorPickerType.accent: true,
            ColorPickerType.wheel: true,
          },
          customColorSwatchesAndNames: {
            ColorTools.createPrimarySwatch(const Color(0xFFEC4141)): '网易红',
          },
          showColorCode: true,
          showRecentColors: true,
          onColorChanged: (Color color) {
            picked = color;
            setAccentPreview(color); // 实时预览
          },
        ).showPickerDialog(
          Get.context!,
          // constraints: const BoxConstraints(
          //   minHeight: 460,
          //   minWidth: 300,
          //   maxWidth: 320,
          // ),
        );

    if (confirmed) {
      await setAccent(picked); // 确定：持久化
    } else {
      setAccentPreview(original); // 取消：回滚
    }
  }
}

class ThemeBinding extends Bindings {
  @override
  void dependencies() => Get.lazyPut(() => ThemeController());
}
