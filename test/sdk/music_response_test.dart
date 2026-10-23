import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/sdk/music_response.dart';

void main() {
  group('MusicResponse.fromNcm', () {
    test('解析上游的 status / body / cookie', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{
        'status': 200,
        'body': <String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{'songs': <Object?>[]},
        },
        'cookie': <String>['NMTID=foo; Path=/;', 'MUSIC_U=bar; Path=/;'],
      });

      expect(r.status, 200);
      expect(r.body['code'], 200);
      expect(r.cookies, contains('NMTID=foo'));
      expect(r.cookies, contains('MUSIC_U=bar'));
    });

    test('多条 cookie 用 ", " 连接', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{
        'body': <String, dynamic>{},
        'cookie': <String>['a=1', 'b=2'],
      });

      expect(r.cookies, 'a=1, b=2');
    });

    test('cookie 是 String 时原样保留', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{
        'body': <String, dynamic>{},
        'cookie': 'a=1',
      });

      expect(r.cookies, 'a=1');
    });

    test('没有 cookie 时 headers 为空,cookies 是空串', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{
        'body': <String, dynamic>{},
      });

      expect(r.headers, isEmpty);
      expect(r.cookies, '');
    });

    test('status 缺失时默认 200', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{
        'body': <String, dynamic>{},
      });

      expect(r.status, 200);
    });

    test('body 缺失时给空 map', () {
      final r = MusicResponse.fromNcm(<String, dynamic>{'status': 500});

      expect(r.body, isEmpty);
      expect(r.status, 500);
    });
  });

  group('JSON 往返', () {
    test('toJson / fromJsonString 保留 status / body / headers', () {
      final original = MusicResponse(
        status: 201,
        body: <String, dynamic>{'code': 200, 'name': 'x'},
        headers: const <String, String>{'Set-Cookie': 'a=1'},
      );

      final restored = MusicResponse.fromJsonString(original.toJsonString());

      expect(restored.status, 201);
      expect(restored.body['code'], 200);
      expect(restored.body['name'], 'x');
      expect(restored.headers['Set-Cookie'], 'a=1');
    });

    test('fromJsonString 缺字段时给默认值', () {
      final restored = MusicResponse.fromJsonString('{}');

      expect(restored.status, 200);
      expect(restored.body, isEmpty);
      expect(restored.headers, isEmpty);
    });
  });

  test('data 是 body 的别名', () {
    final r = MusicResponse(
      status: 200,
      body: <String, dynamic>{'code': 200},
      headers: const {},
    );

    expect(r.data, same(r.body));
  });

  test('toString 不泄露 body 内容', () {
    final r = MusicResponse(
      status: 200,
      body: <String, dynamic>{'code': 200, 'secret': 'value'},
      headers: const {},
    );

    expect(r.toString(), contains('status=200'));
    expect(r.toString(), isNot(contains('secret')));
  });
}
