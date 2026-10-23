import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/sdk/netease_api.dart';
import 'package:oceanus/services/app_shutdown.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';
import 'package:oceanus/services/local_redirect_server.dart';
import 'package:oceanus/services/lyrics_server_service.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeAudioPlayerService audio;

  setUp(() async {
    AppShutdown.resetForTest();
    await bootstrapGetX();
    audio = FakeAudioPlayerService();
    Get.put<AudioPlayerService>(audio, permanent: true);
  });

  tearDown(() {
    AppShutdown.resetForTest();
    teardownGetX();
  });

  group('run', () {
    test('释放音频层与 node bridge', () async {
      await AppShutdown.run();

      expect(audio.commands, contains('shutdown'));
      // NeteaseApi.shutdown 是幂等的:再调一次会直接复用已完成的 future。
      await expectLater(Get.find<NeteaseApi>().shutdown(), completes);
    });

    test('注销本机 HTTP server(已注册时)', () async {
      Get.put<LocalRedirectServer>(
        LocalRedirectServer(Get.find()),
        permanent: true,
      );
      Get.put<LyricsServerService>(LyricsServerService(), permanent: true);

      await AppShutdown.run();

      expect(Get.isRegistered<LocalRedirectServer>(), isFalse);
      expect(Get.isRegistered<LyricsServerService>(), isFalse);
    });

    test('幂等:重复调用只收尾一次', () async {
      final first = AppShutdown.run();
      final second = AppShutdown.run();

      await Future.wait([first, second]);

      expect(audio.commands.where((c) => c == 'shutdown'), hasLength(1));
    });

    test('音频层之外的服务缺失时也能跑完', () async {
      Get.delete<AudioPlayerService>(force: true);
      await expectLater(AppShutdown.run(), completes);
    });
  });
}
