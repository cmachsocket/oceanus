// 应用级冒烟测试:整个 app 能不能起来、四个 tab 能不能切。
//
// 之前这个文件是 Flutter 模板自带的 counter 测试(从来没通过过 —— 它 pump 的
// OceanusApp 需要 ThemeController 等一堆 GetX 依赖)。现在改成真正有意义的
// 冒烟测试:依赖用假的注册,验证 shell 能渲染 + tab 能切换。

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/PlayPage/player_controller.dart';
import 'package:oceanus/main.dart';
import 'package:oceanus/models/default.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';
import 'package:oceanus/theme/theme_controller.dart';

import 'helpers/test_env.dart';

void main() {
  // GetStorage 落盘要真实文件 IO,在 testWidgets 的 fake-async 区里等不到
  // 真实事件循环,会死锁 —— 所以放在 setUpAll(普通 test 区)里做。
  setUpAll(initTestStorage);
  setUp(clearTestStorage);
  tearDown(teardownGetX);

  Future<void> boot() async {
    await bootstrapGetX();
    Get.put<ThemeController>(ThemeController(), permanent: true);
    Get.put<AudioPlayerService>(FakeAudioPlayerService(), permanent: true);
    Get.put<PlayerController>(
      PlayerController(),
      tag: DefaultValues.playerControllerTag,
      permanent: true,
    );
  }

  testWidgets('app 能起来,底部四个 tab 都在', (tester) async {
    await boot();

    await tester.pumpWidget(const OceanusApp());
    await tester.pump();

    expect(find.text('发现'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('切到搜索 tab 能渲染搜索页', (tester) async {
    await boot();

    await tester.pumpWidget(const OceanusApp());
    await tester.pump();

    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('搜索'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到设置 tab 能渲染设置页', (tester) async {
    await boot();

    await tester.pumpWidget(const OceanusApp());
    await tester.pump();

    await tester.tap(find.text('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });
}
