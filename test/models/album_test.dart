import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/models/album.dart';

void main() {
  group('Album.fromNeteaseJson', () {
    test('解析完整字段', () {
      final album = Album.fromNeteaseJson(<String, dynamic>{
        'id': 32311,
        'name': '范特西',
        'picUrl': 'https://example.com/fantasy.jpg',
        'size': 14,
        'publishTime': 1095753600000,
        'type': 'Album',
        'artists': <Map<String, dynamic>>[
          <String, dynamic>{'id': 6452, 'name': '周杰伦'},
          <String, dynamic>{'id': 2, 'name': 'other'},
        ],
      });

      expect(album.id, '32311');
      expect(album.name, '范特西');
      expect(album.artist, '周杰伦');
      expect(album.coverUrl, 'https://example.com/fantasy.jpg');
      expect(album.songCount, 14);
      expect(album.type, AlbumType.album);
      expect(album.releaseDate.millisecondsSinceEpoch, 1095753600000);
    });

    test('type 映射到枚举', () {
      AlbumType typeOf(String t) =>
          Album.fromNeteaseJson(<String, dynamic>{'id': 1, 'type': t}).type;

      expect(typeOf('Album'), AlbumType.album);
      expect(typeOf('Single'), AlbumType.single);
      expect(typeOf('EP'), AlbumType.ep);
      expect(typeOf('Compilation'), AlbumType.compilation);
    });

    test('type 缺失 / 未知时归为 album', () {
      expect(
        Album.fromNeteaseJson(<String, dynamic>{'id': 1}).type,
        AlbumType.album,
      );
      expect(
        Album.fromNeteaseJson(<String, dynamic>{'id': 1, 'type': '???'}).type,
        AlbumType.album,
      );
    });

    test('缺字段时给默认值', () {
      final album = Album.fromNeteaseJson(<String, dynamic>{'id': 7});

      expect(album.id, '7');
      expect(album.name, '');
      expect(album.artist, '');
      expect(album.coverUrl, '');
      expect(album.songCount, 0);
      expect(album.releaseDate.millisecondsSinceEpoch, 0);
    });
  });

  group('AlbumTypeLabel', () {
    test('每个枚举值都有中文标签', () {
      expect(AlbumType.album.label, '专辑');
      expect(AlbumType.ep.label, 'EP');
      expect(AlbumType.single.label, '单曲');
      expect(AlbumType.compilation.label, '合辑');
    });
  });
}
