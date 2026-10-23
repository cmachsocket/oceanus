import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:oceanus/models/snapshot.dart';
import 'package:oceanus/models/song.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';
import 'package:oceanus/services/lyrics_server_service.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeAudioPlayerService audio;
  late LyricsServerService server;

  const song = Song(
    id: '123',
    title: '晴天',
    artist: '周杰伦',
    artistId: '6452',
    album: '叶惠美',
    albumId: '186016',
    coverUrl: 'https://cdn/cover.jpg',
    duration: Duration(minutes: 3, seconds: 5),
  );

  setUpAll(() {
    // 这个用例要连本机 socket,先把 flutter_test 的假 HttpClient 摘掉。
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
  });

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    await bootstrapGetX(onCall: onCall);
    audio = FakeAudioPlayerService();
    Get.put<AudioPlayerService>(audio, permanent: true);
    server = LyricsServerService();
    try {
      await server.startServer();
    } on SocketException {
      // 端口被占用(本机已有实例在跑)—— 这条用例跟端口无关,跳过。
      markTestSkipped('端口 ${LyricsServerService.defaultPort} 被占用');
    }
  }

  tearDown(() {
    server.onClose();
    teardownGetX();
  });

  /// 发一个 GET 并把响应体解成 JSON。
  Future<(int, Map<String, dynamic>)> getJson(String path) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('http://localhost:${server.port}$path'),
      );
      req.followRedirects = false;
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }

  void setSnapshot({Song? currentSong, bool isPlaying = false}) {
    audio.snapshot.value = PlaybackSnapshot(
      isPlaying: isPlaying,
      processingState: ProcessingState.idle,
      position: const Duration(seconds: 30),
      bufferedPosition: Duration.zero,
      currentSong: currentSong,
      queue: const [],
      currentIndex: currentSong == null ? -1 : 0,
      playOrder: PlayOrder.sequential,
      isCurrentSongLiked: false,
    );
  }

  group('/local-asset/player', () {
    test('返回当前播放状态', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );
      setSnapshot(currentSong: song, isPlaying: true);

      final (status, body) = await getJson('/local-asset/player');

      expect(status, 200);
      expect(body['success'], isTrue);
      final data = body['data'] as Map<String, dynamic>;
      expect(data['playing'], isTrue);
      expect(data['progress'], closeTo(30.0, 0.001));
      expect((data['currentTrack'] as Map<String, dynamic>)['name'], '晴天');
      expect(data['repeatMode'], 'off');
    });

    test('currentTrack 用网易云的 schema 字段', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );
      setSnapshot(currentSong: song);

      final (_, body) = await getJson('/local-asset/player');
      final track =
          (body['data'] as Map<String, dynamic>)['currentTrack']
              as Map<String, dynamic>;

      expect(track['id'], '123');
      expect(track['name'], '晴天');
      expect((track['ar'] as List).first, <String, dynamic>{
        'id': '6452',
        'name': '周杰伦',
      });
      expect((track['al'] as Map<String, dynamic>)['name'], '叶惠美');
      expect(
        (track['al'] as Map<String, dynamic>)['picUrl'],
        'https://cdn/cover.jpg',
      );
      expect(track['dt'], song.duration.inMilliseconds);
    });

    test('歌词只保留第一个时间戳之后的部分', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{
            'lyric': '制作信息\n[00:12.00]第一句\n[00:20.00]第二句',
          },
        }),
      );
      setSnapshot(currentSong: song);

      final (_, body) = await getJson('/local-asset/player');
      final lyric =
          (body['data'] as Map<String, dynamic>)['lyric']
              as Map<String, dynamic>;

      expect(lyric['lrc'], '[00:12.00]第一句\n[00:20.00]第二句');
      expect(lyric['tlyric'], '');
      expect(lyric['romalrc'], '');
    });

    test('没有当前歌曲时 currentTrack 是空对象', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );
      setSnapshot();

      final (_, body) = await getJson('/local-asset/player');
      final data = body['data'] as Map<String, dynamic>;

      expect(data['currentTrack'], isEmpty);
      expect(data['playing'], isFalse);
    });

    test('repeatMode 按播放顺序映射', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      audio.snapshot.value = audio.snapshot.value.copyWith(
        playOrder: PlayOrder.shuffle,
      );
      var (_, body) = await getJson('/local-asset/player');
      expect((body['data'] as Map<String, dynamic>)['repeatMode'], 'list');

      audio.snapshot.value = audio.snapshot.value.copyWith(
        playOrder: PlayOrder.repeatOne,
      );
      (_, body) = await getJson('/local-asset/player');
      expect((body['data'] as Map<String, dynamic>)['repeatMode'], 'one');
    });
  });

  group('未知路径', () {
    test('返回 404 + success=false', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      final (status, body) = await getJson('/nope');

      expect(status, 404);
      expect(body['success'], isFalse);
      expect(body['message'], 'Not Found');
    });
  });
}
