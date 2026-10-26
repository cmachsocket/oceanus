import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../controllers/long_press_dialog_controller.dart';

/// 长按 [SongRowTile] 弹出的菜单。
///
/// 注意:
/// - Controller 的生命周期由外部 Binding / 调用方负责,本 Widget 不做
///   Get.put / Get.delete。
/// - Dialog 关闭前必须完成所有 Rx 状态更新,避免 Obx 在 Widget
///   正在 deactivate 时再次触发 rebuild。
class LongPressDialog extends StatelessWidget {
  const LongPressDialog({super.key});

  static const _tag = 'longPressDialog';

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LongPressDialogController>(tag: _tag);

    return Dialog(
      child: Obx(() {
        // 不用 AnimatedSwitcher:直接切 widget tree,避免 dialog + 异步 Obx
        // rebuild 时产生额外的 element reparent / GlobalKey 生命周期问题。
        return controller.isChoosingPlaylist.value
            ? _PlaylistPicker(
                key: const ValueKey('picker'),
                controller: controller,
              )
            : _MainMenu(key: const ValueKey('main'), controller: controller);
      }),
    );
  }
}

// ---- 一级菜单 --------------------------------------------------------------

class _MainMenu extends StatelessWidget {
  const _MainMenu({super.key, required this.controller});

  final LongPressDialogController controller;

  @override
  Widget build(BuildContext context) {
    final song = controller.song;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(
            song.title,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            song.artist,
            style: textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Get.back<void>(),
          ),
        ),

        const Divider(),

        ListTile(
          leading: const Icon(Icons.playlist_add),
          title: const Text('添加到歌单'),
          onTap: controller.openPlaylistPicker,
        ),

        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('添加到播放列表'),
          onTap: controller.addToQueue,
        ),

        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下载'),
          onTap: controller.downloadSong,
        ),

        // 从歌单中删除：仅自建歌单(created)且来自详情页时显示
        if (controller.source == PlaylistSource.created &&
            controller.playlistId != null)
          ListTile(
            leading: Icon(
              Icons.remove_circle_outline,
              color: theme.colorScheme.error,
            ),
            title: Text(
              '从歌单中删除',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: controller.removeFromPlaylist,
          ),
      ],
    );
  }
}

// ---- 二级：选歌单 -----------------------------------------------------------

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({super.key, required this.controller});

  final LongPressDialogController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: controller.closePlaylistPicker,
          ),
          title: Text('选择歌单', style: textTheme.titleMedium),
        ),

        const Divider(),

        if (controller.pickerLoading.value)
          const Center(child: CircularProgressIndicator())
        else if (controller.userPlaylists.isEmpty)
          Text(
            controller.pickerError.value ?? '暂无歌单',
            style: textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          )
        else
          //ConstrainedBox(
          //constraints: const BoxConstraints(maxHeight: 360),
          //child:
          ListView.builder(
            shrinkWrap: true,
            itemCount: controller.userPlaylists.length,
            itemBuilder: (context, i) {
              final p = controller.userPlaylists[i];

              return ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${p.trackCount} 首',
                  style: textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                onTap: () => controller.addToPlaylist(p.id, p.name),
              );
            },
          ),
        // ),
      ],
    );
  }
}
