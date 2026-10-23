import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/models/api_exception.dart';
import 'package:oceanus/models/library_summary.dart' show PlaylistSource;
import 'package:oceanus/models/song.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/SongListPage/songlist_body_controller.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late FakeAudioPlayerService audio;

  const song = Song(
    id: '1',
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    coverUrl: '',
    duration: Duration(seconds: 10),
  );

  /// 默认桩:所有端点都返回一首同名歌曲。
  Future<MusicResponse> defaultStub(String method, List<Object?> params) async {
    return jsonResponse(<String, dynamic>{
      'code': 200,
      'songs': <Object?>[
        <String, dynamic>{
          'id': 1,
          'name': '晴天',
          'ar': <Object?>[
            <String, dynamic>{'id': 6452, 'name': '周杰伦'},
          ],
        },
      ],
      'album': <String, dynamic>{
        'id': 1,
        'name': '叶惠美',
        'picUrl': 'https://cdn/1.jpg',
      },
    });
  }

  Future<SongListBodyController> boot({
    required PlaylistSource source,
    String playlistId = '123',
    void Function(SongListBodyController)? loadSongsCustom,
    Future<MusicResponse> Function(String method, List<Object?> params)? onCall,
  }) async {
    api = await bootstrapGetX(onCall: onCall ?? defaultStub);
    audio = FakeAudioPlayerService();
    Get.put<AudioPlayerService>(audio, permanent: true);
    final controller = SongListBodyController(
      playlistId: playlistId,
      source: source,
      loadSongsCustom: loadSongsCustom,
    );
    Get.put<SongListBodyController>(
      controller,
      tag: 'body-$playlistId',
      permanent: true,
    );
    await controller.ready;
    return controller;
  }

  tearDown(teardownGetX);

  group('按 source 分流', () {
    test('歌单走 playlist_track_all', () async {
      final controller = await boot(source: PlaylistSource.created);

      expect(controller.songs, hasLength(1));
      expect(controller.songs.first.title, '晴天');
      expect(api.calls.map((c) => c.method), contains('playlist_track_all'));
    });

    test('收藏的歌单同样走 playlist_track_all', () async {
      final controller = await boot(source: PlaylistSource.collected);

      expect(controller.songs, hasLength(1));
      expect(api.calls.map((c) => c.method), contains('playlist_track_all'));
    });

    test('专辑走 album', () async {
      final controller = await boot(source: PlaylistSource.album);

      expect(controller.songs, hasLength(1));
      expect(api.calls.map((c) => c.method), contains('album'));
    });

    test('艺人走 artist_songs', () async {
      final controller = await boot(source: PlaylistSource.artist);

      expect(controller.songs, hasLength(1));
      expect(api.calls.map((c) => c.method), contains('artist_songs'));
    });

    test('加载结束后 isLoading 复位', () async {
      final controller = await boot(source: PlaylistSource.created);

      expect(controller.isLoading.value, isFalse);
      expect(controller.errorMessage.value, isNull);
    });
  });

  group('loadSongsCustom', () {
    test('自定义钩子优先于默认分支', () async {
      final controller = await boot(
        source: PlaylistSource.pure,
        loadSongsCustom: (c) => c.songs.assignAll(<Song>[song]),
      );

      expect(controller.songs, hasLength(1));
      expect(api.calls, isEmpty);
    });

    test('watchExternal 把外部列表的变化同步进来', () async {
      final external = <Song>[].obs;
      final controller = await boot(
        source: PlaylistSource.pure,
        loadSongsCustom: (c) => c.watchExternal(external, c.songs),
      );

      external.assignAll(<Song>[song]);
      await Future<void>.delayed(Duration.zero);

      expect(controller.songs, hasLength(1));
    });
  });

  group('错误处理', () {
    test('拉不到专辑内容时写进 errorMessage,不往上抛', () async {
      final controller = await boot(
        source: PlaylistSource.album,
        onCall: (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(controller.errorMessage.value, '专辑内容拉取失败');
      expect(controller.isLoading.value, isFalse);
      expect(controller.songs, isEmpty);
    });

    test('上游报错被 repository 吃掉时只是空列表', () async {
      final controller = await boot(
        source: PlaylistSource.created,
        onCall: (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(controller.songs, isEmpty);
      expect(controller.errorMessage.value, isNull);
    });
  });

  group('播放', () {
    test('playAll 把整张列表交给队列', () async {
      final controller = await boot(source: PlaylistSource.created);

      await controller.playAll();

      expect(audio.commands.single, 'playSongs:1:');
    });

    test('playSong 指定起始歌曲', () async {
      final controller = await boot(source: PlaylistSource.created);

      await controller.playSong(controller.songs.first);

      expect(audio.commands.single, 'playSongs:1:1');
    });
  });
}
