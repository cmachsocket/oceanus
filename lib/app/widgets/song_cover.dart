import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../data/models/headers.dart';

/// 歌曲 / 专辑 / 艺人 / 歌单封面通用 widget
///
/// - URL 为空(常见: search 接口 album 项只有 picId 没 picUrl) → 直接占位,
///   不调 CachedNetworkImage(避免 URL 为 "" 时解析抛异常)
/// - 加载中 / 网络失败 → 占位
/// - 不写圆角数字,接受 [ListTile.leading] 默认方形容器
class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final placeholder = CircularProgressIndicator();

    if (url.isEmpty) return placeholder;

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      httpHeaders: NeteaseImageHeaders.neteaseImageHeaders,
      placeholder: (context, url) => placeholder,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}
