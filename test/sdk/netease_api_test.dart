import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/sdk/netease_api.dart';

void main() {
  group('NeteaseApi.parseCookieString', () {
    test('解析出身份 cookie', () {
      final cookies = NeteaseApi.parseCookieString(
        'MUSIC_U=abc123; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
      );

      expect(cookies['MUSIC_U'], 'abc123');
    });

    test('跳过 Path / Expires / HttpOnly 等非身份字段', () {
      final cookies = NeteaseApi.parseCookieString(
        'MUSIC_U=abc; Path=/; Expires=Thu; HttpOnly; SameSite=None; Max-Age=3600',
      );

      expect(cookies.keys, <String>['MUSIC_U']);
    });

    test('小写开头的键不是网易云的身份 cookie,被跳过', () {
      final cookies = NeteaseApi.parseCookieString(
        'music_u=abc; os=1; MUSIC_U=real',
      );

      expect(cookies['MUSIC_U'], 'real');
      expect(cookies.containsKey('os'), isFalse);
    });

    test('多条 cookie 都被解析', () {
      final cookies = NeteaseApi.parseCookieString(
        'MUSIC_U=abc; Path=/;, __csrf=xyz; Path=/;',
      );

      expect(cookies['MUSIC_U'], 'abc');
      expect(cookies['__csrf'], 'xyz');
    });

    test('空串返回空 map', () {
      expect(NeteaseApi.parseCookieString(''), isEmpty);
    });

    test('没有 "=" 的片段被跳过', () {
      final cookies = NeteaseApi.parseCookieString('garbage; MUSIC_U=abc');

      expect(cookies.length, 1);
      expect(cookies['MUSIC_U'], 'abc');
    });

    test('值里的 "=" 不被截断', () {
      final cookies = NeteaseApi.parseCookieString('MUSIC_U=ab=cd==');

      expect(cookies['MUSIC_U'], 'ab=cd==');
    });

    test('键首尾的非字母数字被剥掉', () {
      final cookies = NeteaseApi.parseCookieString('__cf_bm=xyz');

      expect(cookies['__cf_bm'], 'xyz');
    });
  });
}
