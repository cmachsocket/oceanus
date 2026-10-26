import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/liked_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late LikedRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    repo = Get.find<LikedRepository>();
  }

  tearDown(teardownGetX);

  group('fetchLikedSongIds', () {
    test('解析 body.ids 里的 int id', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'ids': <Object?>[1, 2, 3],
        }),
      );

      expect(await repo.fetchLikedSongIds('100'), <String>{'1', '2', '3'});
      expect(api.calls.single.method, 'likelist');
    });

    test('ids 缺失时返回空集合(不是 null)', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchLikedSongIds('100'), isEmpty);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchLikedSongIds('100'), isNull);
    });
  });

  group('fetchLikedAlbumIds', () {
    test('解析 body.data 里的 id', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 10},
            <String, dynamic>{'id': 20},
          ],
        }),
      );

      expect(await repo.fetchLikedAlbumIds(), <String>{'10', '20'});
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchLikedAlbumIds(), isNull);
    });
  });

  group('fetchLikedArtistIds', () {
    test('解析 body.data 里的 id', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 6452},
          ],
        }),
      );

      expect(await repo.fetchLikedArtistIds(), <String>{'6452'});
      expect(api.calls.single.method, 'artist_sublist');
    });
  });

  group('fetchLikedPlaylistIds', () {
    test('只取 subscribed=true 的歌单', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'playlist': <Object?>[
            <String, dynamic>{'id': 1, 'subscribed': true},
            <String, dynamic>{'id': 2, 'subscribed': false},
            <String, dynamic>{'id': 3, 'subscribed': true},
          ],
        }),
      );

      expect(await repo.fetchLikedPlaylistIds('100'), <String>{'1', '3'});
    });

    test('playlist 缺失时返回空集合', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchLikedPlaylistIds('100'), isEmpty);
    });
  });

  group('fetchFollowed', () {
    test('解析 body.artist.followed', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{'id': 6452, 'followed': true},
        }),
      );

      expect(await repo.fetchFollowed('6452'), isTrue);
    });

    test('followed 缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{'id': 6452},
        }),
      );

      expect(await repo.fetchFollowed('6452'), isNull);
    });

    test('artist 缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchFollowed('6452'), isNull);
    });
  });

  group('toggle 系列', () {
    test('toggleLike 用 id + like=true 调用', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.toggleLike('123', true);

      expect(api.calls.single.method, 'like');
      expect(api.calls.single.params, <Object?>['123', 'true']);
    });

    test('取消喜欢用 like=false', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.toggleLike('123', false);

      expect(api.calls.single.params, <Object?>['123', 'false']);
    });

    test('toggleAlbumSub 用 t=1 / t=0', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.toggleAlbumSub('1', true);
      await repo.toggleAlbumSub('1', false);

      expect(api.calls[0].method, 'album_sub');
      expect(api.calls[0].params, <Object?>['1', '1']);
      expect(api.calls[1].params, <Object?>['1', '0']);
    });

    test('toggleArtistSub 用 t=1 / t=0', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.toggleArtistSub('1', true);

      expect(api.calls.single.method, 'artist_sub');
      expect(api.calls.single.params, <Object?>['1', '1']);
    });

    test('togglePlaylistSubscribe 用 t=1 收藏 / t=2 取消', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.togglePlaylistSubscribe('1', true);
      await repo.togglePlaylistSubscribe('1', false);

      expect(api.calls[0].method, 'playlist_subscribe');
      expect(api.calls[0].params, <Object?>['1', '1']);
      expect(api.calls[1].params, <Object?>['2', '1']);
    });

    test('上游报错时向上抛(由调用方决定怎么提示)', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      await expectLater(
        repo.toggleLike('1', true),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
