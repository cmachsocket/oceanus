import 'package:flutter/material.dart';
import '../PlayPage/BottomPlayer.dart';
import 'package:get/get.dart';
import 'package:responsive_builder/responsive_builder.dart';
import 'models/Default.dart';
import 'HomePage/HomePage.dart';
import 'LibraryPage/LibraryController.dart';
import 'LibraryPage/LibraryPage.dart';
import 'SettingsPage/SettingsPage.dart' show Settings, SettingsPageBinding;
import 'AppShellController.dart';
import 'searchPage/searchPage.dart';
import 'searchPage/SearchController.dart' show SearchPageBinding;

enum PageIndex { home, search, library, settings }

/// 顶层 Scaffold,IndexedStack 那一格换成 Navigator。
/// 切 tab 用 GetX:Get.to() + id 推到 shell 自己的 navigator。
/// tab 状态完全交给 GetxController(AppShellController),本类 StatelessWidget。
/// 主体布局用 responsive_builder 按屏幕宽度切 flex 值。
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  /// AppShell 这一层 Navigator 在 Get 中的 id,跟 Settings 的内嵌 id 区分
  static const int maxPageIndex = 4;
  static const int protraitFlex = 6;
  static const int landscapeFlex = 5;
  static const int bottomPlayerFlex = 1;

  /// 按 index 返回 tab 内容
  static Widget _content(PageIndex i) {
    switch (i) {
      case PageIndex.home:
        return const HomePage();
      case PageIndex.search:
        return const SearchPage();
      case PageIndex.library:
        return const LibraryPage();
      case PageIndex.settings:
        return const Settings();
    }
  }

  /// 跟 _content 对应:每个 tab 是否需要 binding。
  /// library tab 切到时才需要 LibraryController,所以用 Get.to(binding:) 按需绑定。
  /// 启动前已注入的(AppShellController / ThemeController / PlayerController)走 global,不在这里绑。
  static Bindings? _bindingForTab(PageIndex i) {
    switch (i) {
      case PageIndex.home:
        return HomePageBinding();
      case PageIndex.search:
        return SearchPageBinding();
      case PageIndex.library:
        return LibraryBinding();
      case PageIndex.settings:
        return SettingsPageBinding();
    }
  }

  /// shell 这一层的 Navigator,内容跟着 tab index 走
  static Widget _navigator(PageIndex i) {
    final key = Get.nestedKey(DefaultValues.shellNavigatorId);

    return NavigatorPopHandler(
      onPopWithResult: (result) {
        final navigator = key?.currentState;

        if (navigator != null && navigator.canPop()) {
          navigator.pop(result);
        }
      },
      child: Navigator(
        key: key,
        initialRoute: '/',
        onGenerateRoute: (settings) {
          if (settings.name == '/') {
            return GetPageRoute(
              page: () => _content(i),
              binding: _bindingForTab(i),
            );
          }
          return null;
        },
      ),
    );
  }

  /// 按屏幕朝向走不同 flex 配置
  /// - portrait:Navigator 用 Expanded 吃剩余高度,BottomPlay 自身高度
  /// - landscape:Navigator flex=4,BottomPlay flex=1(横屏播放器按比例拉大)
  static Widget _responsiveBody(PageIndex i) {
    return Column(
      children: [
        OrientationLayoutBuilder(
          portrait: (_) => Expanded(flex: protraitFlex, child: _navigator(i)),
          landscape: (_) => Expanded(flex: landscapeFlex, child: _navigator(i)),
        ),
        const Expanded(flex: bottomPlayerFlex, child: BottomPlayer()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = Get.find<AppShellController>();
    // 2026-08-25: 用 SafeArea 包 body, Flutter UI 不越过状态栏 / 底部
    // navigation bar。bottomNavigationBar 本身 Scaffold 会自动避开底部, 这里
    // 跟之前的 MainActivity.setDecorFitsSystemWindows(true) 一起确保非全屏:
    // - setDecorFitsSystemWindows: Android 不强制 edge-to-edge, 状态栏/导航栏
    //   保留系统位置
    // - SafeArea: Flutter UI 进一步避开状态栏/导航栏的高度, 避免画到系统栏下
    // top/bottom true (BottomNavigationBar 本身 Scaffold 避开 bottom, 这里
    // bottom=true 是冗余防御, 设了不出问题)。
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.zero),
      child: SafeArea(
        child: Obx(() {
          final tailOfThePage = maxPageIndex - 1;
          final i = tab.index.value.clamp(0, tailOfThePage);
          return Scaffold(
            resizeToAvoidBottomInset: false,
            body: _responsiveBody(PageIndex.values[i]),

            bottomNavigationBar: BottomNavigationBar(
              currentIndex: i,
              onTap: (j) {
                if (j == i) return;
                tab.change(j);
                // 用 GetX 的导航 API 推到 shell 自己的 navigator
                final toThePage = PageIndex.values[j.clamp(0, tailOfThePage)];
                Get.offAll(
                  //清空 navigator 栈,避免积压
                  () => _content(toThePage),
                  binding: _bindingForTab(toThePage),
                  id: DefaultValues.shellNavigatorId,
                );
              },
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.explore_outlined),
                  activeIcon: Icon(Icons.explore),
                  label: '发现',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.search_outlined),
                  activeIcon: Icon(Icons.search),
                  label: '搜索',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.library_music_outlined),
                  activeIcon: Icon(Icons.library_music),
                  label: '我的',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings_outlined),
                  activeIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
