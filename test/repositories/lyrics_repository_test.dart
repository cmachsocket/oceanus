import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/app/data/models/api_exception.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/app/data/repositories/lyrics_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late LyricsRepository repo;

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    repo = Get.find<LyricsRepository>();
  }

  tearDown(teardownGetX);

  group('fetch', () {
    test('解析 lrc / yrc / tlyric / romalrc', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
          'yrc': <String, dynamic>{'lyric': '[0,100](0,100,0)hello'},
          'tlyric': <String, dynamic>{'lyric': '[00:00.00]你好'},
          'romalrc': <String, dynamic>{'lyric': '[00:00.00]konnichiwa'},
        }),
      );

      final lyrics = await repo.fetch('123');

      expect(lyrics!.lrc, '[00:00.00]hello');
      expect(lyrics.yrc, '[0,100](0,100,0)hello');
      expect(lyrics.tlyric, '[00:00.00]你好');
      expect(lyrics.romalrc, '[00:00.00]konnichiwa');
      expect(api.calls.single.method, 'lyric_new');
    });

    test('lrc 和 yrc 都空时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '  '},
          'yrc': <String, dynamic>{'lyric': ''},
        }),
      );

      expect(await repo.fetch('123'), isNull);
    });

    test('字段缺失时返回 null', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      expect(await repo.fetch('123'), isNull);
    });

    test('上游报错时返回 null', () async {
      await boot(
        (method, params) async => throw const ApiException(500, 'boom'),
      );

      expect(await repo.fetch('123'), isNull);
    });

    test('命中缓存时不再调上游', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );

      await repo.fetch('123');
      await repo.fetch('123');

      expect(api.calls, hasLength(1));
    });

    test('没有歌词的结果不进缓存', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{'code': 200}),
      );

      await repo.fetch('123');
      await repo.fetch('123');

      expect(api.calls, hasLength(2));
    });
  });

  group('invalidate', () {
    test('清掉指定 songId 的缓存', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );

      await repo.fetch('123');
      repo.invalidate('123');
      await repo.fetch('123');

      expect(api.calls, hasLength(2));
    });

    test('不传 songId 时清掉全部缓存', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );

      await repo.fetch('123');
      await repo.fetch('456');
      repo.invalidate();
      await repo.fetch('123');
      await repo.fetch('456');

      expect(api.calls, hasLength(4));
    });

    test('清掉别的 songId 不影响当前缓存', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'lrc': <String, dynamic>{'lyric': '[00:00.00]hello'},
        }),
      );

      await repo.fetch('123');
      repo.invalidate('999');
      await repo.fetch('123');

      expect(api.calls, hasLength(1));
    });
  });
}
