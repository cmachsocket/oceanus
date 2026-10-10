import 'Song.dart';

/// 一首歌的下载状态。[DownloadService] 持有
/// `RxMap<String songId, DownloadTaskView>` 作为 UI 真相源。
///
/// 存 songId + 反序列化的 [Song] 而不是 Song 引用:background_downloader 的
/// database 只有 taskId + metaData,重启后要靠它还原标题/艺人。
class DownloadTaskView {
  /// background_downloader 的 taskId(业务无关的底层句柄,仅 DownloadService
  /// 内部用于 cancel)。
  final String taskId;

  /// 网易云歌曲 id,跨重启稳定,UI 用它做 key。
  final String songId;

  /// 持久化只存 JSON 字符串,启动后从 metaData 反序列化。
  final Song song;

  /// 映射自 background_downloader 的 TaskStatus,但不复用它的 enum:
  /// 业务侧不依赖 SDK 的 enum,自家 enum 以后好加"已过期待重下"之类的新状态。
  final DownloadStatus status;

  /// 0..1,失败 / 取消 / 未开始时为 0。
  final double progress;

  final String? errorMessage;

  /// 完成后的绝对路径,用于"打开文件夹" / 本地播放。
  final String? savedPath;

  const DownloadTaskView({
    required this.taskId,
    required this.songId,
    required this.song,
    required this.status,
    this.progress = 0,
    this.errorMessage,
    this.savedPath,
  });

  DownloadTaskView copyWith({
    String? taskId,
    DownloadStatus? status,
    double? progress,
    String? errorMessage,
    String? savedPath,
    bool clearError = false,
    bool clearSavedPath = false,
  }) {
    return DownloadTaskView(
      taskId: taskId ?? this.taskId,
      songId: songId,
      song: song,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      savedPath: clearSavedPath ? null : (savedPath ?? this.savedPath),
    );
  }
}

/// UI 层用的简化状态枚举。与 background_downloader 的 TaskStatus 一一对应
/// (不含 paused:业务上不主动暂停,失败 / 取消 / 完成都是终态)。
enum DownloadStatus {
  /// 等待 native 调度(排队 / 等待网络)
  enqueued,

  running,
  complete,

  /// 服务器 404 / 文件不存在
  notFound,

  failed,

  canceled,

  /// 失败后等待重试(background_downloader 内置退避)
  waitingToRetry,
}
