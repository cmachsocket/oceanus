import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/album_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late AlbumRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    await bootstrapGetX(onCall: onCall);
    repo = Get.find<AlbumRepository>();
  }

  tearDown(teardownGetX);

  group('fetch', () {
    test('一次拿到元信息 + 全部曲目', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'album': <String, dynamic>{
            'name': '范特西',
            'picUrl': 'https://cdn/fantasy.jpg',
            'description': '简介',
          },
          'songs': <Object?>[
            <String, dynamic>{
              'id': 1,
              'name': '爱在西元前',
              'ar': <Object?>[
                <String, dynamic>{'id': 6452, 'name': '周杰伦'},
              ],
            },
          ],
        }),
      );

      final content = await repo.fetch('32311');

      expect(content!.name, '范特西');
      expect(content.coverUrl, 'https://cdn/fantasy.jpg');
      expect(content.description, '简介');
      expect(content.songs, hasLength(1));
      expect(content.songs.first.title, '爱在西元前');
    });

    test('songs 缺失时曲目为空列表,元信息照常返回', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'album': <String, dynamic>{'name': '范特西'},
        }),
      );

      final content = await repo.fetch('32311');

      expect(content!.songs, isEmpty);
      expect(content.name, '范特西');
    });

    test('album 字段缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetch('32311'), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetch('32311'), isNull);
    });
  });
}
