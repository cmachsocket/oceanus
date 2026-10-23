import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/services/local_redirect_server.dart';
import 'package:oceanus/services/repositories/song_repository.dart';

import '../helpers/test_env.dart';

void main() {
  late FakeNeteaseApi api;
  late LocalRedirectServer server;

  setUpAll(() {
    // flutter_test 默认把 HttpClient 换成永远返回 400 的假实现(免得单元测试
    // 碰真网络)。这个用例要的就是本机 socket,得先把假实现摘掉。
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
  });

  Future<void> boot(
    Future<MusicResponse> Function(String method, List<Object?> params) onCall,
  ) async {
    api = await bootstrapGetX(onCall: onCall);
    server = LocalRedirectServer(Get.find<SongRepository>());
    await server.init();
  }

  tearDown(() {
    server.onClose();
    teardownGetX();
  });

  /// 不跟随重定向地发一个 GET,返回响应。
  Future<HttpClientResponse> get(Uri uri) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      return await req.close();
    } finally {
      client.close(force: true);
    }
  }

  group('init', () {
    test('起来之后 enabled 为 true,baseUrl 指向本机端口', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      expect(server.enabled, isTrue);
      expect(server.baseUrl, startsWith('http://localhost:'));
    });
  });

  group('urlFor', () {
    test('路径形如 /s/<songId>/<songId>.mp3,带上音质参数', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      final uri = server.urlFor(songId: '123', quality: 'standard');

      expect(uri.path, '/s/123/123.mp3');
      expect(uri.queryParameters['q'], 'standard');
      // port=0 表示随机端口,实际端口写在 URL 里
      expect(uri.port, isNot(0));
      expect(server.baseUrl, contains(':${uri.port}'));
    });

    test('无损音质用 flac 扩展名', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      expect(
        server.urlFor(songId: '1', quality: 'lossless').path,
        '/s/1/1.flac',
      );
      expect(server.urlFor(songId: '1', quality: 'hires').path, '/s/1/1.flac');
    });

    test('音质为空时回落到 standard', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      final uri = server.urlFor(songId: '1', quality: '');

      expect(uri.queryParameters['q'], 'standard');
      expect(uri.path, '/s/1/1.mp3');
    });
  });

  group('HTTP 处理', () {
    test('命中 /s/<id>/ 时 302 到真实地址', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 123, 'url': 'https://cdn/123.mp3'},
          ],
        }),
      );

      final res = await get(server.urlFor(songId: '123', quality: 'standard'));

      expect(res.statusCode, HttpStatus.movedTemporarily);
      expect(
        res.headers.value(HttpHeaders.locationHeader),
        'https://cdn/123.mp3',
      );
    });

    test('不是 /s/ 开头的路径返回 404', () async {
      await boot((method, params) async => jsonResponse(<String, dynamic>{}));

      final res = await get(Uri.parse('${server.baseUrl}/whatever'));

      expect(res.statusCode, HttpStatus.notFound);
    });

    test('取不到播放地址时返回 404', () async {
      await boot(
        (method, params) async =>
            jsonResponse(<String, dynamic>{'code': 200, 'data': <Object?>[]}),
      );

      final res = await get(server.urlFor(songId: '404', quality: 'standard'));

      expect(res.statusCode, HttpStatus.notFound);
    });

    test('同一首歌的重复请求只问上游一次(有 TTL 缓存)', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 123, 'url': 'https://cdn/123.mp3'},
          ],
        }),
      );

      final uri = server.urlFor(songId: '123', quality: 'standard');
      await get(uri);
      await get(uri);

      expect(api.calls.where((c) => c.method == 'song_url_v1'), hasLength(1));
    });

    test('不同音质算不同的缓存 key', () async {
      await boot(
        (method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'data': <Object?>[
            <String, dynamic>{'id': 123, 'url': 'https://cdn/123.mp3'},
          ],
        }),
      );

      await get(server.urlFor(songId: '123', quality: 'standard'));
      await get(server.urlFor(songId: '123', quality: 'lossless'));

      expect(api.calls.where((c) => c.method == 'song_url_v1'), hasLength(2));
    });
  });
}
