import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/ApiException.dart';
import '../models/LibrarySummary.dart';
import '../models/Song.dart';
import '../sdk/AuthController.dart';
import '../services/AudioPlayerWrapper.dart';
import '../services/DownloadService.dart';
import '../services/repositories/LibraryRepository.dart';
import '../services/repositories/PlaylistRepository.dart';

/// 长按 [SongRowTile] 弹出的菜单。
///
/// 注意：
/// - Controller 的生命周期由外部 Binding / 调用方负责。
/// - 本 Widget 不再负责 Get.put / Get.delete。
/// - Dialog 关闭前必须完成所有 Rx 状态更新，避免 Obx 在 Widget
///   正在 deactivate 时再次触发 rebuild。
class LongPressDialog extends StatelessWidget {
  const LongPressDialog({super.key});

  static const _tag = 'longPressDialog';

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LongPressDialogController>(tag: _tag);

    return Dialog(
      child: Obx(() {
        // 不使用 AnimatedSwitcher。
        //
        // 这里没有动画需求，直接切换 widget tree。
        // 同时避免 dialog + 异步 Obx rebuild 时产生额外的
        // element reparent / GlobalKey 生命周期问题。
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
        // 标题区：歌曲名 + 艺人 + 关闭按钮
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

        // 添加到歌单
        ListTile(
          leading: const Icon(Icons.playlist_add),
          title: const Text('添加到歌单'),
          onTap: controller.openPlaylistPicker,
        ),

        // 添加到播放列表
        ListTile(
          leading: const Icon(Icons.queue_music),
          title: const Text('添加到播放列表'),
          onTap: controller.addToQueue,
        ),

        // 下载
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下载'),
          onTap: controller.downloadSong,
        ),

        // 从歌单中删除：仅自建歌单内显示
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
        // 标题 + 返回
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: controller.closePlaylistPicker,
          ),
          title: Text('选择歌单', style: textTheme.titleMedium),
        ),

        const Divider(),

        // loading
        if (controller.pickerLoading.value)
          const Center(child: CircularProgressIndicator())
        // 空 / 错误
        else if (controller.userPlaylists.isEmpty)
          Text(
            controller.pickerError.value ?? '暂无歌单',
            style: textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          )
        // 歌单列表
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

// ---- Controller ------------------------------------------------------------

/// LongPressDialog 的 GetX controller。
///
/// 生命周期由外部 Binding / 调用方负责。
///
/// 特别注意：
///
/// 所有异步操作都遵循：
///
///   await
///   ↓
///   isBusy = false
///   ↓
///   Get.back()
///
/// 绝对不能：
///
///   Get.back()
///   ↓
///   finally
///   ↓
///   isBusy = false
///
/// 后一种顺序可能导致 Dialog 已经开始 deactivate 后，
/// Obx 又因为 Rx 更新而尝试 rebuild，从而触发 Flutter framework
/// 的 `_dependents.isEmpty` assertion。
class LongPressDialogController extends GetxController {
  LongPressDialogController({
    required this.song,
    required this.index,
    required this.source,
    required this.playlistId,
  });

  final Song song;
  final int index;
  final PlaylistSource source;
  final String? playlistId;

  // ---- 依赖 ----------------------------------------------------------------

  final PlaylistRepository _playlistRepo = Get.find<PlaylistRepository>();

  final LibraryRepository _libraryRepo = Get.find<LibraryRepository>();

  final AuthController _auth = Get.find<AuthController>();

  final AudioPlayerService _player = Get.find<AudioPlayerService>();

  final DownloadService _downloader = Get.find<DownloadService>();

  // ---- 状态 ----------------------------------------------------------------

  /// 是否在二级「选歌单」面板。
  final RxBool isChoosingPlaylist = false.obs;

  /// 二级面板：加载状态。
  final RxBool pickerLoading = false.obs;

  /// 二级面板：错误信息。
  final RxnString pickerError = RxnString();

  /// 用户歌单。
  final RxList<PlaylistSummary> userPlaylists = <PlaylistSummary>[].obs;

  /// 通用操作锁，防止重复点击。
  final RxBool isBusy = false.obs;

  // ---- 操作 ----------------------------------------------------------------

  /// 打开二级选歌单面板。
  ///
  /// 第一次进入时加载用户歌单。
  Future<void> openPlaylistPicker() async {
    if (isBusy.value) return;

    isChoosingPlaylist.value = true;

    if (userPlaylists.isEmpty) {
      await _loadUserPlaylists();
    }
  }

  /// 返回一级菜单。
  void closePlaylistPicker() {
    isChoosingPlaylist.value = false;
  }

  /// 添加到指定歌单。
  ///
  /// 生命周期顺序非常重要：
  ///
  ///   await addTracks()
  ///        ↓
  ///   isBusy = false
  ///        ↓
  ///   Get.back()
  ///
  /// 不要把 isBusy=false 放进 Get.back() 后面的 finally。
  Future<void> addToPlaylist(String playlistId, String playlistName) async {
    if (isBusy.value) return;

    isBusy.value = true;

    try {
      final ok = await _playlistRepo.addTracks(playlistId, [song.id]);

      // ------------------------------------------------------------
      // 关键：
      // Dialog 关闭之前先完成最后一次 Rx 更新。
      // ------------------------------------------------------------
      isBusy.value = false;

      // Rx 已经稳定，不再触发 Dialog 内 Obx rebuild。
      Get.back<void>();

      if (ok) {
        _toast('已添加到 $playlistName');
      } else {
        _toast('添加失败');

        if (kDebugMode) {
          debugPrint(
            '[LongPressDialog] addTracks failed: '
            'playlistId=$playlistId, '
            'songId=${song.id}',
          );
        }
      }
    } catch (e) {
      // 异常情况下同样必须先恢复 Rx 状态，
      // 然后再决定是否关闭 Dialog。
      isBusy.value = false;

      if (kDebugMode) {
        debugPrint('[LongPressDialog] addToPlaylist exception: $e');
      }

      _toast('添加失败: $e');
    }
  }

  /// 从当前所在的自建歌单删除这首歌。
  Future<void> removeFromPlaylist() async {
    final pid = playlistId;

    if (pid == null) return;
    if (isBusy.value) return;

    isBusy.value = true;

    try {
      final ok = await _playlistRepo.removeTracks(pid, [song.id]);

      // ------------------------------------------------------------
      // 关键：
      // 必须在 Get.back() 之前恢复 isBusy。
      // ------------------------------------------------------------
      isBusy.value = false;

      Get.back<void>();

      if (ok) {
        _toast('已从歌单删除');

        // 通知上层 controller 刷新 body 列表。
        //
        // LongPressDialog 不直接持有上层 controller，
        // 调用方在 Get.back 后自行 reload。
      } else {
        _toast('删除失败');

        if (kDebugMode) {
          debugPrint(
            '[LongPressDialog] removeTracks failed: '
            'playlistId=$pid, '
            'songId=${song.id}',
          );
        }
      }
    } catch (e) {
      // 注意这里没有 finally。
      //
      // 因为如果 finally 放在 Get.back() 后面，
      // 就可能重新出现：
      //
      // Get.back()
      //   ↓
      // Dialog deactivate
      //   ↓
      // finally -> isBusy=false
      //   ↓
      // Obx rebuild
      //
      // 从而触发 _dependents.isEmpty。
      isBusy.value = false;

      if (kDebugMode) {
        debugPrint('[LongPressDialog] removeFromPlaylist exception: $e');
      }

      _toast('删除失败: $e');
    }
  }

  /// 追加到当前播放队列末尾。
  Future<void> addToQueue() async {
    if (isBusy.value) return;

    isBusy.value = true;

    try {
      await _player.addToQueue(song);

      // ------------------------------------------------------------
      // 关键：
      // 先结束 busy，再关闭 Dialog。
      // ------------------------------------------------------------
      isBusy.value = false;

      Get.back<void>();

      _toast('已添加到播放列表');
    } catch (e) {
      // 异常情况下同样先恢复 Rx。
      isBusy.value = false;

      if (kDebugMode) {
        debugPrint('[LongPressDialog] addToQueue failed: $e');
      }

      Get.back<void>();

      _toast('添加失败: $e');
    }
  }

  /// 下载当前歌曲。
  Future<void> downloadSong() async {
    if (isBusy.value) return;

    isBusy.value = true;

    try {
      final ok = await _downloader.download(song);

      // ------------------------------------------------------------
      // 关键：
      // 先结束 busy，再关闭 Dialog。
      // ------------------------------------------------------------
      isBusy.value = false;

      Get.back<void>();

      if (ok) {
        _toast('已加入下载队列');
      } else {
        _toast('下载失败');

        if (kDebugMode) {
          debugPrint(
            '[LongPressDialog] download failed: '
            'songId=${song.id}',
          );
        }
      }
    } catch (e) {
      // 异常情况下同样先恢复 Rx。
      isBusy.value = false;

      if (kDebugMode) {
        debugPrint('[LongPressDialog] downloadSong failed: $e');
      }

      Get.back<void>();

      _toast('下载失败: $e');
    }
  }

  // ---- 私有 ----------------------------------------------------------------

  /// 加载用户歌单。
  Future<void> _loadUserPlaylists() async {
    pickerLoading.value = true;
    pickerError.value = null;

    try {
      final uid = _auth.currentUid;

      if (uid == 0) {
        pickerError.value = '请先登录';
        userPlaylists.clear();
        return;
      }

      final list = await _libraryRepo.fetchPlaylists(uid.toString());

      userPlaylists.assignAll(list);
    } on ApiException catch (e) {
      pickerError.value = e.message;
      userPlaylists.clear();

      if (kDebugMode) {
        debugPrint(
          '[LongPressDialog] fetchPlaylists ApiException: '
          '$e',
        );
      }
    } catch (e) {
      pickerError.value = '加载歌单失败: $e';
      userPlaylists.clear();

      if (kDebugMode) {
        debugPrint('[LongPressDialog] fetchPlaylists exception: $e');
      }
    } finally {
      // 这里没有 Get.back()，所以 finally 是安全的。
      pickerLoading.value = false;
    }
  }

  /// 显示操作结果。
  void _toast(String msg) {
    Get.snackbar(
      '',
      msg,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
}
