import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/SettingsPage/about_page.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUpAll(() {
    // 版本号来自平台通道,测试里用 mock 值(不在代码里写死版本)。
    PackageInfo.setMockInitialValues(
      appName: 'oceanus',
      packageName: 'oceanus',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
    );
  });

  Future<void> pumpAbout(WidgetTester tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: AboutPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('展示运行时版本号 / 开源协议 / 源码仓库 / 联系方式', (tester) async {
    await pumpAbout(tester);

    expect(find.text('关于'), findsOneWidget);
    expect(find.text('9.9.9+42'), findsOneWidget);
    expect(find.text('GNU General Public License v3.0'), findsOneWidget);
    expect(find.text(AboutPage.repositoryUrl), findsOneWidget);

    await tester.scrollUntilVisible(find.text('GitHub @cmachsocket'), 200);
    expect(find.text('GitHub @cmachsocket'), findsOneWidget);
  });

  testWidgets('点击源码仓库复制链接', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpAbout(tester);
    await tester.tap(find.text(AboutPage.repositoryUrl));
    await tester.pump();

    expect(copied, [AboutPage.repositoryUrl]);

    // 等提示条自己消失,否则测试结束时 overlay 里还挂着动画 ticker。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
