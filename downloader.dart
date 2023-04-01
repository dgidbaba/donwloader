import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:android_path_provider/android_path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:nb_utils/nb_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:streamit_flutter/main.dart';
import 'package:streamit_flutter/models/DownloadData.dart';
import 'package:streamit_flutter/utils/AppWidgets.dart';
import 'package:streamit_flutter/utils/Common.dart';
import 'package:streamit_flutter/utils/Constants.dart';
import 'package:streamit_flutter/utils/resources/Colors.dart';
import 'package:streamit_flutter/utils/resources/Images.dart';

class DownloadVideoFromLinkWidget extends StatefulWidget with WidgetsBindingObserver {
  final String videoName;
  final String videoLink;
  final String videoId;
  final String videoImage;
  final String videoDescription;
  final String videoDuration;

  const DownloadVideoFromLinkWidget({
    super.key,
    required this.videoName,
    required this.videoLink,
    required this.videoId,
    required this.videoImage,
    required this.videoDescription,
    required this.videoDuration,
  });

  @override
  _DownloadVideoFromLinkWidgetState createState() => _DownloadVideoFromLinkWidgetState();
}

class _DownloadVideoFromLinkWidgetState extends State<DownloadVideoFromLinkWidget> {
  TaskInfo? _tasks;
  late ItemHolder _items;
  late bool _showContent;
  late bool _permissionReady;
  late String _localPath;
  final ReceivePort _port = ReceivePort();
  bool isFileDownloaded = false;

  @override
  void initState() {
    super.initState();
    _bindBackgroundIsolate();

    FlutterDownloader.registerCallback(downloadCallback, step: 1);

    _showContent = false;
    _permissionReady = false;
    _prepare();
  }

  @override
  void dispose() {
    if (_tasks!.status == DownloadTaskStatus.failed) {
      _delete(_tasks!);
    }
    _unbindBackgroundIsolate();
    super.dispose();
  }

  void _bindBackgroundIsolate() {
    final isSuccess = IsolateNameServer.registerPortWithName(
      _port.sendPort,
      'downloader_send_port',
    );
    if (!isSuccess) {
      _unbindBackgroundIsolate();
      _bindBackgroundIsolate();
      return;
    }
    _port.listen((dynamic data) {
      final taskId = (data as List<dynamic>)[0] as String;
      final status = DownloadTaskStatus(data[1] as int);
      final progress = data[2] as int;

      print(
        'Callback on UI isolate: '
        'task ($taskId) is in status ($status) and process ($progress)',
      );

      if (_tasks != null) {
        final task = _tasks!;
        setState(() {
          task
            ..status = status
            ..progress = progress;
        });
      }
    });
  }

  void _unbindBackgroundIsolate() {
    IsolateNameServer.removePortNameMapping('downloader_send_port');
  }

  @pragma('vm:entry-point')
  static void downloadCallback(
    String id,
    DownloadTaskStatus status,
    int progress,
  ) {
    print(
      'Callback on background isolate: '
      'task ($id) is in status ($status) and process ($progress)',
    );

    IsolateNameServer.lookupPortByName('downloader_send_port')?.send([id, status.value, progress]);
  }

  Widget _buildNoPermissionWarning() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Grant storage permission to continue',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.blueGrey, fontSize: 18),
            ),
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: _retryRequestPermission,
            child: const Text(
              'Retry',
              style: TextStyle(
                color: colorPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          )
        ],
      ),
    );
  }

  Future<void> _retryRequestPermission() async {
    final hasGranted = await _checkPermission();

    if (hasGranted) {
      await _prepareSaveDir();
    }

    setState(() {
      _permissionReady = hasGranted;
    });
  }

  Future<void> _requestDownload(TaskInfo task) async {
    task.taskId = await FlutterDownloader.enqueue(
      url: task.link!,
      headers: {'auth': 'test_for_sql_encoding'},
      savedDir: _localPath,
      saveInPublicStorage: true,
    ).then((value) async {
      DownloadData data = DownloadData();
      data.id = widget.videoId.toInt();
      data.title = widget.videoName;
      data.image = widget.videoImage;
      data.description = widget.videoDescription;
      data.duration = widget.videoDuration;
      data.userId = getIntAsync(USER_ID);
      data.filePath = (await _getSavedDir()).toString() + "/" + (widget.videoLink.split("/").last);
      data.isDeleted = false;
      log(data.toJson());
      addOrRemoveFromLocalStorage(data);
      return "";
    });
  }

  Future<void> _pauseDownload(TaskInfo task) async {
    await FlutterDownloader.pause(taskId: task.taskId!);
  }

  Future<void> _resumeDownload(TaskInfo task) async {
    final newTaskId = await FlutterDownloader.resume(taskId: task.taskId!);
    task.taskId = newTaskId;
  }

  Future<void> _retryDownload(TaskInfo task) async {
    final newTaskId = await FlutterDownloader.retry(taskId: task.taskId!);
    task.taskId = newTaskId;
  }

  Future<bool> _openDownloadedFile(TaskInfo? task) async {
    final taskId = task?.taskId;
    if (taskId == null) {
      return false;
    }

    return FlutterDownloader.open(taskId: taskId);
  }

  Future<void> _delete(TaskInfo task) async {
    await FlutterDownloader.remove(
      taskId: task.taskId!,
      shouldDeleteContent: true,
    );
    await _prepare();
    setState(() {});
  }

  Future<bool> _checkPermission() async {
    if (Platform.isIOS) {
      return true;
    }

    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt > 28) {
        return true;
      }

      final status = await Permission.storage.status;
      if (status == PermissionStatus.granted) {
        return true;
      }

      final result = await Permission.storage.request();
      return result == PermissionStatus.granted;
    }

    throw StateError('unknown platform');
  }

  Future<void> _prepare() async {
    final tasks = await FlutterDownloader.loadTasks();

    if (tasks == null) {
      print('No tasks were retrieved from the database.');
      return;
    }

    _tasks = TaskInfo(name: widget.videoName, link: widget.videoLink);

    _items = ItemHolder(name: _tasks!.name, task: _tasks!);
    if (!isFileDownloaded) {
      _items.task?.status = DownloadTaskStatus.undefined;
    }
    for (final task in tasks) {
      if (_tasks!.link == task.url) {
        _tasks!
          ..taskId = task.taskId
          ..status = task.status
          ..progress = task.progress;
      }
    }

    _permissionReady = await _checkPermission();
    if (_permissionReady) {
      await _prepareSaveDir();
    }

    setState(() {
      _showContent = true;
    });
  }
  

  Future<void> _prepareSaveDir() async {
    _localPath = (await _getSavedDir())!;
    final savedDir = Directory(_localPath);
    if (!savedDir.existsSync()) {
      await savedDir.create();
    }
  }

  Future<String?> _getSavedDir() async {
    String? externalStorageDirPath;

    if (Platform.isAndroid) {
      try {
        externalStorageDirPath = await AndroidPathProvider.downloadsPath;
      } catch (err, st) {
        print('failed to get downloads path: $err, $st');

        final directory = await getExternalStorageDirectory();
        externalStorageDirPath = directory?.path;
      }
    } else if (Platform.isIOS) {
      externalStorageDirPath = (await getApplicationDocumentsDirectory()).absolute.path;
    }
    return externalStorageDirPath;
  }

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (_) {
      if (!_showContent) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return _permissionReady
          ? DownloadListItem(
              data: _items,
              onTap: (task) async {
                final success = await _openDownloadedFile(task);
                if (!success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cannot open this file'),
                    ),
                  );
                }
              },
              onActionTap: (task) {
                if (task.status == DownloadTaskStatus.undefined) {
                  _requestDownload(task);
                } else if (task.status == DownloadTaskStatus.running) {
                  _pauseDownload(task);
                } else if (task.status == DownloadTaskStatus.paused) {
                  _resumeDownload(task);
                } else if (task.status == DownloadTaskStatus.complete || task.status == DownloadTaskStatus.canceled) {
                  _delete(task);
                } else if (task.status == DownloadTaskStatus.failed) {
                  _retryDownload(task);
                }
              },
              onCancel: _delete,
            )
          : _buildNoPermissionWarning();
    });
  }
}

class ItemHolder {
  ItemHolder({this.name, this.task});

  final String? name;
  final TaskInfo? task;
}

class TaskInfo {
  TaskInfo({this.name, this.link});

  final String? name;
  final String? link;

  String? taskId;
  int? progress = 0;
  DownloadTaskStatus? status = DownloadTaskStatus.undefined;
}

class DownloadListItem extends StatelessWidget {
  const DownloadListItem({
    super.key,
    this.data,
    this.onTap,
    this.onActionTap,
    this.onCancel,
  });

  final ItemHolder? data;
  final Function(TaskInfo?)? onTap;
  final Function(TaskInfo)? onActionTap;
  final Function(TaskInfo)? onCancel;

  @override
  Widget build(BuildContext context) {
    final task = data!.task!;
    return InkWell(
      onTap: data!.task!.status == DownloadTaskStatus.complete
          ? () {
              onTap!(data!.task);
            }
          : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (task.status == DownloadTaskStatus.undefined)
            ClipRRect(
              borderRadius: BorderRadius.circular(50),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Container(
                  padding: EdgeInsets.all(8),
                  color: colorPrimary.withOpacity(0.2),
                  child: commonCacheImageWidget(ic_download, color: colorPrimary, width: 24, height: 24),
                ),
              ),
            ).onTap(() {
              onActionTap?.call(task);
            })
          else if (task.status == DownloadTaskStatus.running)
            Row(
              children: [
                Text('${task.progress}%', style: primaryTextStyle(size: 14, color: colorPrimary)),
                IconButton(
                  onPressed: () => onActionTap?.call(task),
                  constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                  icon: const Icon(Icons.pause, color: colorPrimary),
                  tooltip: 'Pause',
                ),
              ],
            )
          else if (task.status == DownloadTaskStatus.paused)
            Row(
              children: [
                Text(
                  '${task.progress}%',
                  style: primaryTextStyle(size: 14, color: colorPrimary),
                ),
                IconButton(
                  onPressed: () => onActionTap?.call(task),
                  constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                  icon: const Icon(Icons.play_arrow, color: colorPrimary),
                  tooltip: 'Resume',
                ),
                if (onCancel != null)
                  IconButton(
                    onPressed: () => onCancel?.call(task),
                    constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                    icon: const Icon(Icons.close, color: Colors.red),
                    tooltip: 'Cancel',
                  ),
              ],
            )
          else if (task.status == DownloadTaskStatus.complete)
            IconButton(
              onPressed: () => onActionTap?.call(task),
              constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
              icon: const Icon(Icons.delete),
              tooltip: 'Delete',
            )
          else if (task.status == DownloadTaskStatus.canceled)
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('Canceled', style: TextStyle(color: Colors.red)),
                if (onActionTap != null)
                  IconButton(
                    onPressed: () => onActionTap?.call(task),
                    constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                    icon: const Icon(Icons.cancel),
                    tooltip: 'Cancel',
                  )
              ],
            )
          else if (task.status == DownloadTaskStatus.failed)
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('Failed', style: TextStyle(color: colorPrimary)),
                IconButton(
                  onPressed: () => onActionTap?.call(task),
                  constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
                  icon: const Icon(Icons.refresh, color: colorPrimary),
                  tooltip: 'Refresh',
                )
              ],
            )
          else if (task.status == DownloadTaskStatus.enqueued)
            const Text('Pending', style: TextStyle(color: colorPrimary))
          else
            Offstage(),
        ],
      ),
    );
  }
}
