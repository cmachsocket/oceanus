// ignore_for_file: file_names

import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';
// tray_manager 0.7 重新导出了 nativeapi 的全部符号,不要直接 import nativeapi
// (它只是传递依赖,analyzer 会报未声明)。
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/Snapshot.dart' show PlaybackSnapshot;
import 'AudioPlayerWrapper.dart';

/// ---- 系统托盘控制器 -----------------------------------------------------------
///
/// 桌面平台注册托盘图标 + 菜单(显示/隐藏、上一首、播放暂停、下一首、喜欢、退出)。
/// 菜单命令直接调 [AudioPlayerService] —— 不绕 PlayerController,因为后者不是
/// permanent,tray 命令可能在页面 pop 之后到达,GetX 会重建一个空 controller。
///
/// **三处必须记住的坑**(都实际踩过,改动前先读这里):
///
/// 1. **显隐判断一律现查 `windowManager.isVisible()`**,不要用本地缓存。缓存只由
///    focus/blur 写,而菜单点击、标题栏 X、任务栏最小化都不保证发这些事件,
///    缓存失真就变成"藏起来后再点也唤不回来"。
///
/// 2. **菜单 label 改了不会自动通知面板,必须重建整份菜单**。Linux 上菜单经
///    D-Bus dbusmenu 交给面板,面板只在打开时拉一次 GetLayout 并缓存;协议里
///    通知它"布局变了"靠 `LayoutUpdated` 信号,而 nativeapi 0.3.0 在
///    `MenuItem.label` 变更时既不发信号也不递增 revision(实测:3 秒内 0 信号,
///    revision 恒定)。症状是显隐行为正确、菜单文字却永远停在初始值。
///    故走 `_rebuildMenu()` + 重新 `setContextMenu`,强制面板重拉。
///
/// 3. **别动 `setContextMenuTrigger`**。Linux 菜单由面板自己弹,应用侧
///    `popUpContextMenu` 是 no-op 且收不到点击事件(README-ZH 149/151 行),
///    设成 `rightClicked` 会让左键激活失效、菜单直接打不开。
///
/// 另:macOS 拦截"点 X"改成隐藏到托盘;Linux/Windows 保持点 X 退出。
class TrayController extends GetxController with WindowListener {
  // TrayIcon / Menu / MenuItem **必须**持有引用,否则被 GC 时 nativeapi 的
  // finalizer 释放句柄,图标或菜单项随之消失。
  TrayIcon? _tray;
  Menu? _menu;
  MenuItem? _togglePlayItem;
  MenuItem? _toggleLikeItem;
  MenuItem? _currentSongItem;

  AudioPlayerService get _audio => Get.find<AudioPlayerService>();

  Worker? _snapshotWorker;

  /// 窗口是否可见 —— **只用于决定菜单项文案**,不参与点击分支判断(见坑 1)。
  /// 即使偶尔失真也只会影响文字,不会导致唤不回来。
  bool _showHideVisible = true;

  @override
  void onInit() {
    super.onInit();
    if (!_isSupportedPlatform) {
      // 移动端 / Web:不注册,纯 no-op
      return;
    }
    _initTray();
    _initWindowCloseIntercept();
  }

  @override
  void onClose() {
    _snapshotWorker?.dispose();
    windowManager.removeListener(this);
    _tray?.dispose();
    _menu?.dispose();
    super.onClose();
  }

  bool get _isSupportedPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  // ---- 托盘初始化 ---------------------------------------------------------------

  Future<void> _initTray() async {
    final icon = TrayIcon.create();
    if (icon == null) {
      // GNOME 没装 AppIndicator 扩展时会这样,跳过托盘,应用主体照常工作。
      // ignore: avoid_print
      print('[TrayController] TrayIcon.create() 返回 null (Linux 可能需要 AppIndicator 扩展)');
      return;
    }
    _tray = icon;

    // macOS 用 monochrome template image(系统菜单栏自动反色),其他平台用彩色图。
    final imagePath = Platform.isMacOS
        ? 'assets/tray/oceanus_tray_mono.png'
        : 'assets/tray/oceanus_tray.png';
    final image = ImageAsset.fromAsset(imagePath);
    if (image != null) {
      icon.icon = image;
    }
    icon.isIconTemplate = Platform.isMacOS;
    icon.setTooltip('Oceanus · 网易云音乐');

    _rebuildMenu();
    _tray!.setContextMenu(_menu!);

    // 见类注释坑 3:非 macOS 保持默认的 left-click,不要动。
    icon.setContextMenuTrigger(
      Platform.isMacOS
          ? ContextMenuTrigger.rightClicked
          : ContextMenuTrigger.clicked,
    );

    // 仅 Windows/macOS 有意义,Linux 上不触发(见类注释坑 3)。
    icon.addListener(_onTrayIconEvent);
    icon.setVisible(true);

    _snapshotWorker = ever<PlaybackSnapshot>(_audio.snapshot, _onSnapshot);
    _onSnapshot(_audio.snapshot.value);
  }

  /// 整份重建菜单。调用方负责重新 `setContextMenu`。
  ///
  /// 必须重建而不能只改 `item.label` 的原因见类注释坑 2。另外重建时要丢掉旧
  /// item 句柄,否则新 label 会写到已不属于当前菜单的旧 item 上。
  void _rebuildMenu() {
    _togglePlayItem = null;
    _toggleLikeItem = null;
    _currentSongItem = null;
    _menu?.dispose();

    _menu = Menu.create();
    _buildMenuItems();
    // 新 item 默认是兜底文案(播放/喜欢/未在播放),用当前快照刷成真实状态。
    _onSnapshot(_audio.snapshot.value);
  }

  void _buildMenuItems() {
    final menu = _menu!;

    // 顶部:当前歌曲 (disabled,不可点)
    final current = MenuItem.createWithLabelAndType(
      '未在播放',
      MenuItemType.normal,
    );
    current?.isEnabled = false;
    _currentSongItem = current;
    if (current != null) menu.addItem(current);

    menu.addSeparator();

    // 窗口可见时写"隐藏主窗口",不可见时写"显示主窗口"(见 _showHideVisible)。
    // 句柄不跨重建保留,文案由 _buildMenuItems 每次重建时写入。
    final showHide = MenuItem.createWithLabelAndType(
      _showHideVisible ? '隐藏主窗口' : '显示主窗口',
      MenuItemType.normal,
    );
    showHide?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        _toggleWindow();
      }
    });
    if (showHide != null) menu.addItem(showHide);

    menu.addSeparator();

    // 上一首
    final prev = MenuItem.createWithLabelAndType('上一首', MenuItemType.normal);
    prev?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        // ignore: discarded_futures
        _audio.skipToPrevious();
      }
    });
    if (prev != null) menu.addItem(prev);

    // 播放/暂停,label 由 _onSnapshot 改
    final play = MenuItem.createWithLabelAndType('播放', MenuItemType.normal);
    play?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        if (_audio.snapshot.value.isPlaying) {
          // ignore: discarded_futures
          _audio.pause();
        } else {
          // ignore: discarded_futures
          _audio.play();
        }
      }
    });
    _togglePlayItem = play;
    if (play != null) menu.addItem(play);

    // 下一首
    final next = MenuItem.createWithLabelAndType('下一首', MenuItemType.normal);
    next?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        // ignore: discarded_futures
        _audio.skipToNext();
      }
    });
    if (next != null) menu.addItem(next);

    // 喜欢 / 取消喜欢,label 由 _onSnapshot 改
    final like = MenuItem.createWithLabelAndType('喜欢', MenuItemType.normal);
    like?.isEnabled = false; // 没有当前歌曲时灰掉
    like?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        final song = _audio.snapshot.value.currentSong;
        if (song == null) return;
        // ignore: discarded_futures
        _audio.toggleFavorite(song.id);
      }
    });
    _toggleLikeItem = like;
    if (like != null) menu.addItem(like);

    menu.addSeparator();

    // 退出
    final exit = MenuItem.createWithLabelAndType('退出', MenuItemType.normal);
    exit?.addListener((event) {
      if (event is MenuItemClickedEvent) {
        // ignore: discarded_futures
        _quit();
      }
    });
    if (exit != null) menu.addItem(exit);
  }

  // ---- snapshot → 动态更新菜单 label -------------------------------------------

  void _onSnapshot(PlaybackSnapshot s) {
    final song = s.currentSong;
    // 顶部:"歌名 - 艺术家",过长截断
    if (_currentSongItem != null) {
      if (song == null) {
        _currentSongItem!.label = '未在播放';
      } else {
        final title = song.title.trim().isEmpty ? '未知曲目' : song.title.trim();
        final artist = song.artist.trim();
        final combined = artist.isEmpty ? title : '$title - $artist';
        _currentSongItem!.label =
            combined.length > 40 ? '${combined.substring(0, 40)}…' : combined;
      }
    }

    // 播放-暂停
    if (_togglePlayItem != null) {
      _togglePlayItem!.label = s.isPlaying ? '暂停' : '播放';
    }

    // 喜欢 / 取消喜欢 (没当前歌曲时灰掉)
    if (_toggleLikeItem != null) {
      if (song == null) {
        _toggleLikeItem!.label = '喜欢';
        _toggleLikeItem!.isEnabled = false;
      } else {
        _toggleLikeItem!.label = s.isCurrentSongLiked ? '取消喜欢' : '喜欢';
        _toggleLikeItem!.isEnabled = true;
      }
    }
  }

  // ---- 托盘点击事件 -------------------------------------------------------------

  void _onTrayIconEvent(TrayIconEvent event) {
    // Linux 上不触发点击事件(见类注释坑 3),这里只在 Windows/macOS 有意义。
    if (event is TrayIconClickedEvent || event is TrayIconDoubleClickedEvent) {
      _toggleWindow();
    }
  }

  Future<void> _toggleWindow() async {
    try {
      // 现查原生真值,不用本地缓存(见类注释坑 1)。
      final visible = await windowManager.isVisible();
      if (visible) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
      _syncWindowState(!visible);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[TrayController] toggleWindow 失败: $e');
      }
    }
  }

  /// 同步菜单文案。走重建而非 `item.label`,原因见类注释坑 2。
  void _syncWindowState(bool visible) {
    _showHideVisible = visible;
    // 托盘创建失败时菜单还没建,等 _initTray 里首次构建。
    if (_tray == null || _menu == null) return;
    _rebuildMenu();
    _tray!.setContextMenu(_menu!);
  }

  /// 重新从原生窗口读一次可见性并同步。
  ///
  /// focus/blur/minimize/restore 只表示焦点或图标状态变了,**不等于**窗口被隐藏
  /// —— 切到别的应用只是 blur,窗口照样可见。所以这些回调里不能直接推断可见性。
  Future<void> _refreshWindowState() async {
    try {
      _syncWindowState(await windowManager.isVisible());
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[TrayController] 刷新窗口状态失败: $e');
      }
    }
  }

  void _quit() {
    // 兜底 flush(GetX 可能来不及跑 AudioPlayerService.onClose)。
    // 注意不能声明成 Future<void>:exit(0) 永不返回。
    // ignore: discarded_futures
    windowManager.destroy();
    // ignore: avoid_print
    print('[TrayController] 退出应用 (来自托盘菜单)');
    exit(0);
  }

  // ---- WindowListener ----------------------------------------------------------

  /// listener 在所有桌面平台注册 —— 菜单文案依赖这些事件刷新,只在 macOS 注册
  /// 会让 Windows/Linux 上的状态永远不更新(类注释坑 1)。
  /// 拦截关闭则只 macOS:它习惯点 X 只隐藏,Windows/Linux 习惯点 X 退出。
  Future<void> _initWindowCloseIntercept() async {
    windowManager.addListener(this);
    if (Platform.isMacOS) {
      // 让 close 信号走 onWindowClose 而不是真销毁
      await windowManager.setPreventClose(true);
    }
    await _refreshWindowState();
  }

  @override
  void onWindowClose() {
    // macOS 点 X → 隐藏到托盘,而不是退出
    // ignore: discarded_futures
    windowManager.hide();
    _syncWindowState(false);
  }

  @override
  void onWindowFocus() {
    // ignore: discarded_futures
    _refreshWindowState();
  }

  @override
  void onWindowBlur() {
    // ignore: discarded_futures
    _refreshWindowState();
  }

  @override
  void onWindowMinimize() {
    // ignore: discarded_futures
    _refreshWindowState();
  }

  @override
  void onWindowRestore() {
    // ignore: discarded_futures
    _refreshWindowState();
  }
}