import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/sdk/method_spec.dart';

void main() {
  group('specFor', () {
    test('能查到已登记的方法', () {
      expect(specFor('search').method, 'search');
      expect(specFor('album_sublist').method, 'album_sublist');
    });

    test('未登记的方法抛 ArgumentError', () {
      expect(
        () => specFor('not_a_real_method'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('not_a_real_method'),
          ),
        ),
      );
    });
  });

  group('positionalToQuery', () {
    test('位置参数按顺序映射到字段名', () {
      final query = positionalToQuery('search', <Object?>['周杰伦', '1', '3']);

      expect(query['keywords'], '周杰伦');
      expect(query['type'], '1');
      expect(query['limit'], '3');
    });

    test('缺省参数用 spec 里的默认值补齐', () {
      final query = positionalToQuery('search', <Object?>['周杰伦']);

      expect(query['keywords'], '周杰伦');
      expect(query['type'], '1');
      expect(query['limit'], '30');
    });

    test('album_sublist 的 limit 默认 50', () {
      final query = positionalToQuery('album_sublist', const <Object?>[]);

      expect(query['limit'], '50');
    });

    test('artist_songs 的 limit 默认 50', () {
      final query = positionalToQuery('artist_songs', <Object?>['6452']);

      expect(query['id'], '6452');
      expect(query['limit'], '50');
    });

    test('没有默认值的缺省参数写 null', () {
      final query = positionalToQuery('playlist_detail', const <Object?>[]);

      expect(query.containsKey('id'), isTrue);
      expect(query['id'], isNull);
    });

    test('显式传 null 走默认值而不是写 null', () {
      final query = positionalToQuery('search', <Object?>['x', null]);

      expect(query['type'], '1');
    });

    test('多传的参数被忽略', () {
      final query = positionalToQuery('album_sublist', <Object?>[
        '10',
        'extra',
      ]);

      expect(query['limit'], '10');
      expect(query.length, 1);
    });

    test('无参方法返回空 dict', () {
      expect(positionalToQuery('user_account', const <Object?>[]), isEmpty);
      expect(positionalToQuery('artist_sublist', const <Object?>[]), isEmpty);
    });

    test('like 的两个参数按 op / id 语义落位', () {
      final query = positionalToQuery('like', <Object?>['123', 'true']);

      expect(query['id'], '123');
      expect(query['like'], 'true');
    });

    test('playlist_tracks 用 op / pid / tracks 三个字段', () {
      final query = positionalToQuery('playlist_tracks', <Object?>[
        'add',
        '99',
        '1,2,3',
      ]);

      expect(query['op'], 'add');
      expect(query['pid'], '99');
      expect(query['tracks'], '1,2,3');
    });

    test('未知方法抛 ArgumentError', () {
      expect(
        () => positionalToQuery('nope', const <Object?>[]),
        throwsArgumentError,
      );
    });
  });

  group('methodSpecs 表', () {
    test('每个 method 唯一', () {
      final names = methodSpecs.map((s) => s.method).toList();

      expect(names.toSet().length, names.length);
    });

    test('所有条目都有非空 method 名', () {
      for (final spec in methodSpecs) {
        expect(spec.method, isNotEmpty);
      }
    });
  });
}
