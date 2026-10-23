import 'package:flutter_test/flutter_test.dart';
import 'package:oceanus/models/library_summary.dart';

void main() {
  group('PlaylistCard.fromNeteaseJson', () {
    test('解析 /personalized 的一项', () {
      final card = PlaylistCard.fromNeteaseJson(<String, dynamic>{
        'id': 145022,
        'name': '华语热歌',
        'picUrl': 'https://example.com/hot.jpg',
      });

      expect(card.id, '145022');
      expect(card.name, '华语热歌');
      expect(card.picUrl, 'https://example.com/hot.jpg');
    });

    test('缺字段时给空串', () {
      final card = PlaylistCard.fromNeteaseJson(<String, dynamic>{'id': 1});

      expect(card.name, '');
      expect(card.picUrl, '');
    });
  });

  group('PlaylistSummary.fromNeteaseJson', () {
    test('subscribed=true 归为 collected', () {
      final summary = PlaylistSummary.fromNeteaseJson(<String, dynamic>{
        'id': 2,
        'name': '收藏的歌单',
        'coverImgUrl': 'https://example.com/c.jpg',
        'trackCount': 30,
        'subscribed': true,
      });

      expect(summary.id, '2');
      expect(summary.name, '收藏的歌单');
      expect(summary.picUrl, 'https://example.com/c.jpg');
      expect(summary.trackCount, 30);
      expect(summary.source, PlaylistSource.collected);
    });

    test('subscribed 缺失 / false 归为 created', () {
      expect(
        PlaylistSummary.fromNeteaseJson(<String, dynamic>{'id': 1}).source,
        PlaylistSource.created,
      );
      expect(
        PlaylistSummary.fromNeteaseJson(<String, dynamic>{
          'id': 1,
          'subscribed': false,
        }).source,
        PlaylistSource.created,
      );
    });

    test('trackCount 缺失时归零', () {
      final summary = PlaylistSummary.fromNeteaseJson(<String, dynamic>{
        'id': 1,
      });

      expect(summary.trackCount, 0);
    });
  });

  group('AlbumSummary.fromNeteaseJson', () {
    test('解析 /album/sublist 的一项', () {
      final summary = AlbumSummary.fromNeteaseJson(<String, dynamic>{
        'id': 347208,
        'name': '五月天',
        'picUrl': 'https://example.com/a.jpg',
        'artists': <Map<String, dynamic>>[
          <String, dynamic>{'id': 11, 'name': '五月天'},
        ],
      });

      expect(summary.id, '347208');
      expect(summary.name, '五月天');
      expect(summary.artist, '五月天');
      expect(summary.picUrl, 'https://example.com/a.jpg');
    });

    test('artists 缺失时 artist 为空串', () {
      final summary = AlbumSummary.fromNeteaseJson(<String, dynamic>{'id': 1});

      expect(summary.artist, '');
    });
  });

  group('ArtistSummary.fromNeteaseJson', () {
    test('解析 /user/follow/mixed 的一项', () {
      final summary = ArtistSummary.fromNeteaseJson(<String, dynamic>{
        'id': 6452,
        'name': '周杰伦',
        'picUrl': 'https://example.com/jay.jpg',
      });

      expect(summary.id, '6452');
      expect(summary.name, '周杰伦');
      expect(summary.picUrl, 'https://example.com/jay.jpg');
    });
  });
}
