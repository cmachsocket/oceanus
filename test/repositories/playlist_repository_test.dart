import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/app/data/models/library_summary.dart'
    show PlaylistSource;
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/services/playlist_events_controller.dart';
import 'package:oceanus/app/data/repositories/playlist_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late PlaylistRepository repo;
  late PlaylistEventsController events;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    repo = Get.find<PlaylistRepository>();
    events = Get.find<PlaylistEventsController>();
  }

  tearDown(teardownGetX);

  group('fetchMeta', () {
    test('解析歌单元信息,subscribed=true 归为 collected', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'playlist': <String, dynamic>{
            'name': '华语热歌',
            'coverImgUrl': 'https://cdn/hot.jpg',
            'description': '描述',
            'subscribed': true,
          },
        }),
      );

      final meta = await repo.fetchMeta('145022');

      expect(meta!.name, '华语热歌');
      expect(meta.coverUrl, 'https://cdn/hot.jpg');
      expect(meta.description, '描述');
      expect(meta.source, PlaylistSource.collected);
    });

    test('subscribed 缺失时归为 created', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'playlist': <String, dynamic>{'name': 'x'},
        }),
      );

      expect((await repo.fetchMeta('1'))!.source, PlaylistSource.created);
    });

    test('playlist 字段缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchMeta('1'), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchMeta('1'), isNull);
    });
  });

  group('fetchTracks', () {
    test('解析曲目列表', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'songs': <Object?>[
            <String, dynamic>{
              'id': 1,
              'name': '晴天',
              'ar': <Object?>[
                <String, dynamic>{'id': 6452, 'name': '周杰伦'},
              ],
              'al': <String, dynamic>{'id': 2, 'name': '叶惠美'},
            },
          ],
        }),
      );

      final songs = await repo.fetchTracks('145022');

      expect(songs, hasLength(1));
      expect(songs.first.title, '晴天');
      expect(songs.first.artist, '周杰伦');
    });

    test('songs 字段缺失时返回空列表', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetchTracks('1'), isEmpty);
    });

    test('上游报错时返回空列表', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetchTracks('1'), isEmpty);
    });
  });

  group('createPlaylist', () {
    test('从 body.playlist.id 取新歌单 id', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'playlist': <String, dynamic>{'id': 999},
        }),
      );

      expect(await repo.createPlaylist('新歌单'), '999');
      expect(api.calls.single.method, 'playlist_create');
      expect(api.calls.single.params.first, '新歌单');
    });

    test('顶层冗余 id 也能取到', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'id': 888}),
      );

      expect(await repo.createPlaylist('x'), '888');
    });

    test('业务码非 200 时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 405}),
      );

      expect(await repo.createPlaylist('x'), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.createPlaylist('x'), isNull);
    });
  });

  group('addTracks', () {
    test('顶层 code 200 视为成功并累加 delta', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.addTracks('123', <String>['1', '2']), isTrue);
      expect(events.deltaFor('123'), 2);
    });

    test('嵌套在 body.body 的 code 200 也算成功', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'body': <String, dynamic>{'code': 200},
        }),
      );

      expect(await repo.addTracks('123', <String>['1']), isTrue);
      expect(events.deltaFor('123'), 1);
    });

    test('用 op=add / pid / tracks 三个参数调上游', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.addTracks('123', <String>['1', '2']);

      expect(api.calls.single.method, 'playlist_tracks');
      expect(api.calls.single.params, <Object?>['add', '123', '1,2']);
    });

    test('业务失败时返回 false 且不动 delta', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 400}),
      );

      expect(await repo.addTracks('123', <String>['1']), isFalse);
      expect(events.deltaFor('123'), 0);
    });

    test('空歌曲列表直接返回 false', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      expect(await repo.addTracks('123', const <String>[]), isFalse);
      expect(api.calls, isEmpty);
    });

    test('上游抛异常时返回 false', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.addTracks('123', <String>['1']), isFalse);
    });
  });

  group('removeTracks', () {
    test('成功后 delta 减少', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.removeTracks('123', <String>['1', '2']), isTrue);
      expect(events.deltaFor('123'), -2);
      expect(api.calls.single.params.first, 'del');
    });

    test('业务失败时返回 false', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 400}),
      );

      expect(await repo.removeTracks('123', <String>['1']), isFalse);
      expect(events.deltaFor('123'), 0);
    });
  });

  group('deletePlaylist', () {
    test('成功后清掉本地 delta', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      events.applyDelta('123', 5);
      expect(await repo.deletePlaylist('123'), isTrue);
      expect(events.deltaFor('123'), 0);
      expect(api.calls.single.method, 'playlist_delete');
    });

    test('业务失败时返回 false', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 400}),
      );

      expect(await repo.deletePlaylist('123'), isFalse);
    });
  });
}
