import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/theme_controller.dart';

/// 设置页用的三段主题切换器
/// 用 ToggleButtons 而不是 SegmentedButton —— 后者在 Android 上渲染黑屏
class ThemeSwitcher extends StatelessWidget {
  const ThemeSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Get.find<ThemeController>();
    return Obx(() {
      final current = theme.mode.value;
      return ToggleButtons(
        isSelected: [
          current == ThemeMode.system,
          current == ThemeMode.light,
          current == ThemeMode.dark,
        ],
        onPressed: (index) {
          final modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
          theme.setMode(modes[index]);
        },
        children: const [
          Icon(Icons.brightness_auto),
          Icon(Icons.light_mode),
          Icon(Icons.dark_mode),
        ],
      );
    });
  }
}

class ColorSchemeSwitcher extends StatelessWidget {
  const ColorSchemeSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = Get.find<ThemeController>();
    return IconButton(
      icon: const Icon(Icons.color_lens_outlined),
      onPressed: () {
        themeCtrl.openColorPickerDialog();
      },
    );
  }
}
