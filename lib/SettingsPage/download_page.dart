import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/download_task_view.dart';
import '../services/download_service.dart';
import '../models/default.dart';

/// 下载详情页 —— 列出所有下载任务 + 进度 / 状态 / 文件大小。
///
/// **设计**:订阅 `DownloadService.tasks` (按 songId 索引的 RxMap),状态
/// 变化自动 rebuild。**不持有任何本地状态**,只纯转发 service 的 Rx。
///
/// 列表项交互:
/// - 完成的: 显示大小 + "打开" 按钮 (调到文件管理器, 本期先不做)
/// - 失败的: 显示错误信息 + 重试按钮 (后续扩展)
/// - 下载中: 显示进度条 + 取消按钮
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Get.back(id: DefaultValues.shellNavigatorId);
          },
        ),
        title: const Text('下载状态'),
        actions: [
          // 清空终态 (已下载 / 失败 / 取消)
          IconButton(
            tooltip: '清空已完成',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () {
              Get.find<DownloadService>().clearFinished();
            },
          ),
        ],
      ),
      body: const _DownloadList(),
    );
  }
}

class _DownloadList extends StatelessWidget {
  const _DownloadList();

  @override
  Widget build(BuildContext context) {
    final svc = Get.find<DownloadService>();
    return Obx(() {
      // listViewKey 随列表长度变化 → ListView 重置滚动到顶部 (新增任务时)
      final entries = svc.tasks.entries.toList();
      if (entries.isEmpty) {
        return const Center(child: Text('暂无下载'));
      }
      return ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final view = entries[index].value;
          return _DownloadTile(view: view);
        },
      );
    });
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.view});

  final DownloadTaskView view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: _StatusIcon(view: view, color: scheme.primary),

      title: Text(
        view.song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _StatusLine(view: view),
      trailing:
          view.status == DownloadStatus.complete ||
              view.status == DownloadStatus.failed ||
              view.status == DownloadStatus.canceled ||
              view.status == DownloadStatus.notFound
          ? IconButton(
              tooltip: '移除',
              icon: const Icon(Icons.close),
              onPressed: () {
                Get.find<DownloadService>().remove(view.songId);
              },
            )
          : IconButton(
              tooltip: '取消',
              icon: const Icon(Icons.close),
              onPressed: () {
                Get.find<DownloadService>().remove(view.songId);
              },
            ),
    );
  }
}

/// 状态图标 + 进度。下载中显示半圆环,完成/失败/取消显示对应图标。
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.view, required this.color});

  final DownloadTaskView view;
  final Color color;

  @override
  Widget build(BuildContext context) {
    switch (view.status) {
      case DownloadStatus.complete:
        return Icon(Icons.check_circle, color: color);
      case DownloadStatus.failed:
        return const Icon(Icons.error_outline, color: Colors.redAccent);
      case DownloadStatus.canceled:
        return const Icon(Icons.cancel_outlined);
      case DownloadStatus.notFound:
        return const Icon(Icons.help_outline);
      case DownloadStatus.enqueued:
      case DownloadStatus.waitingToRetry:
        return const Icon(Icons.schedule);
      case DownloadStatus.running:
        return Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: view.progress > 0 ? view.progress : null,
                color: color,
              ),
            ),
            Text('${(view.progress * 100).toInt()}'),
          ],
        );
    }
  }
}

/// 副标题:艺人名 + 状态文字 + (错误时)错误信息 + (完成时)保存路径。
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.view});

  final DownloadTaskView view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).textTheme;
    final statusText = _statusLabel(view.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${view.song.artist} · $statusText'),
        if (view.savedPath != null)
          Text(
            view.savedPath!,
            style: scheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (view.errorMessage != null)
          Text(
            view.errorMessage!,
            style: scheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (view.status == DownloadStatus.running)
          LinearProgressIndicator(value: view.progress),
      ],
    );
  }

  String _statusLabel(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.enqueued:
        return '等待中';
      case DownloadStatus.running:
        return '下载中';
      case DownloadStatus.complete:
        return '已完成';
      case DownloadStatus.failed:
        return '失败';
      case DownloadStatus.notFound:
        return '资源不存在';
      case DownloadStatus.canceled:
        return '已取消';
      case DownloadStatus.waitingToRetry:
        return '等待重试';
    }
  }
}
