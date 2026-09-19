import 'package:flutter/material.dart';
import '../sdk/AuthController.dart';
import 'package:get/get.dart';
import 'LoginController.dart';
import 'LoginPage.dart';
import 'SettingsController.dart';
import '../theme/ThemeSwitcher.dart';
import '../models/Default.dart';
import 'QualitySwitcher.dart';
import 'DownloadPage.dart';

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
      ],
    );
  }
}

/// 设置 tab binding: 跟 HomePageBinding / SearchPageBinding / LibraryBinding 同款,
/// 在 AppShell._bindingForTab(3) 触发按需注入, 路由 pop 时随 binding 自动销毁。
/// 解决: 之前 _bindingForTab 对 case 3 fallthrough 到 HomePageBinding, 切到设置 tab
/// 用 Home 的 binding, lifecycle 不一致可能渲染 stall; 加这个 binding 让设置 tab
/// 有自己的 binding 生命周期, 跟其他 tab 行为统一。
class SettingsPageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<SettingsController>(() => SettingsController());
  }
}

/// 登录页 binding:跟 SearchPageBinding 同款
///
/// 由调用方在 Get.to(..., binding: LoginPageBinding()) 时按需注入
class LoginPageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<LoginController>(() => LoginController());
  }
}
