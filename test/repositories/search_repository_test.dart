import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/search_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late SearchRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    repo = Get.find<SearchRepository>();
  }

  tearDown(teardownGetX);

  group('search', () {
    test('把 keywords / type / limit 传给上游', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{'songs': <Object?>[]},
        }),
      );

      await repo.search(keywords: '周杰伦', type: SearchType.song, limit: 5);

      expect(api.calls.single.method, 'search');
      expect(api.calls.single.params, <Object?>['周杰伦', '1', '5']);
    });

    test('四种 type 的上游 type id 不同', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{},
        }),
      );

      await repo.search(keywords: 'x', type: SearchType.album);
      await repo.search(keywords: 'x', type: SearchType.artist);
      await repo.search(keywords: 'x', type: SearchType.playlist);

      expect(api.calls.map((c) => c.params[1]), <Object?>['10', '100', '1000']);
    });

    test('解析单曲结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{
            'songs': <Object?>[
              <String, dynamic>{
                'id': 1,
                'name': '晴天',
                'artists': <Object?>[
                  <String, dynamic>{'id': 6452, 'name': '周杰伦'},
                ],
                'album': <String, dynamic>{'id': 2, 'name': '叶惠美'},
              },
            ],
          },
        }),
      );

      final result = await repo.search(keywords: '周杰伦', type: SearchType.song);

      expect(result!.songs, hasLength(1));
      expect(result.songs!.first.title, '晴天');
      expect(result.songs!.first.artist, '周杰伦');
      expect(result.albums, isNull);
    });

    test('解析专辑结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{
            'albums': <Object?>[
              <String, dynamic>{
                'id': 3,
                'name': '范特西',
                'type': 'Album',
                'artists': <Object?>[
                  <String, dynamic>{'id': 6452, 'name': '周杰伦'},
                ],
              },
            ],
          },
        }),
      );

      final result = await repo.search(keywords: '范特西', type: SearchType.album);

      expect(result!.albums, hasLength(1));
      expect(result.albums!.first.name, '范特西');
      expect(result.albums!.first.artist, '周杰伦');
      expect(result.songs, isNull);
    });

    test('解析艺人结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{
            'artists': <Object?>[
              <String, dynamic>{'id': 6452, 'name': '周杰伦'},
            ],
          },
        }),
      );

      final result = await repo.search(
        keywords: '周杰伦',
        type: SearchType.artist,
      );

      expect(result!.artists, hasLength(1));
      expect(result.artists!.first.name, '周杰伦');
    });

    test('解析歌单结果', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{
            'playlists': <Object?>[
              <String, dynamic>{
                'id': 145022,
                'name': '华语热歌',
                'coverImgUrl': 'https://cdn/hot.jpg',
                'trackCount': 100,
                'creator': <String, dynamic>{'nickname': '官方'},
              },
            ],
          },
        }),
      );

      final result = await repo.search(
        keywords: '热歌',
        type: SearchType.playlist,
      );

      expect(result!.playlists, hasLength(1));
      expect(result.playlists!.first.name, '华语热歌');
      expect(result.playlists!.first.coverUrl, 'https://cdn/hot.jpg');
      expect(result.playlists!.first.trackCount, 100);
      expect(result.playlists!.first.creatorName, '官方');
    });

    test('result 字段缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.search(keywords: 'x', type: SearchType.song), isNull);
    });

    test('result 里没有对应类型的数组时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{'albums': <Object?>[]},
        }),
      );

      expect(await repo.search(keywords: 'x', type: SearchType.song), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.search(keywords: 'x', type: SearchType.song), isNull);
    });
  });

  group('SearchType', () {
    test('resultKey 与上游字段名对应', () {
      expect(SearchType.song.resultKey, 'songs');
      expect(SearchType.album.resultKey, 'albums');
      expect(SearchType.artist.resultKey, 'artists');
      expect(SearchType.playlist.resultKey, 'playlists');
    });
  });
}
