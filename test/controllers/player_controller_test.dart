import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:oceanus/PlayPage/player_controller.dart';
import 'package:oceanus/models/snapshot.dart';
import 'package:oceanus/models/song.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeAudioPlayerService audio;
  late PlayerController controller;

  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    coverUrl: '',
    duration: Duration(minutes: 3, seconds: 5),
  );

  PlaybackSnapshot snapshot({
    bool isPlaying = false,
    Duration position = Duration.zero,
    Duration bufferedPosition = Duration.zero,
    Song? currentSong,
    int currentIndex = -1,
    PlayOrder playOrder = PlayOrder.sequential,
    bool isCurrentSongLiked = false,
  }) {
    return PlaybackSnapshot(
      isPlaying: isPlaying,
      processingState: ProcessingState.idle,
      position: position,
      bufferedPosition: bufferedPosition,
      currentSong: currentSong,
      queue: const [],
      currentIndex: currentIndex,
      playOrder: playOrder,
      isCurrentSongLiked: isCurrentSongLiked,
    );
  }

  Future<void> boot() async {
    await bootstrapGetX();
    audio = FakeAudioPlayerService();
    Get.put<AudioPlayerService>(audio, permanent: true);
    controller = Get.put<PlayerController>(PlayerController(), permanent: true);
  }

  tearDown(teardownGetX);

  group('镜像 snapshot', () {
    test('初始状态是空的', () async {
      await boot();

      expect(controller.isPlaying.value, isFalse);
      expect(controller.position.value, Duration.zero);
      expect(controller.buffered.value, Duration.zero);
      expect(controller.currentSong.value, isNull);
      expect(controller.isLiked.value, isFalse);
      expect(controller.duration.value, Duration.zero);
    });

    test('snapshot 变化时同步到 UI 字段', () async {
      await boot();

      audio.snapshot.value = snapshot(
        isPlaying: true,
        position: const Duration(seconds: 42),
        bufferedPosition: const Duration(seconds: 50),
        currentSong: song,
        isCurrentSongLiked: true,
      );

      expect(controller.isPlaying.value, isTrue);
      expect(controller.position.value, const Duration(seconds: 42));
      expect(controller.buffered.value, const Duration(seconds: 50));
      expect(controller.currentSong.value, song);
      expect(controller.isLiked.value, isTrue);
    });

    test('duration 取当前歌曲的时长', () async {
      await boot();

      audio.snapshot.value = snapshot(currentSong: song);

      expect(controller.duration.value, const Duration(minutes: 3, seconds: 5));
    });

    test('没有当前歌曲时退回用队列里的占位时长', () async {
      await boot();
      audio.playlist.assignAll(<Song>[song]);
      audio.currentIndex.value = 0;

      audio.snapshot.value = snapshot();

      expect(controller.duration.value, const Duration(minutes: 3, seconds: 5));
    });

    test('队列为空且没有当前歌曲时时长归零', () async {
      await boot();

      audio.snapshot.value = snapshot();

      expect(controller.duration.value, Duration.zero);
    });
  });

  group('center 页切换', () {
    test('cover / lyric 来回切', () async {
      await boot();

      expect(controller.center.value, CenterPage.cover);
      controller.switchPage();
      expect(controller.center.value, CenterPage.lyric);
      controller.switchPage();
      expect(controller.center.value, CenterPage.cover);
    });
  });

  group('命令转发', () {
    test('togglePlay 按当前状态决定 play / pause', () async {
      await boot();

      controller.togglePlay();
      expect(audio.commands.single, 'play');

      audio.snapshot.value = snapshot(isPlaying: true);
      controller.togglePlay();
      expect(audio.commands.last, 'pause');
    });

    test('next / prev / selectIndex 转发给 wrapper', () async {
      await boot();

      controller.next();
      controller.prev();
      controller.selectIndex(2);

      expect(audio.commands, <String>[
        'skipToNext',
        'skipToPrevious',
        'selectIndex:2',
      ]);
    });

    test('seek 转发给 wrapper', () async {
      await boot();

      controller.seek(const Duration(seconds: 30));

      expect(audio.commands.single, 'seek:0:00:30.000000');
    });
  });

  group('toggleFavorite', () {
    test('没有当前歌曲时什么都不做', () async {
      await boot();

      controller.toggleFavorite();

      expect(audio.commands, isEmpty);
    });

    test('有当前歌曲时转发 songId', () async {
      await boot();
      audio.snapshot.value = snapshot(currentSong: song);

      controller.toggleFavorite();

      expect(audio.commands.single, 'toggleFavorite:1');
    });
  });
}
