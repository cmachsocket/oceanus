import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/artist_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late ArtistRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    await bootstrapGetX(onCall: onCall);
    repo = Get.find<ArtistRepository>();
  }

  tearDown(teardownGetX);

  group('fetchArtist', () {
    test('解析艺人信息 + 关注状态', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{
            'id': 6452,
            'name': '周杰伦',
            'briefDesc': '简介',
            'picUrl': 'https://cdn/jay.jpg',
            'followed': true,
          },
        }),
      );

      final info = await repo.fetchArtist('6452');

      expect(info!.artist.name, '周杰伦');
      expect(info.artist.bio, '简介');
      expect(info.followed, isTrue);
    });

    test('followed 字段缺失时是 null 而不是 false', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{'id': 6452, 'name': '周杰伦'},
        }),
      );

      expect((await repo.fetchArtist('6452'))!.followed, isNull);
    });

    test('artist 字段缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchArtist('6452'), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchArtist('6452'), isNull);
    });
  });

  group('fetchAlbums', () {
    test('解析 hotAlbums', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'hotAlbums': <Object?>[
            <String, dynamic>{'id': 1, 'name': '范特西', 'type': 'Album'},
          ],
        }),
      );

      final albums = await repo.fetchAlbums('6452');

      expect(albums, hasLength(1));
      expect(albums.first.name, '范特西');
    });

    test('albums 字段也能解析', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'albums': <Object?>[
            <String, dynamic>{'id': 1, 'name': '范特西'},
          ],
        }),
      );

      expect(await repo.fetchAlbums('6452'), hasLength(1));
    });

    test('列表缺失时返回空列表', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchAlbums('6452'), isEmpty);
    });
  });

  group('fetchSongs', () {
    test('默认 limit 是 50', () async {
      final api = await bootstrapGetX(
        onCall: (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'songs': <Object?>[]}),
      );
      repo = Get.find<ArtistRepository>();

      await repo.fetchSongs('6452');

      expect(api.calls.single.method, 'artist_songs');
      expect(api.calls.single.params, <Object?>['6452', '50']);
    });

    test('可以覆盖 limit', () async {
      final api = await bootstrapGetX(
        onCall: (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'songs': <Object?>[]}),
      );
      repo = Get.find<ArtistRepository>();

      await repo.fetchSongs('6452', limit: 10);

      expect(api.calls.single.params, <Object?>['6452', '10']);
    });

    test('解析歌曲列表', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'songs': <Object?>[
            <String, dynamic>{'id': 1, 'name': '晴天'},
          ],
        }),
      );

      final songs = await repo.fetchSongs('6452');

      expect(songs, hasLength(1));
      expect(songs.first.title, '晴天');
    });

    test('上游报错时返回空列表', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchSongs('6452'), isEmpty);
    });
  });
}
