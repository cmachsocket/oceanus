import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../ArtistPage/artist_detail.dart';
import '../SongListPage/songlist_detail.dart';
import '../models/default.dart';
import '../models/song.dart';
import '../models/library_summary.dart' show PlaylistSource;

/// 歌曲列表里的"艺人 - 专辑"双链接文本
///
/// - 艺人点击 → [ArtistDetail](artistId: song.artistId)
/// - 专辑点击 → [SongListDetail](playlistId: song.albumId, source: PlaylistSource.album)
///   —— 专辑复用歌单详情页的 head / body,不另起 controller
/// - 任一 ID 缺失 → 对应链接降级为只读 Text(避免点开 "111" 占位)
class LinkedDetailText extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final TextStyle? textStyle;
  final MainAxisAlignment? mainAxisAlignment;
  final bool? backFirst;
  const LinkedDetailText({
    super.key,
    required this.song,
    this.onTap,
    this.textStyle,
    this.mainAxisAlignment,
    this.backFirst,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = textStyle ?? textTheme.bodySmall;

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: mainAxisAlignment ?? MainAxisAlignment.start,
      children: [
        _ArtistLink(song: song, style: style, backFirst: backFirst ?? false),
        Text('-', textAlign: TextAlign.center, style: style),
        _AlbumLink(song: song, style: style, backFirst: backFirst ?? false),
      ],
    );
  }
}

/// 艺人链接:有 artistId → TextButton;否则降级为只读 Text
class _ArtistLink extends StatelessWidget {
  const _ArtistLink({
    required this.song,
    required this.style,
    required this.backFirst,
  });

  final Song song;
  final TextStyle? style;
  final bool backFirst;

  @override
  Widget build(BuildContext context) {
    final id = song.artistId;
    final text = song.artist.isEmpty ? '未知艺人' : song.artist;
    if (id == null || id.isEmpty) {
      return Flexible(
        child: _ReadOnlyText(text: text, style: style),
      );
    }
    return Flexible(
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => _navigate(id),
        child: Text(
          text,
          maxLines: 1,
          style: style,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  void _navigate(String artistId) {
    if (backFirst) Get.back(id: DefaultValues.shellNavigatorId);
    Get.to(
      () => ArtistDetail(artistId: artistId),
      id: DefaultValues.shellNavigatorId,
      binding: ArtistDetailBinding(artistId: artistId),
    );
  }
}

/// 专辑链接:复用 SongListDetail,source 传 PlaylistSource.album
class _AlbumLink extends StatelessWidget {
  const _AlbumLink({
    required this.song,
    required this.style,
    required this.backFirst,
  });

  final Song song;
  final TextStyle? style;
  final bool backFirst;

  @override
  Widget build(BuildContext context) {
    final id = song.albumId;
    final text = song.album.isEmpty ? '未知专辑' : song.album;
    if (id == null || id.isEmpty) {
      return Flexible(
        child: _ReadOnlyText(text: text, style: style),
      );
    }
    return Flexible(
      child: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () {
          if (backFirst) Get.back(id: DefaultValues.shellNavigatorId);
          Get.to(
            () => SongListDetail(
              controllerTag: id + PlaylistSource.album.toString(),
            ),
            id: DefaultValues.shellNavigatorId,
            binding: SongListDetailBinding(
              playlistId: id,
              source: PlaylistSource.album,
            ),
          );
        },
        child: Text(
          text,
          maxLines: 1,
          style: style,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 纯文本(没有 ID 时降级显示)。**不包 Flexible** —— Flexible 由调用方
/// (`_ArtistLink` / `_AlbumLink`) 统一加。Nested Flexible 会撞
/// `Competing ParentDataWidgets` 断言。
class _ReadOnlyText extends StatelessWidget {
  const _ReadOnlyText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      style: style,
      overflow: TextOverflow.ellipsis,
    );
  }
}
