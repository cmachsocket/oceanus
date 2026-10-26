import 'package:flutter/material.dart';
import '../../../../sdk/auth_controller.dart';
import 'package:get/get.dart';
import '../bindings/login_binding.dart';
import '../controllers/login_controller.dart';
import 'login_page.dart';
import '../controllers/settings_controller.dart';
import '../../../theme/widgets/theme_switcher.dart';
import '../../../core/constants/default_values.dart';
import '../widgets/quality_switcher.dart';
import 'download_page.dart';
import 'about_page.dart';

/// 设置 tab 内容(放进 app_shell 的 IndexedStack)。
/// 父级 IndexedStack 必须被 Expanded 包裹 —— 否则 Column 的主轴给的是
/// 0..Infinity,ListView 里的 RenderViewport 拿到 unbounded height 报错。
class Settings extends StatelessWidget {
  const Settings({super.key});

  /// 跳登录页入口:跟 AppShell tab 切换同款 Get.to(binding:) 模式
  static void _openLogin() => Get.to(
    () => const LoginPage(),
    binding: LoginPageBinding(),
    id: DefaultValues.shellNavigatorId,
  );

  /// 退出登录入口(已登录态才显示):走 [AuthController.logout],
  static Future<void> _doLogout() async {
    final loginCtrl = Get.isRegistered<LoginController>()
        ? Get.find<LoginController>()
        : Get.put(LoginController());
    await loginCtrl.logout();
    Get.delete<LoginController>();
    Get.snackbar('已退出', '本地登录态已清除', snackPosition: SnackPosition.BOTTOM);
  }

  @override
  Widget build(BuildContext context) {
    // 2026-08-24: 显式 Get.find<SettingsController>() 触发 lazyPut 复用检查,
    // 跟其他 tab (Home/Search/Library) 在自己的 binding 里 Get.lazyPut 的模式对齐。
    // 之前这里没有 binding, AppShell._bindingForTab(3) fallthrough 到 default
    // (HomePageBinding), 导致切到设置 tab 时 binding lifecycle 跟其他 tab 不一致,
    // 推测是 Android 16 / Flutter 3.47 上点击设置 tab 渲染 stall 到 fps=0.44 的 root cause。
    final settingsCtrl = Get.find<SettingsController>();
    return ListView(
      children: [
        const ListTile(
          leading: Icon(Icons.brightness_6_outlined),
          title: Text('主题'),
          subtitle: Text('跟随系统 / 浅色 / 深色'),
          trailing: ThemeSwitcher(),
        ),
        const ListTile(
          leading: Icon(Icons.colorize),
          title: Text('强调色'),
          subtitle: Text('自定义强调色'),
          trailing: ColorSchemeSwitcher(),
        ),
        // 登录账号:已登录 → "已登录 (退出)" / 未登录 → "登录账号"
        Obx(() {
          final auth = Get.find<AuthController>();
          return ListTile(
            leading: Icon(
              auth.loggedIn
                  ? Icons.account_circle
                  : Icons.account_circle_outlined,
            ),
            title: Text(auth.loggedIn ? '已登录' : '登录账号'),
            subtitle: Text(auth.loggedIn ? '本地登录态已保存,点击退出' : '手机号 + 验证码'),
            trailing: auth.loggedIn
                ? const Icon(Icons.logout)
                : const Icon(Icons.chevron_right),
            onTap: () => auth.loggedIn ? _doLogout() : _openLogin(),
          );
        }),
        const ListTile(
          leading: Icon(Icons.high_quality_outlined),
          title: Text('音质'),
          trailing: QualitySwitcher(),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下载模式'),
          subtitle: Text('点击进入下载详情'),
          trailing: Obx(
            () => Switch(
              value: settingsCtrl.downloadMode.value,
              onChanged: (value) async {
                settingsCtrl.downloadMode.value = value;
              },
            ),
          ),
          onTap: () => Get.to(
            () => const DownloadPage(),
            id: DefaultValues.shellNavigatorId,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.exit_to_app),
          title: const Text('窗口退出按钮'),
          subtitle: const Text('退出应用/最小化到托盘'),
          trailing: Obx(
            () => Switch(
              value: settingsCtrl.exitToTray.value,
              onChanged: settingsCtrl.setExitToTray,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('关于'),
          subtitle: const Text('版本号 / 开源协议 / 联系方式'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Get.to(
            () => const AboutPage(),
            id: DefaultValues.shellNavigatorId,
          ),
        ),
      ],
    );
  }
}
