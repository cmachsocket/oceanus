import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../data/models/song.dart';
import '../../../widgets/linked_detail_text.dart';
import '../../../widgets/song_cover.dart';
import '../../../core/constants/default_values.dart';
import 'package:responsive_builder/responsive_builder.dart';
import '../../settings/controllers/settings_controller.dart';
import '../../../services/download_service.dart';
import '../../../data/models/download_task_view.dart';

/// 查询 song 是否被喜欢的回调（无参：调用方包好 song 后注入）
typedef IsLikedGetter = bool Function();

/// 歌曲行（供 SongListDetail / ArtistDetail 共用）
///
/// - **fav button 响应式**：[isLiked] 回调被 Obx 包裹，likedIds 变化时
///   只重建 IconButton（不是整行）。
/// - 如果 caller 不传 [isLiked]（null），Obx 闭包里不会触达任何 Rx，零开销。
class SongRowTile extends StatelessWidget {
  const SongRowTile({
    super.key,
    required this.song,
    this.selected = false,
    this.onToggleFavorite,
    this.onPlay,
    this.isLiked,
    this.extraTrailing,
    this.onLongPress,
  });

  final Song song;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onPlay;
  final bool selected;
  final void Function()? onLongPress;

  //额外的 trailing widget, 比如专辑列表页的 "更多" 按钮
  final Widget Function()? extraTrailing;

  /// 查询当前 song 是否被喜欢 —— callback 内部读 Rx，
  /// Obx 会自动监听那些 Rx（likedIds / likedAlbumIds 等）。
  final IsLikedGetter? isLiked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settingsCtrl = Get.find<SettingsController>();
    return ListTile(
      selected: selected,
      leading: AspectRatio(
        aspectRatio: DefaultValues.squardRatio,
        child: SongCover(url: song.coverUrl),
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: LinkedDetailText(song: song),
      onTap: onPlay,
      onLongPress: onLongPress,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OrientationLayoutBuilder(
            portrait: (context) => const SizedBox.shrink(),
            landscape: (context) => Text(song.durationLabel),
          ),
          // fav button:isLiked == null 路径不能包 Obx (GetX 检测空订阅会抛
          // "improper use"),直接用普通 IconButton;此路径本来就没 Rx 可订阅。
          if (isLiked == null)
            IconButton(
              padding: DefaultValues.onlyZero,
              icon: const Icon(Icons.favorite_border),
              onPressed: null, // 没回调就不响应
              tooltip: '喜爱',
            )
          else
            Obx(() {
              final liked = isLiked!.call();
              return IconButton(
                padding: DefaultValues.onlyZero,
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  color: liked ? scheme.primary : null,
                ),
                onPressed: onToggleFavorite,
                tooltip: '喜爱',
              );
            }),
          // 下载按钮:
          // - downloadMode == false → 不显示,退回 extraTrailing(caller 自定义
          //   trailing,如专辑页"更多")或空
          // - downloadMode == true → Obx 盯 DownloadService.tasks[songId],
          //   按 idle / queued / running(progress) / complete / failed 切图标
          //
          // 外层 if-else 拆开避免 Obx 闭包零订阅 (GetX 会抛 "improper use") ——
          // DownloadMode 路径必须包 Obx 才能响应 settings 切换,空路径不需要。
          if (settingsCtrl.downloadMode.value)
            Obx(() {
              final downloadSvc = Get.find<DownloadService>();
              final view = downloadSvc.tasks[song.id];
              return _DownloadButton(song: song, view: view);
            })
          else if (extraTrailing != null)
            extraTrailing!()
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// 下载按钮 —— 单一职责,按 [view] (DownloadService.tasks[songId] 的当前值)
/// 决定图标 / 进度 / 点击行为:未下载 → 普通下载图标(点击下载);
/// 排队 / 进行中 → 转圈(点击取消);完成 → check(点击无效);
/// 失败 / 取消 / notFound → alert(点击重试)。
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.song, required this.view});

  final Song song;
  final DownloadTaskView? view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final svc = Get.find<DownloadService>();
    final status = view?.status;
    final isInProgress =
        status == DownloadStatus.enqueued ||
        status == DownloadStatus.running ||
        status == DownloadStatus.waitingToRetry;
    final isComplete = status == DownloadStatus.complete;

    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          padding: DefaultValues.onlyZero,
          icon: Icon(
            _iconFor(status),
            color: isComplete ? scheme.primary : null,
          ),
          tooltip: _tooltipFor(status),
          onPressed: () {
            if (isInProgress) {
              svc.remove(song.id);
            } else {
              // ignore: discarded_futures
              svc.download(song);
            }
          },
        ),
        // running 时叠进度环
        if (status == DownloadStatus.running ||
            status == DownloadStatus.waitingToRetry)
          IgnorePointer(
            child: SizedBox.expand(
              child: CircularProgressIndicator(
                value: (view?.progress ?? 0) > 0 ? view!.progress : null,
                color: scheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  IconData _iconFor(DownloadStatus? s) {
    switch (s) {
      case DownloadStatus.complete:
        return Icons.check_circle;
      case DownloadStatus.failed:
      case DownloadStatus.notFound:
        return Icons.error_outline;
      case DownloadStatus.canceled:
        return Icons.cancel_outlined;
      case DownloadStatus.enqueued:
      case DownloadStatus.running:
      case DownloadStatus.waitingToRetry:
        return Icons.downloading;
      case null:
        return Icons.download_outlined;
    }
  }

  String _tooltipFor(DownloadStatus? s) {
    switch (s) {
      case DownloadStatus.complete:
        return '已下载';
      case DownloadStatus.failed:
      case DownloadStatus.notFound:
        return '点击重试';
      case DownloadStatus.canceled:
        return '已取消 · 点击重试';
      case DownloadStatus.enqueued:
        return '等待中 · 点击取消';
      case DownloadStatus.running:
      case DownloadStatus.waitingToRetry:
        return '下载中 · 点击取消';
      case null:
        return '下载';
    }
  }
}
