import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/models/api_exception.dart';
import 'package:oceanus/sdk/api_call.dart';
import 'package:oceanus/sdk/music_response.dart';

MusicResponse _res(Map<String, dynamic> body, {int status = 200}) {
  return MusicResponse(status: status, body: body, headers: const {});
}

void main() {
  group('checkResponse', () {
    test('HTTP 200 + code 200 通过', () {
      expect(
        () => checkResponse(_res(<String, dynamic>{'code': 200})),
        returnsNormally,
      );
    });

    test('HTTP 状态非 200 抛 ApiException,code = HTTP 状态', () {
      expect(
        () => checkResponse(
          _res(<String, dynamic>{'code': 200}, status: 503),
          hint: '拉歌单',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 503)
              .having((e) => e.message, 'message', contains('拉歌单'))
              .having((e) => e.message, 'message', contains('503')),
        ),
      );
    });

    test('body.code 非 200 抛 ApiException 并带上 rawBody', () {
      expect(
        () => checkResponse(
          _res(<String, dynamic>{'code': 301, 'message': '需要登录'}),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 301)
              .having((e) => e.message, 'message', contains('需要登录'))
              .having((e) => e.rawBody?['code'], 'rawBody.code', 301),
        ),
      );
    });

    test('嵌套在 body.body 里的 code 也会被检查', () {
      expect(
        () => checkResponse(
          _res(<String, dynamic>{
            'body': <String, dynamic>{'code': 400, 'msg': '参数错'},
          }),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 400)
              .having((e) => e.message, 'message', contains('参数错')),
        ),
      );
    });

    test('message 缺失时依次回退 msg / body.message / body.msg', () {
      expect(
        () => checkResponse(_res(<String, dynamic>{'code': 1, 'msg': 'M1'})),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('M1'),
          ),
        ),
      );
      expect(
        () => checkResponse(
          _res(<String, dynamic>{
            'body': <String, dynamic>{'code': 1, 'message': 'M2'},
          }),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('M2'),
          ),
        ),
      );
    });

    test('code 缺失时只看 HTTP 状态', () {
      expect(
        () => checkResponse(_res(<String, dynamic>{'result': <Object?>[]})),
        returnsNormally,
      );
    });
  });

  group('apiCall', () {
    test('成功时原样返回响应', () async {
      final r = await apiCall(
        () async => _res(<String, dynamic>{'code': 200}),
        what: '测试',
      );

      expect(r.body['code'], 200);
    });

    test('非 ApiException 被包成 localUnexpected', () async {
      await expectLater(
        apiCall(() async => throw StateError('boom'), what: '测试'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.localUnexpected)
              .having((e) => e.cause, 'cause', isA<StateError>())
              .having((e) => e.message, 'message', contains('测试')),
        ),
      );
    });

    test('ApiException 原样抛出,不二次包装', () async {
      await expectLater(
        apiCall(() async => throw const ApiException(301, '需要登录'), what: '测试'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 301)
              .having((e) => e.message, 'message', '需要登录'),
        ),
      );
    });

    test('业务码错误也以 ApiException 形式抛出', () async {
      await expectLater(
        apiCall(() async => _res(<String, dynamic>{'code': 405})),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 405)),
      );
    });
  });
}
