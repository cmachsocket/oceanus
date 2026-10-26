import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/modules/player/controllers/lyrics_controller.dart';
import 'package:oceanus/app/data/models/lyrics.dart';
import 'package:oceanus/app/services/audio_player_wrapper.dart';

import '../helpers/test_env.dart';

void main() {
  late LyricsController controller;

  setUp(() async {
    // AudioPlayerService 的构造会 Get.find 一堆仓库,先把依赖图搭起来。
    await bootstrapGetX();
    Get.put<AudioPlayerService>(FakeAudioPlayerService(), permanent: true);
    controller = Get.put<LyricsController>(LyricsController(), permanent: true);
  });

  tearDown(teardownGetX);

  group('alignLyrics', () {
    test('yrc 为空时原样返回', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '   '),
        Lyrics(lrc: '[00:01.00]你好'),
      );

      expect(aligned.yrc, '   ');
    });

    test('lrc 为空时保留 yrc 自己的时间', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[2000,500](2000,500,0)你'),
        Lyrics(lrc: '  '),
      );

      expect(aligned.yrc, contains('[2000,500]'));
    });

    test('行时间被 lrc 覆写', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[2000,500](2000,500,0)你(2500,500,0)好'),
        Lyrics(lrc: '[00:01.00]你好'),
      );

      expect(aligned.yrc, contains('[1000,500]'));
    });

    test('行内逐字时间按同一个 delta 平移', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[2000,500](2000,500,0)你(2500,500,0)好'),
        Lyrics(lrc: '[00:01.00]你好'),
      );

      // 行头 2000 → 1000(delta -1000),逐字 2000/2500 → 1000/1500
      expect(aligned.yrc, contains('(1000,500,0)你(1500,500,0)好'));
    });

    test('lrc 里没有这一句时保留 yrc 的时间', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[2000,500](2000,500,0)别的'),
        Lyrics(lrc: '[00:01.00]你好'),
      );

      expect(aligned.yrc, contains('[2000,500]'));
      expect(aligned.yrc, contains('别的'));
    });

    test('副歌重复文本按出现顺序消费 lrc 的时间', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[2000,500](2000,500,0)你好\n[6000,500](6000,500,0)你好'),
        Lyrics(lrc: '[00:01.00]你好\n[00:05.00]你好'),
      );

      final lines = aligned.yrc!.trim().split('\n');
      expect(lines[0], startsWith('[1000,'));
      expect(lines[1], startsWith('[5000,'));
    });

    test('制作信息行原样透传', () {
      final meta = '{"t":0,"c":[{"tx":"作词: "},{"tx":"某"}]}';
      final aligned = controller.alignLyrics(
        Lyrics(yrc: meta),
        Lyrics(lrc: '[00:01.00]你好'),
      );

      expect(aligned.yrc, contains('作词'));
    });

    test('lrc / tlyric / romalrc 优先用 yrc 自带的', () {
      final aligned = controller.alignLyrics(
        Lyrics(
          yrc: '[1000,500](1000,500,0)你',
          lrc: 'yrc-lrc',
          tlyric: 'yrc-tlyric',
          romalrc: 'yrc-romalrc',
        ),
        Lyrics(lrc: 'lrc-lrc', tlyric: 'lrc-tlyric', romalrc: 'lrc-romalrc'),
      );

      expect(aligned.lrc, 'yrc-lrc');
      expect(aligned.tlyric, 'yrc-tlyric');
      expect(aligned.romalrc, 'yrc-romalrc');
    });

    test('yrc 没带 lrc 时用传入的 lrc 补上', () {
      final aligned = controller.alignLyrics(
        Lyrics(yrc: '[1000,500](1000,500,0)你'),
        Lyrics(lrc: 'lrc-lrc'),
      );

      expect(aligned.lrc, 'lrc-lrc');
    });
  });
}
