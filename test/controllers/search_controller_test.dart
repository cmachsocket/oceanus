import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/modules/search/controllers/search_controller.dart';
import 'package:oceanus/app/services/audio_player_wrapper.dart';
import 'package:oceanus/app/data/repositories/search_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late SearchController controller;

  /// 默认桩:search 按请求的 type 返回对应形状的结果,song_detail 返回封面。
  Future<MusicResponse> defaultStub(String method, List<Object?> params) async {
    switch (method) {
      case 'search':
        final type = params[1];
        final key = switch (type) {
          '10' => 'albums',
          '100' => 'artists',
          '1000' => 'playlists',
          _ => 'songs',
        };
        final item = switch (key) {
          'albums' => <String, dynamic>{'id': 1, 'name': '范特西'},
          'artists' => <String, dynamic>{'id': 6452, 'name': '周杰伦'},
          'playlists' => <String, dynamic>{'id': 1, 'name': '华语热歌'},
          _ => <String, dynamic>{
            'id': 1,
            'name': '晴天',
            'artists': <Object?>[
              <String, dynamic>{'id': 6452, 'name': '周杰伦'},
            ],
          },
        };
        return jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{
            key: <Object?>[item],
          },
        });
      case 'song_detail':
        return jsonResponse(<String, dynamic>{
          'code': 200,
          'songs': <Object?>[
            <String, dynamic>{
              'id': 1,
              'al': <String, dynamic>{'picUrl': 'https://cdn/1.jpg'},
            },
          ],
        });
      default:
        return jsonResponse(<String, dynamic>{'code': 200});
    }
  }

  Future<void> boot([
    Future<MusicResponse> Function(String method, List<Object?> params)? onCall,
  ]) async {
    api = await bootstrapGetX(onCall: onCall ?? defaultStub);
    Get.put<AudioPlayerService>(FakeAudioPlayerService(), permanent: true);
    controller = Get.put<SearchController>(SearchController(), permanent: true);
  }

  tearDown(teardownGetX);

  /// [SearchController.setType] 内部触发的是不 await 的 search,这里等它跑完。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('search', () {
    test('把结果写进对应类型的列表', () async {
      await boot();

      await controller.search('周杰伦');

      expect(controller.songResults, hasLength(1));
      expect(controller.songResults.first.title, '晴天');
      expect(controller.submittedKeyword.value, '周杰伦');
      expect(controller.isLoading.value, isFalse);
    });

    test('只查当前 type,切 type 时旧结果清空', () async {
      await boot();

      await controller.search('周杰伦');
      expect(controller.songResults, isNotEmpty);

      controller.setType(SearchType.album);
      await settle();

      expect(controller.songResults, isEmpty);
      expect(controller.albumResults, hasLength(1));
      expect(controller.albumResults.first.name, '范特西');
    });

    test('关键词去空白', () async {
      await boot();

      await controller.search('  周杰伦  ');

      expect(controller.keyword.value, '周杰伦');
      expect(api.calls.first.params.first, '周杰伦');
    });

    test('空关键词直接清空,不调上游', () async {
      await boot();

      await controller.search('   ');

      expect(api.calls.where((c) => c.method == 'search'), isEmpty);
      expect(controller.submittedKeyword.value, '');
      expect(controller.songResults, isEmpty);
    });

    test('搜索时 isLoading 会在结束后复位', () async {
      await boot();

      await controller.search('周杰伦');

      expect(controller.isLoading.value, isFalse);
    });
  });

  group('setType', () {
    test('输入框有内容时自动重搜', () async {
      await boot();

      controller.setKeyword('周杰伦');
      controller.setType(SearchType.artist);
      await settle();

      final searchCalls = api.calls.where((c) => c.method == 'search');
      expect(searchCalls, isNotEmpty);
      expect(searchCalls.last.params[1], '100');
    });

    test('输入框为空时只清空,不调上游', () async {
      await boot();

      controller.setType(SearchType.artist);
      await settle();

      expect(api.calls.where((c) => c.method == 'search'), isEmpty);
    });
  });

  group('clearKeyword', () {
    test('清空输入框、提交状态和当前结果', () async {
      await boot();

      await controller.search('周杰伦');
      controller.clearKeyword();

      expect(controller.keyword.value, '');
      expect(controller.submittedKeyword.value, '');
      expect(controller.songResults, isEmpty);
    });
  });

  group('enrichSongCovers', () {
    test('用 song_detail 补回封面', () async {
      await boot();

      await controller.search('周杰伦');
      await controller.enrichSongCovers();

      expect(controller.songResults.first.coverUrl, 'https://cdn/1.jpg');
    });

    test('没有结果时什么都不做', () async {
      await boot();

      await controller.enrichSongCovers();

      expect(api.calls.where((c) => c.method == 'song_detail'), isEmpty);
    });
  });

  group('播放', () {
    test('playSong 把当前结果当队列', () async {
      await boot();
      final audio = Get.find<AudioPlayerService>() as FakeAudioPlayerService;

      await controller.search('周杰伦');
      await controller.playSong(controller.songResults.first);

      expect(audio.commands.single, 'playSongs:1:1');
    });
  });
}
