import 'library_summary.dart' show PlaylistSource;

class PlaylistMeta {
  final String name;
  final String coverUrl;
  final String description;

  /// 详情页 controller 读它决定显示 ❤️ 收藏还是 🗑 删除。来自
  /// `/playlist/detail` 的 `playlist.subscribed`,已由 fromNeteaseJson 换成
  /// enum,调用方不接触 bool。
  final PlaylistSource source;

  const PlaylistMeta({
    required this.name,
    required this.coverUrl,
    required this.description,
    required this.source,
  });
}
