import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:oceanus/SettingsPage/settings_controller.dart';
import 'package:oceanus/theme/theme_controller.dart';

import '../helpers/test_env.dart';

void main() {
  setUp(clearTestStorage);
  tearDown(teardownGetX);

  group('SettingsController', () {
    test('没存过时默认 standard', () async {
      await initTestStorage();
      final controller = Get.put<SettingsController>(SettingsController());

      expect(controller.currentQuality.value, Quality.standard);
    });

    test('setQuality 更新内存值并写盘', () async {
      await initTestStorage();
      final controller = Get.put<SettingsController>(SettingsController());

      await controller.setQuality(Quality.lossless);

      expect(controller.currentQuality.value, Quality.lossless);
      expect(GetStorage().read<String>('quality_v1'), 'lossless');
    });

    test('重新创建 controller 时从盘上恢复', () async {
      await initTestStorage();
      await Get.put<SettingsController>(
        SettingsController(),
      ).setQuality(Quality.hires);

      Get.delete<SettingsController>(force: true);
      final restored = Get.put<SettingsController>(SettingsController());

      expect(restored.currentQuality.value, Quality.hires);
    });

    test('盘上是陌生值时回落到 standard', () async {
      await initTestStorage();
      GetStorage().write('quality_v1', 'not_a_quality');

      final controller = Get.put<SettingsController>(SettingsController());

      expect(controller.currentQuality.value, Quality.standard);
    });

    test('downloadMode 默认关', () async {
      await initTestStorage();
      final controller = Get.put<SettingsController>(SettingsController());

      expect(controller.downloadMode.value, isFalse);
    });

    test('exitToTray 默认关', () async {
      await initTestStorage();
      final controller = Get.put<SettingsController>(SettingsController());

      expect(controller.exitToTray.value, isFalse);
    });

    test('setExitToTray 更新内存值并写盘', () async {
      await initTestStorage();
      final controller = Get.put<SettingsController>(SettingsController());

      await controller.setExitToTray(true);

      expect(controller.exitToTray.value, isTrue);
      expect(GetStorage().read<bool>('exit_to_tray_v1'), isTrue);
    });

    test('重新创建 controller 时从盘上恢复 exitToTray', () async {
      await initTestStorage();
      await Get.put<SettingsController>(
        SettingsController(),
      ).setExitToTray(true);

      Get.delete<SettingsController>(force: true);
      final restored = Get.put<SettingsController>(SettingsController());

      expect(restored.exitToTray.value, isTrue);
    });
  });

  group('ThemeController', () {
    test('默认跟随系统 + 网易红', () async {
      await initTestStorage();
      final controller = Get.put<ThemeController>(ThemeController());

      expect(controller.mode.value, ThemeMode.system);
      expect(controller.accent.value, ThemeController.neteaseRed);
    });

    test('setMode 更新内存值并写盘', () async {
      await initTestStorage();
      final controller = Get.put<ThemeController>(ThemeController());

      await controller.setMode(ThemeMode.dark);

      expect(controller.mode.value, ThemeMode.dark);
      expect(GetStorage().read<String>('themeMode'), 'dark');
    });

    test('重新创建 controller 时从盘上恢复模式', () async {
      await initTestStorage();
      await Get.put<ThemeController>(
        ThemeController(),
      ).setMode(ThemeMode.light);

      Get.delete<ThemeController>(force: true);
      final restored = Get.put<ThemeController>(ThemeController());

      expect(restored.mode.value, ThemeMode.light);
    });

    test('盘上是陌生模式时回落到 system', () async {
      await initTestStorage();
      GetStorage().write('themeMode', 'not_a_mode');

      final controller = Get.put<ThemeController>(ThemeController());

      expect(controller.mode.value, ThemeMode.system);
    });

    test('setAccent 写盘的是 ARGB 整数', () async {
      await initTestStorage();
      final controller = Get.put<ThemeController>(ThemeController());
      const green = Color(0xFF00FF00);

      await controller.setAccent(green);

      expect(controller.accent.value, green);
      expect(GetStorage().read<int>('accentColor'), green.toARGB32());
    });

    test('重新创建 controller 时从盘上恢复强调色', () async {
      await initTestStorage();
      await Get.put<ThemeController>(
        ThemeController(),
      ).setAccent(const Color(0xFF123456));

      Get.delete<ThemeController>(force: true);
      final restored = Get.put<ThemeController>(ThemeController());

      expect(restored.accent.value, const Color(0xFF123456));
    });

    test('setAccentPreview 只改内存,不写盘', () async {
      await initTestStorage();
      final controller = Get.put<ThemeController>(ThemeController());

      controller.setAccentPreview(const Color(0xFF00FF00));

      expect(controller.accent.value, const Color(0xFF00FF00));
      expect(GetStorage().read<int>('accentColor'), isNull);
    });

    test('light / dark 主题跟着强调色走', () async {
      await initTestStorage();
      final controller = Get.put<ThemeController>(ThemeController());

      final lightBefore = controller.lightTheme.colorScheme.primary;
      final darkBefore = controller.darkTheme.colorScheme.primary;

      await controller.setAccent(const Color(0xFF00FF00));

      expect(controller.lightTheme.colorScheme.primary, isNot(lightBefore));
      expect(controller.darkTheme.colorScheme.primary, isNot(darkBefore));
    });
  });
}
