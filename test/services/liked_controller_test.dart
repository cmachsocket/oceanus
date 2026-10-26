import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/services/liked_controller.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late LikedController controller;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    controller = Get.find<LikedController>();
  }

  tearDown(teardownGetX);

  group('isLiked', () {
    test('四类收藏各查各的桶', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      controller.likedSongIds.add('song-1');
      controller.likedAlbumIds.add('album-1');
      controller.likedArtistIds.add('artist-1');
      controller.likedPlaylistIds.add('playlist-1');

      expect(controller.isLiked('song-1', LikedType.song), isTrue);
      expect(controller.isLiked('album-1', LikedType.album), isTrue);
      expect(controller.isLiked('artist-1', LikedType.artist), isTrue);
      expect(controller.isLiked('playlist-1', LikedType.playlist), isTrue);

      expect(controller.isLiked('album-1', LikedType.song), isFalse);
      expect(controller.isLiked('song-1', LikedType.album), isFalse);
    });
  });

  group('toggle', () {
    test('收藏时乐观加入对应桶', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await controller.toggle('1', LikedType.song);

      expect(controller.isLiked('1', LikedType.song), isTrue);
      expect(api.calls.single.method, 'like');
      expect(api.calls.single.params, <Object?>['1', 'true']);
    });

    test('取消收藏时从桶里移除', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      controller.likedSongIds.add('1');
      await controller.toggle('1', LikedType.song);

      expect(controller.isLiked('1', LikedType.song), isFalse);
      expect(api.calls.single.params, <Object?>['1', 'false']);
    });

    test('不同类型走不同的接口', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await controller.toggle('1', LikedType.album);
      await controller.toggle('1', LikedType.artist);
      await controller.toggle('1', LikedType.playlist);

      expect(api.calls.map((c) => c.method), <String>[
        'album_sub',
        'artist_sub',
        'playlist_subscribe',
      ]);
    });
  });

  group('syncArtistLike', () {
    test('后端说已关注就把 id 加进桶', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{'id': 6452, 'followed': true},
        }),
      );

      await controller.syncArtistLike('6452');

      expect(controller.isLiked('6452', LikedType.artist), isTrue);
    });

    test('后端说没关注就把 id 移出桶', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'artist': <String, dynamic>{'id': 6452, 'followed': false},
        }),
      );

      controller.likedArtistIds.add('6452');
      await controller.syncArtistLike('6452');

      expect(controller.isLiked('6452', LikedType.artist), isFalse);
    });

    test('接口失败时保持原状', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      controller.likedArtistIds.add('6452');
      await controller.syncArtistLike('6452');

      expect(controller.isLiked('6452', LikedType.artist), isTrue);
    });
  });

  group('loadAll', () {
    test('未登录时什么都不拉', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await controller.loadAll();

      expect(api.calls, isEmpty);
    });
  });

  // 失败回滚分支会弹 snackbar。snackbar 的退场动画在单元测试里没有帧驱动,
  // 会把用例挂住,所以这条路径不在单元测试里覆盖(见 docs 的测试说明)。
}
