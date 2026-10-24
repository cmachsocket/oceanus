import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../models/download_task_view.dart';
import '../models/song.dart';
import 'repositories/song_repository.dart';

/// 全局下载管理 service。
///
/// 文件规则:`歌曲名字 - 歌手.mp3` / `歌曲名字 - 歌手.flac`。文件格式不依赖 URL
/// 后缀,而是根据实际文件内容判断。支持 MP3、FLAC。
///
/// 文件不存在时:删除 background_downloader 数据库记录 + taskId -> songId 映射,
/// 从 UI tasks 中删除,业务层视为“未下载”。
class DownloadService extends GetxService {
  final SongRepository _songRepo;

  DownloadService(this._songRepo);

  /// UI 唯一订阅点。
  ///
  /// key = songId
  final RxMap<String, DownloadTaskView> tasks =
      <String, DownloadTaskView>{}.obs;

  /// background_downloader 单例。
  final FileDownloader _downloader = FileDownloader();

  /// callback group。
  static const _group = 'ncm_download';

  /// taskId -> songId。
  final Map<String, String> _taskIdToSongId = {};

  /// 启动状态。
  bool _started = false;

  /// Desktop Downloads 目录。
  String? _desktopDownloadsDir;

  // Platform

  static bool get _isAndroid {
    return !kIsWeb && Platform.isAndroid;
  }

  // init

  Future<void> init() async {
    if (_started) return;

    _started = true;

    await _downloader.start(autoCleanDatabase: false);

    _downloader.registerCallbacks(
      group: _group,
      taskStatusCallback: _onStatus,
      taskProgressCallback: _onProgress,
    );

    // Desktop Downloads

    if (!_isAndroid) {
      final dir = await getDownloadsDirectory();

      if (dir != null) {
        _desktopDownloadsDir = dir.path;

        debugPrint(
          '[DownloadService] desktop downloads dir: '
          '$_desktopDownloadsDir',
        );
      } else {
        debugPrint(
          '[DownloadService] WARN: '
          'getDownloadsDirectory() returned null',
        );
      }
    }

    // Restore

    final records = await _downloader.database.allRecords(group: _group);

    for (final record in records) {
      final task = record.task;

      if (task is! DownloadTask) {
        continue;
      }

      final meta = _parseMeta(task.metaData);

      if (meta == null) {
        continue;
      }

      _taskIdToSongId[task.taskId] = meta.songId;

      String? savedPath;

      try {
        savedPath = await _restoreSavedPath(task);
      } catch (e) {
        debugPrint(
          '[DownloadService] restore path failed: '
          'taskId=${task.taskId} error=$e',
        );
      }

      // 文件已经不存在

      if (!_isFileAvailable(savedPath)) {
        debugPrint(
          '[DownloadService] restore: file missing, '
          'delete stale record '
          'songId=${meta.songId} '
          'taskId=${task.taskId} '
          'path=$savedPath',
        );

        await _deleteTaskRecord(task.taskId);

        _taskIdToSongId.remove(task.taskId);

        continue;
      }

      // 检查实际格式 + 修正扩展名

      final fileType = await _detectAudioFileType(savedPath!);

      if (fileType == null) {
        debugPrint(
          '[DownloadService] restore: unsupported audio format '
          'songId=${meta.songId} path=$savedPath',
        );

        await _deleteTaskRecord(task.taskId);
        _taskIdToSongId.remove(task.taskId);

        continue;
      }

      // 修正文件名

      final normalizedPath = await _normalizeExistingFile(
        savedPath,
        meta.song,
        fileType,
      );

      if (normalizedPath == null) {
        debugPrint(
          '[DownloadService] restore: failed to normalize file '
          'songId=${meta.songId} path=$savedPath',
        );

        await _deleteTaskRecord(task.taskId);
        _taskIdToSongId.remove(task.taskId);

        continue;
      }

      tasks[meta.songId] = DownloadTaskView(
        taskId: task.taskId,
        songId: meta.songId,
        song: meta.song,
        status: _mapStatus(record.status),
        progress: record.progress,
        savedPath: normalizedPath,
      );
    }
  }

  // Download

  Future<bool> download(Song song) async {
    final songId = song.id;

    debugPrint(
      '[DownloadService] download() called '
      'songId=$songId '
      'title=${song.title}',
    );

    try {
      final existing = tasks[songId];

      if (existing != null) {
        // 已完成

        if (existing.status == DownloadStatus.complete) {
          final savedPath = existing.savedPath;

          if (_isFileAvailable(savedPath)) {
            return true;
          }

          debugPrint(
            '[DownloadService] completed task has missing file, '
            'resetting '
            'songId=$songId '
            'taskId=${existing.taskId}',
          );

          await _removeStaleTask(songId: songId, taskId: existing.taskId);
        }
        // 正在下载
        else if (existing.status != DownloadStatus.failed &&
            existing.status != DownloadStatus.canceled &&
            existing.status != DownloadStatus.notFound) {
          return false;
        }
        // 失败 / 取消 / 404
        else {
          await remove(songId);
        }
      }

      // 获取 URL

      final url = await _songRepo.fetchSongUrl(songId);

      debugPrint('[DownloadService] fetchSongUrl result url=$url');

      if (url == null) {
        tasks[songId] = DownloadTaskView(
          taskId: '',
          songId: songId,
          song: song,
          status: DownloadStatus.failed,
          errorMessage: '无法获取下载链接 (可能需要登录)',
        );

        return false;
      }

      // 临时文件名:不要在这里写 .mp3 —— 网易云返回的真实格式可能是 FLAC,
      // 完成后根据文件头判断真正格式,最终是 `歌曲 - 歌手.mp3` / `歌曲 - 歌手.flac`。
      final baseName = _buildBaseFileName(song);

      final temporaryFilename = '$baseName.download';

      // Construct task

      final DownloadTask task;

      if (_isAndroid) {
        task = DownloadTask(
          url: url,
          filename: temporaryFilename,
          baseDirectory: BaseDirectory.temporary,
          group: _group,
          retries: 3,
          allowPause: true,
          metaData: _encodeMeta(songId, song),
        );
      } else {
        final dir = _desktopDownloadsDir;

        if (dir == null) {
          tasks[songId] = DownloadTaskView(
            taskId: '',
            songId: songId,
            song: song,
            status: DownloadStatus.failed,
            errorMessage: '无法获取桌面 Downloads 目录',
          );

          return false;
        }

        task = DownloadTask(
          url: url,
          filename: temporaryFilename,
          baseDirectory: BaseDirectory.root,
          directory: dir,
          group: _group,
          retries: 3,
          metaData: _encodeMeta(songId, song),
        );
      }

      debugPrint(
        '[DownloadService] enqueue '
        'url=$url '
        'filename=${task.filename}',
      );

      // enqueue

      final enqueued = await _downloader.enqueue(task);

      debugPrint(
        '[DownloadService] enqueue returned '
        '$enqueued taskId=${task.taskId}',
      );

      if (!enqueued) {
        tasks[songId] = DownloadTaskView(
          taskId: task.taskId,
          songId: songId,
          song: song,
          status: DownloadStatus.failed,
          errorMessage: 'enqueue 返回 false (FileDownloader 未就绪)',
        );

        return false;
      }

      _taskIdToSongId[task.taskId] = songId;

      tasks[songId] = DownloadTaskView(
        taskId: task.taskId,
        songId: songId,
        song: song,
        status: DownloadStatus.enqueued,
      );

      return true;
    } catch (e, st) {
      debugPrint('[DownloadService] download() EXCEPTION: $e\n$st');

      tasks[songId] = DownloadTaskView(
        taskId: '',
        songId: songId,
        song: song,
        status: DownloadStatus.failed,
        errorMessage: '下载异常: $e',
      );

      return false;
    }
  }

  // Remove

  Future<void> remove(String songId) async {
    final view = tasks[songId];

    if (view == null) {
      return;
    }

    final taskId = view.taskId;

    if (taskId.isNotEmpty) {
      try {
        await _downloader.cancelTaskWithId(taskId);
      } catch (e) {
        debugPrint(
          '[DownloadService] cancelTaskWithId failed: '
          'taskId=$taskId error=$e',
        );
      }

      await _deleteTaskRecord(taskId);

      _taskIdToSongId.remove(taskId);
    }

    tasks.remove(songId);
  }

  // Clear finished

  Future<void> clearFinished() async {
    final toRemove = <String>[];

    for (final entry in tasks.entries) {
      final status = entry.value.status;

      if (status == DownloadStatus.complete ||
          status == DownloadStatus.failed ||
          status == DownloadStatus.notFound ||
          status == DownloadStatus.canceled) {
        toRemove.add(entry.key);
      }
    }

    for (final songId in toRemove) {
      final view = tasks.remove(songId);

      if (view == null) {
        continue;
      }

      final taskId = view.taskId;

      if (taskId.isNotEmpty) {
        await _deleteTaskRecord(taskId);
        _taskIdToSongId.remove(taskId);
      }
    }
  }

  // callbacks

  void _onStatus(TaskStatusUpdate update) {
    debugPrint(
      '[DownloadService] _onStatus: '
      'taskId=${update.task.taskId} '
      'status=${update.status} '
      'exception=${update.exception}',
    );

    final taskId = update.task.taskId;

    final songId = _taskIdToSongId[taskId];

    if (songId == null) {
      return;
    }

    final existing = tasks[songId];

    if (existing == null) {
      return;
    }

    final newStatus = _mapStatus(update.status);

    if (newStatus == DownloadStatus.complete) {
      unawaited(
        _finalizeDownload(update.task as DownloadTask, songId, existing),
      );

      return;
    }

    tasks[songId] = existing.copyWith(
      status: newStatus,
      errorMessage: newStatus == DownloadStatus.failed
          ? update.exception?.description
          : null,
      clearError: newStatus != DownloadStatus.failed,
    );
  }

  void _onProgress(TaskProgressUpdate update) {
    final taskId = update.task.taskId;

    final songId = _taskIdToSongId[taskId];

    if (songId == null) {
      return;
    }

    final existing = tasks[songId];

    if (existing == null) {
      return;
    }

    tasks[songId] = existing.copyWith(
      progress: update.progress.clamp(0.0, 1.0),
    );
  }

  // Finalize

  Future<void> _finalizeDownload(
    DownloadTask task,
    String songId,
    DownloadTaskView existing,
  ) async {
    try {
      // 找到下载后的临时文件

      final temporaryPath = await task.filePath();

      if (!_isFileAvailable(temporaryPath)) {
        debugPrint(
          '[DownloadService] finalize: '
          'temporary file missing '
          'songId=$songId '
          'path=$temporaryPath',
        );

        await _removeStaleTask(songId: songId, taskId: task.taskId);

        return;
      }

      // 判断真实格式

      final fileType = await _detectAudioFileType(temporaryPath);

      if (fileType == null) {
        debugPrint(
          '[DownloadService] finalize: '
          'unknown audio format '
          'songId=$songId '
          'path=$temporaryPath',
        );

        await _deleteTaskRecord(task.taskId);
        _taskIdToSongId.remove(task.taskId);
        tasks.remove(songId);

        return;
      }

      final extension = fileType.extension;
      final mimeType = fileType.mimeType;

      final finalBaseName = _buildBaseFileName(existing.song);

      final finalFileName = '$finalBaseName.$extension';

      debugPrint(
        '[DownloadService] detected format: '
        'songId=$songId '
        'type=$fileType '
        'filename=$finalFileName',
      );

      // Android

      if (_isAndroid) {
        // background_downloader 的 SharedStorage 支持 mimeType —— 即使 task 的
        // 临时文件是 `xxx.download`,移入 Downloads 时系统也能按真实 MIME 类型
        // 处理最终文件。
        final sharedPath = await _downloader.moveToSharedStorage(
          task,
          SharedStorage.downloads,
          mimeType: mimeType,
        );

        if (sharedPath == null || sharedPath.isEmpty) {
          debugPrint(
            '[DownloadService] finalize: '
            'moveToSharedStorage failed '
            'songId=$songId',
          );

          tasks[songId] = existing.copyWith(
            status: DownloadStatus.failed,
            progress: 1.0,
            savedPath: null,
            errorMessage: '移动到公共 Downloads 失败',
            clearError: false,
          );

          return;
        }

        debugPrint(
          '[DownloadService] Android shared path: '
          '$sharedPath',
        );

        // Android 返回的路径就是 SharedStorage 中实际文件路径。如果插件因为
        // MIME 类型没有自动得到目标文件名,尝试把它改成 `歌曲 - 歌手.flac`
        // 或 `歌曲 - 歌手.mp3`。

        final normalizedPath = await _normalizeAndroidSharedPath(
          sharedPath,
          finalFileName,
        );

        if (normalizedPath == null) {
          debugPrint(
            '[DownloadService] finalize: '
            'Android shared file unavailable '
            'songId=$songId',
          );

          await _removeStaleTask(songId: songId, taskId: task.taskId);

          return;
        }

        tasks[songId] = existing.copyWith(
          status: DownloadStatus.complete,
          progress: 1.0,
          savedPath: normalizedPath,
          errorMessage: null,
          clearError: true,
        );

        return;
      }

      // Desktop

      final normalizedPath = await _normalizeDesktopFile(
        temporaryPath,
        finalFileName,
      );

      if (normalizedPath == null) {
        debugPrint(
          '[DownloadService] finalize: '
          'desktop rename failed '
          'songId=$songId',
        );

        await _removeStaleTask(songId: songId, taskId: task.taskId);

        return;
      }

      if (!_isFileAvailable(normalizedPath)) {
        debugPrint(
          '[DownloadService] finalize: '
          'desktop final file missing '
          'songId=$songId '
          'path=$normalizedPath',
        );

        await _removeStaleTask(songId: songId, taskId: task.taskId);

        return;
      }

      tasks[songId] = existing.copyWith(
        status: DownloadStatus.complete,
        progress: 1.0,
        savedPath: normalizedPath,
        errorMessage: null,
        clearError: true,
      );
    } catch (e, st) {
      debugPrint(
        '[DownloadService] _finalizeDownload EXCEPTION: '
        '$e\n$st',
      );

      tasks[songId] = existing.copyWith(
        status: DownloadStatus.failed,
        progress: 1.0,
        savedPath: null,
        errorMessage: '保存下载文件失败: $e',
        clearError: false,
      );
    }
  }

  // Audio type detection

  /// 只识别：
  ///
  ///   FLAC
  ///   MP3
  ///
  /// 返回 null 表示不是支持的格式。
  Future<_AudioFileType?> _detectAudioFileType(String path) async {
    final file = File(path);

    if (!await file.exists()) {
      return null;
    }

    try {
      final raf = await file.open();

      try {
        final header = await raf.read(12);

        if (header.length >= 4) {
          // FLAC
          //
          // 66 4C 61 43
          // f  L  a  C
          // ---------------------------------------------------------------

          if (header[0] == 0x66 &&
              header[1] == 0x4C &&
              header[2] == 0x61 &&
              header[3] == 0x43) {
            return _AudioFileType.flac;
          }

          // MP3: ID3
          //
          // 49 44 33
          // I  D  3
          // ---------------------------------------------------------------

          if (header.length >= 3 &&
              header[0] == 0x49 &&
              header[1] == 0x44 &&
              header[2] == 0x33) {
            return _AudioFileType.mp3;
          }

          // MP3: MPEG audio frame sync
          //
          // 常见 MPEG1/2 Layer III：
          //
          // 11111111 111xxxxx
          // ---------------------------------------------------------------

          if (header.length >= 2 &&
              header[0] == 0xFF &&
              (header[1] & 0xE0) == 0xE0) {
            return _AudioFileType.mp3;
          }
        }

        return null;
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint(
        '[DownloadService] detect audio type failed: '
        'path=$path error=$e',
      );

      return null;
    }
  }

  // Filename

  /// 构造：
  ///
  ///   歌曲名字 - 歌手
  String _buildBaseFileName(Song song) {
    final title = _sanitizeFileNamePart(song.title);

    final artist = _sanitizeFileNamePart(_getArtistName(song));

    if (artist.isEmpty) {
      return title.isEmpty ? song.id : title;
    }

    if (title.isEmpty) {
      return artist;
    }

    return '$title - $artist';
  }

  /// 这里是唯一需要根据你的 Song 模型调整的地方。
  ///
  /// 当前假设：
  ///
  ///   Song.artist
  ///
  /// 如果你的 Song 实际字段不是 artist，
  /// 只需要改这一处。
  String _getArtistName(Song song) {
    return song.artist;
  }

  /// 清理 Windows / Android / Linux / macOS 常见非法文件名字符。
  String _sanitizeFileNamePart(String value) {
    var result = value.trim();

    if (result.isEmpty) {
      return '';
    }

    result = result.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    // 控制字符
    result = result.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');

    // 避免末尾的空格和点
    result = result.replaceFirst(RegExp(r'[ .]+$'), '');

    // Windows 保留名称
    if (_isWindowsReservedName(result)) {
      result = '_$result';
    }

    // 防止名字过长。
    //
    // 这里不截到很短，只限制单个字段。
    if (result.length > 180) {
      result = result.substring(0, 180).trim();
    }

    return result;
  }

  bool _isWindowsReservedName(String value) {
    final upper = value.toUpperCase();

    return upper == 'CON' ||
        upper == 'PRN' ||
        upper == 'AUX' ||
        upper == 'NUL' ||
        RegExp(r'^COM[1-9]$').hasMatch(upper) ||
        RegExp(r'^LPT[1-9]$').hasMatch(upper);
  }

  // Desktop normalize

  Future<String?> _normalizeDesktopFile(
    String sourcePath,
    String finalFileName,
  ) async {
    try {
      final source = File(sourcePath);

      if (!await source.exists()) {
        return null;
      }

      final targetPath = _joinPath(source.parent.path, finalFileName);

      // 已经是目标文件
      if (source.path == targetPath) {
        return source.path;
      }

      final target = File(targetPath);

      // 如果存在旧文件，删除它。
      //
      // 这里采用覆盖策略。
      if (await target.exists()) {
        await target.delete();
      }

      final renamed = await source.rename(targetPath);

      return renamed.path;
    } catch (e) {
      debugPrint(
        '[DownloadService] normalizeDesktopFile failed: '
        '$e',
      );

      return null;
    }
  }

  // Android normalize

  Future<String?> _normalizeAndroidSharedPath(
    String sharedPath,
    String finalFileName,
  ) async {
    try {
      // Android 29+ SharedStorage 有可能返回 content:// URI。
      //
      // 这种情况下不能用 dart:io File 去 rename。
      if (sharedPath.startsWith('content://')) {
        debugPrint(
          '[DownloadService] Android returned content URI: '
          '$sharedPath',
        );

        // moveToSharedStorage 已经根据 mimeType 写入 SharedStorage。
        //
        // 此时不能通过 dart:io 修改 content URI。
        // 直接返回插件提供的 URI。
        return sharedPath;
      }

      final source = File(sharedPath);

      if (!await source.exists()) {
        return null;
      }

      final parent = source.parent.path;

      final targetPath = _joinPath(parent, finalFileName);

      if (source.path == targetPath) {
        return source.path;
      }

      final target = File(targetPath);

      if (await target.exists()) {
        await target.delete();
      }

      final renamed = await source.rename(targetPath);

      return renamed.path;
    } catch (e) {
      debugPrint(
        '[DownloadService] normalizeAndroidSharedPath failed: '
        '$e',
      );

      // 如果 SharedStorage 本身已经成功，
      // 至少保留插件返回的路径。
      return sharedPath;
    }
  }

  // Restore shared storage path

  Future<String?> _restoreSavedPath(DownloadTask task) async {
    // Desktop

    if (!_isAndroid) {
      return await task.filePath();
    }

    // Android:moveToSharedStorage 后 task.filePath() 指向的是原来的 temporary
    // 文件,而实际文件已经进入 SharedStorage —— 用 background_downloader 的
    // pathInSharedStorage() 获取共享存储路径,优先用 task.filename。

    try {
      final path = await _downloader.pathInSharedStorage(
        task.filename,
        SharedStorage.downloads,
      );

      if (path != null && path.isNotEmpty) {
        return path;
      }
    } catch (e) {
      debugPrint(
        '[DownloadService] pathInSharedStorage failed: '
        'taskId=${task.taskId} error=$e',
      );
    }

    // 兼容仍然存在 temporary 文件的情况。
    return await task.filePath();
  }

  // Existing file normalization

  Future<String?> _normalizeExistingFile(
    String path,
    Song song,
    _AudioFileType type,
  ) async {
    if (path.startsWith('content://')) {
      return path;
    }

    final file = File(path);

    if (!await file.exists()) {
      return null;
    }

    final finalName = '${_buildBaseFileName(song)}.${type.extension}';

    final currentName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : '';

    if (currentName == finalName) {
      return file.path;
    }

    // Android SharedStorage 的路径可能并不允许 Dart File rename。
    // Desktop / 普通文件路径可以直接 rename。
    try {
      final targetPath = _joinPath(file.parent.path, finalName);

      final target = File(targetPath);

      if (await target.exists()) {
        await target.delete();
      }

      final renamed = await file.rename(targetPath);

      return renamed.path;
    } catch (e) {
      debugPrint(
        '[DownloadService] normalizeExistingFile rename failed: '
        'path=$path error=$e',
      );

      // 原文件仍然存在的话，至少可以继续作为已下载文件。
      if (await file.exists()) {
        return file.path;
      }

      return null;
    }
  }

  // Path

  String _joinPath(String directory, String filename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$filename';
    }

    return '$directory${Platform.pathSeparator}$filename';
  }

  // File existence

  bool _isFileAvailable(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }

    // Android MediaStore URI 不能通过 File.existsSync 判断。
    if (path.startsWith('content://')) {
      return true;
    }

    try {
      return File(path).existsSync();
    } catch (e) {
      debugPrint(
        '[DownloadService] exists check failed: '
        'path=$path error=$e',
      );

      return false;
    }
  }

  // Stale task

  Future<void> _removeStaleTask({
    required String songId,
    required String taskId,
  }) async {
    debugPrint(
      '[DownloadService] removing stale task: '
      'songId=$songId '
      'taskId=$taskId',
    );

    if (taskId.isNotEmpty) {
      await _deleteTaskRecord(taskId);

      _taskIdToSongId.remove(taskId);
    }

    tasks.remove(songId);
  }

  // Database

  Future<void> _deleteTaskRecord(String taskId) async {
    if (taskId.isEmpty) {
      return;
    }

    try {
      await _downloader.database.deleteRecordWithId(taskId);

      debugPrint(
        '[DownloadService] database record deleted: '
        'taskId=$taskId',
      );
    } catch (e, st) {
      debugPrint(
        '[DownloadService] deleteTaskRecord failed: '
        'taskId=$taskId '
        'error=$e\n$st',
      );
    }
  }

  // Status

  DownloadStatus _mapStatus(TaskStatus s) {
    switch (s) {
      case TaskStatus.enqueued:
        return DownloadStatus.enqueued;

      case TaskStatus.running:
        return DownloadStatus.running;

      case TaskStatus.complete:
        return DownloadStatus.complete;

      case TaskStatus.notFound:
        return DownloadStatus.notFound;

      case TaskStatus.failed:
        return DownloadStatus.failed;

      case TaskStatus.canceled:
        return DownloadStatus.canceled;

      case TaskStatus.waitingToRetry:
        return DownloadStatus.waitingToRetry;

      case TaskStatus.paused:
        return DownloadStatus.running;
    }
  }

  // Metadata

  String _encodeMeta(String songId, Song song) {
    return jsonEncode({'songId': songId, 'song': song.toJson()});
  }

  _Meta? _parseMeta(String raw) {
    if (raw.isEmpty) {
      return null;
    }

    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;

      final songId = m['songId'] as String?;
      final songRaw = m['song'];

      if (songId == null || songRaw == null) {
        return null;
      }

      final songMap = songRaw is Map<String, dynamic>
          ? songRaw
          : Map<String, dynamic>.from(songRaw as Map);

      return _Meta(songId: songId, song: Song.fromJson(songMap));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] parseMeta failed: $e');
      }

      return null;
    }
  }

  // Lifecycle

  @override
  void onClose() {
    // FileDownloader 是 singleton。
    //
    // 不在这里 close。
    super.onClose();
  }
}

// Audio type

enum _AudioFileType {
  mp3,
  flac;

  String get extension {
    switch (this) {
      case _AudioFileType.mp3:
        return 'mp3';

      case _AudioFileType.flac:
        return 'flac';
    }
  }

  String get mimeType {
    switch (this) {
      case _AudioFileType.mp3:
        return 'audio/mpeg';

      case _AudioFileType.flac:
        return 'audio/flac';
    }
  }
}

// Metadata

class _Meta {
  final String songId;
  final Song song;

  _Meta({required this.songId, required this.song});
}
