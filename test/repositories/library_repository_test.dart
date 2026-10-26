import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/app/data/models/library_summary.dart'
    show PlaylistSource;
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/library_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late LibraryRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    await bootstrapGetX(onCall: onCall);
    repo = Get.find<LibraryRepository>();
  }

  tearDown(teardownGetX);

  group('fetchPersonalized', () {
    test('解析推荐歌单', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <Object?>[
            <String, dynamic>{
              'id': 145022,
              'name': '华语热歌',
              'picUrl': 'https://cdn/hot.jpg',
            },
          ],
        }),
      );

      final cards = await repo.fetchPersonalized();

      expect(cards, hasLength(1));
      expect(cards.first.name, '华语热歌');
      expect(cards.first.picUrl, 'https://cdn/hot.jpg');
    });

    test('result 缺失时返回空列表', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchPersonalized(), isEmpty);
    });
  });

  group('fetchPlaylists', () {
    test('解析我的歌单并区分自建 / 收藏', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'playlist': <Object?>[
            <String, dynamic>{
              'id': 1,
              'name': '自建',
              'coverImgUrl': 'https://cdn/a.jpg',
              'trackCount': 10,
              'subscribed': false,
            },
            <String, dynamic>{
              'id': 2,
              'name': '收藏',
              'coverImgUrl': 'https://cdn/b.jpg',
              'trackCount': 20,
              'subscribed': true,
            },
          ],
        }),
      );

      final playlists = await repo.fetchPlaylists('100');

      expect(playlists, hasLength(2));
      expect(playlists[0].source, PlaylistSource.created);
      expect(playlists[1].source, PlaylistSource.collected);
      expect(playlists[1].trackCount, 20);
    });

    test('上游报错时返回空列表', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchPlaylists('100'), isEmpty);
    });
  });

  group('fetchSubscribedAlbums', () {
    test('解析订阅专辑', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{
              'id': 1,
              'name': '五月天',
              'picUrl': 'https://cdn/a.jpg',
              'artists': <Object?>[
                <String, dynamic>{'id': 11, 'name': '五月天'},
              ],
            },
          ],
        }),
      );

      final albums = await repo.fetchSubscribedAlbums('100');

      expect(albums, hasLength(1));
      expect(albums.first.artist, '五月天');
    });
  });

  group('fetchFollowedArtists', () {
    test('解析 data.records 里的 artistInfo', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <String, dynamic>{
            'records': <Object?>[
              <String, dynamic>{
                'artistInfo': <String, dynamic>{
                  'id': 6452,
                  'name': '周杰伦',
                  'picUrl': 'https://cdn/jay.jpg',
                },
              },
            ],
          },
        }),
      );

      final artists = await repo.fetchFollowedArtists('100');

      expect(artists, hasLength(1));
      expect(artists.first.name, '周杰伦');
    });

    test('没有 artistInfo 的记录被跳过', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <String, dynamic>{
            'records': <Object?>[
              <String, dynamic>{'other': 'x'},
            ],
          },
        }),
      );

      expect(await repo.fetchFollowedArtists('100'), isEmpty);
    });
  });
}
