import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/services/repositories/song_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late SongRepository repo;

  /// 每个用例自己 boot —— 不同用例要返回不同的上游响应。
  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    repo = Get.find<SongRepository>();
  }

  tearDown(teardownGetX);

  group('fetchSongUrls', () {
    test('按 id 拼成逗号分隔的 ids 一次性问上游', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 1, 'url': 'https://cdn/a.mp3'},
          ],
        }),
      );

      await repo.fetchSongUrls(<String>['1', '2']);

      expect(api.calls.single.method, 'song_url_v1');
      expect(api.calls.single.params.first, '1,2');
    });

    test('没显式给 level 时用全局音质设置', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'data': <Object?>[]}),
      );

      await repo.fetchSongUrls(<String>['1']);

      expect(api.calls.single.params[1], 'standard');
    });

    test('显式给的 level 覆盖全局设置', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'data': <Object?>[]}),
      );

      await repo.fetchSongUrls(<String>['1'], level: 'lossless');

      expect(api.calls.single.params[1], 'lossless');
    });

    test('返回 id → url 映射', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 1, 'url': 'https://cdn/a.mp3'},
            <String, dynamic>{'id': 2, 'url': 'https://cdn/b.mp3'},
          ],
        }),
      );

      final urls = await repo.fetchSongUrls(<String>['1', '2']);

      expect(urls, <String, String>{
        '1': 'https://cdn/a.mp3',
        '2': 'https://cdn/b.mp3',
      });
    });

    test('http 开头的地址升级成 https', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 1, 'url': 'http://cdn/a.mp3'},
          ],
        }),
      );

      final urls = await repo.fetchSongUrls(<String>['1']);

      expect(urls['1'], 'https://cdn/a.mp3');
    });

    test('取不到地址的歌(VIP / 地区限制)不进结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 1, 'url': 'https://cdn/a.mp3'},
            <String, dynamic>{'id': 2, 'url': null},
            <String, dynamic>{'id': 3, 'url': ''},
          ],
        }),
      );

      final urls = await repo.fetchSongUrls(<String>['1', '2', '3']);

      expect(urls.keys, <String>['1']);
    });

    test('空 id 列表直接返回空 map,不调上游', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      expect(await repo.fetchSongUrls(const <String>[]), isEmpty);
      expect(api.calls, isEmpty);
    });

    test('上游报错时返回空 map 而不是抛异常', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchSongUrls(<String>['1']), isEmpty);
    });

    test('data 不是 List 时返回空 map', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'data': 'oops'}),
      );

      expect(await repo.fetchSongUrls(<String>['1']), isEmpty);
    });
  });

  group('fetchSongDetails', () {
    test('返回 id → 封面 URL 映射', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'songs': <Object?>[
            <String, dynamic>{
              'id': 1,
              'al': <String, dynamic>{'picUrl': 'https://cdn/1.jpg'},
            },
            <String, dynamic>{
              'id': 2,
              'album': <String, dynamic>{'picUrl': 'https://cdn/2.jpg'},
            },
          ],
        }),
      );

      final covers = await repo.fetchSongDetails(<String>['1', '2']);

      expect(covers, <String, String>{
        '1': 'https://cdn/1.jpg',
        '2': 'https://cdn/2.jpg',
      });
    });

    test('封面为空的歌不进结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'songs': <Object?>[
            <String, dynamic>{
              'id': 1,
              'al': <String, dynamic>{'picUrl': ''},
            },
          ],
        }),
      );

      expect(await repo.fetchSongDetails(<String>['1']), isEmpty);
    });

    test('空 id 列表直接返回空 map,不调上游', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      expect(await repo.fetchSongDetails(const <String>[]), isEmpty);
      expect(api.calls, isEmpty);
    });

    test('上游报错时返回空 map', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchSongDetails(<String>['1']), isEmpty);
    });
  });

  group('fetchSongUrl', () {
    test('返回第一首的地址', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 7, 'url': 'https://cdn/7.mp3'},
          ],
        }),
      );

      expect(await repo.fetchSongUrl('7'), 'https://cdn/7.mp3');
    });

    test('取不到时返回 null', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'data': <Object?>[]}),
      );

      expect(await repo.fetchSongUrl('7'), isNull);
    });
  });
}
