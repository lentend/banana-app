import 'package:camera/camera.dart'; // 用來構建 UI
import 'package:flutter/material.dart'; // 用來控制相機（預覽、錄影、拍照）
import 'package:permission_handler/permission_handler.dart'; // 管理權限（相機、儲存空間等）
import 'package:path_provider/path_provider.dart'; // 取得 App 專屬儲存資料夾
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:convert';
import 'util.dart'; // 引入 util.dart
import 'camera_controller.dart';
import 'dart:typed_data'; // 處理二進位資料（像是 Uint8List）
import 'dart:async';
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // 確保 Flutter 框架與原生平台通訊管道初始化完成
  await _requestPermissions(); // 向使用者請求必要權限（如相機、儲存空間）
  await clearFile(); // 清空紀錄檔案內容
  print('檔案已清空');
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // 隱藏 DEBUG 標籤
      title: '錄影上傳區',
      theme: ThemeData(
        primarySwatch: Colors.blue, // 設定主題顏色
      ),
      home: CameraPage(), // App 啟動後的首頁畫面
    );
  }
}

Future<void> _requestPermissions() async {
  await Permission.camera.request();
  await Permission.microphone.request();
  await Permission.storage.request(); // 添加存儲權限
}

class CameraPage extends StatefulWidget {
  @override
  _CameraPageState createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _controller; // Flutter camera 控制器
  bool _isRecording = false; // 是否正在錄影
  String? _videoPath; // 錄製影片的檔案路徑
  String? _fileName; // 錄製影片的檔名
  VideoPlayerController? _videoPlayerController; // 用來播放錄製後影片的控制器
  bool _isCameraPreview = false; // 是否顯示相機預覽畫面
  bool _isVideoPlaying = false; // 是否正在播放影片
  bool _isVideoPaused = false; // 是否影片暫停
  bool _isProcessingComplete = false; // 添加處理完成的標誌
  bool _isUploading = false; // 正在上傳影片
  bool _isUploadFailed = false; // 上傳是否失敗
  bool _isButtonDisabled = false; // 按鈕是否禁用
  bool isLoading = false; // 是否正在讀取
  Duration _currentPosition = Duration.zero; // 當前播放時間
  Duration _totalDuration = Duration.zero; // 總影片時長

  // 定義伺服器 URL 作為變數,須改
  String serverUrl = 'https://appraisal-cms-pages-may.trycloudflare.com';

  @override
  void initState() {
    super.initState();
    _currentPosition = Duration.zero;
    _totalDuration = Duration.zero;
    _initializeCamera(); // 啟動相機初始化流程
  }

  Future<void> _initializeCamera() async {
    if (_controller != null) {
      await _controller?.dispose(); // 如果已有相機控制器，先釋放資源
      _controller = null;
    }
    final cameras = await availableCameras(); // 取得所有可用的相機列表
    final firstCamera = cameras.first; // 選擇第一個相機(後鏡頭)

    _controller = CameraController(
      firstCamera,
      ResolutionPreset.high, // 設定解析度為高
    );

    await _controller?.initialize();
    try {
      await _controller?.initialize(); // 初始化相機控制器
      if (mounted) {
        setState(() {}); // 重新渲染畫面（讓相機預覽顯示）
      }
    } catch (e) {
      print("初始化相機失敗: $e");
    }
  }

  // 切換錄影狀態
  void _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    // 如果相機控制器還沒建立，或是已建立但還沒初始化
    if (_controller == null || !_controller!.value.isInitialized) {
      print("相機未初始化或已釋放");
      return;
    }
    final directory = await getTemporaryDirectory(); // 使用暫存資料夾存影片
    final videoPath = '${directory.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    _videoPath = videoPath; // 跨函式共用錄影路徑
    _currentPosition = Duration.zero; // 重置目前播放時間
    _totalDuration = Duration.zero; // 重置影片總時長

    await _controller?.startVideoRecording(); // 啟動錄影
    setState(() {
      _isRecording = true;
      _isCameraPreview = true;
      _isVideoPlaying = false;
    });
  }

  Future<void> _stopRecording() async {
    final XFile? videoFile = await _controller?.stopVideoRecording(); // 停止錄影並取得影片檔案
    if (videoFile != null) {
      _videoPath = videoFile.path;
      setState(() {
        _isRecording = false;
        _isCameraPreview = false;
      });
      await _uploadVideo(_videoPath!); // 上傳影片至伺服器
    }
  }

  Future<void> _uploadVideo(String path) async {
    setState(() {
      _isUploading = true; // 切換為上傳中狀態
    });

    // 以目前時間生成檔名
    final now = DateTime.now();
    final fileName = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.mp4';
    _fileName = fileName;
    print('Uploading file: $fileName');

    try {
      var file = File(path);
      var length = await file.length();
      var uri = Uri.parse('$serverUrl/upload');

      var request = http.StreamedRequest('POST', uri);
      request.headers.addAll({
        "x-filename": fileName, // 傳送自定義檔名供後端儲存使用
        "Content-Type": "video/mp4",
      });
      var fileStream = file.openRead(); // 將影片檔案作為位元流送出
      fileStream.listen((chunk) {
        request.sink.add(chunk); // 逐塊寫入上傳資料流
      }, onDone: () {
        request.sink.close(); // 上傳結束，關閉資料流
      });

      var response = await request.send(); // 等待伺服器回應
      if (response.statusCode == 200) {
        print('Video uploaded, processed, and result uploaded to AWS successfully');
        setState(() {
          _isProcessingComplete = true; // 啟用“觀看結果”按鈕
        });
      } else {
        print('Failed to upload video');
        setState(() {
          _isUploadFailed = true; // 上傳失敗
        });
      }
    } catch (e) {
      print('Error uploading video: $e');
      setState(() {
        _isUploadFailed = true;
      });
    } finally {
      setState(() {
        _isUploading = false; // 結束上傳
      });
    }
  }

  // 將 Duration 轉為 mm:ss 格式字串（例如 02:09）
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  // 從伺服器下載處理後的影片，並播放；同時記錄檔名與最大 exp 資料夾到 TXT
  void _playResult() async {
    if (_fileName == null) {
      print('No file name set. Cannot play video.');
      return;
    }
    setState(() {
      isLoading = true; // 開始讀取
      _isButtonDisabled = true; // 禁用按鈕
    });

    // 新增請求以獲取最大 exp 資料夾
    final maxDirUrl = '$serverUrl/getmax_dir';
    final maxDirResponse = await http.get(Uri.parse(maxDirUrl));
    if (maxDirResponse.statusCode == 200) {
      final maxExpDir = maxDirResponse.body; // 直接取得伺服器回傳的內容
      print('伺服器中的最大 exp 資料夾為: $maxExpDir');

      // 檔案內容為 _fileName/maxExpDir
      final contentToWrite = '$_fileName/$maxExpDir';

      // 檢查是否需要寫入 TXT 檔案
      final directory = await getApplicationDocumentsDirectory();
      final txtFile = File('${directory.path}/maxExpDir.txt');
      String existingContent = '';
      if (await txtFile.exists()) {
        existingContent = await txtFile.readAsString();
      }

      if (!existingContent.contains(contentToWrite)) {
        // 如果不存在該內容，則寫入
        await txtFile.writeAsString('$existingContent\n$contentToWrite', mode: FileMode.write);
        print('內容 "$contentToWrite" 已寫入到本地 TXT 文件: ${txtFile.path}');
      } else {
        print('內容 "$contentToWrite" 已經存在於本地 TXT 文件中，跳過寫入');
      }
    } else {
      print('Failed to fetch max exp directory');
    }

    // 從伺服器下載處理後影片
    final url = '$serverUrl/processed_video/$_fileName';
    final response = await http.get(Uri.parse(url));
    print('檔案名稱為: $_fileName');

    if (response.statusCode == 200) {
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/downloaded_video.mp4'; // 建立影片儲存完整路徑
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes); // 將影片二進位資料寫入本地 mp4 檔案
      // 將影片檔案交給 VideoPlayerController 播放
      setState(() {
        _videoPlayerController = VideoPlayerController.file(file)
          ..initialize().then((_) {
            _videoPlayerController!.play(); // 播放影片
            setState(() {
              _isCameraPreview = false; // 關閉相機預覽畫面
              _isVideoPlaying = true; // 切換成播放狀態
              _isVideoPaused = false;
              isLoading = false; // 結束讀取狀態
              _totalDuration = _videoPlayerController!.value.duration; // 獲取影片總時長
            });

            // 監聽影片播放進度
            _videoPlayerController!.addListener(() {
              if (_videoPlayerController != null &&
                  _videoPlayerController!.value.isInitialized) {
                setState(() {
                  _currentPosition = _videoPlayerController!.value.position; // 更新當前播放時間
                });
              }
            });

            // 監聽影片是否播放完畢
            _videoPlayerController!.addListener(_onVideoPlayerStateChanged);
          });
        //_isButtonDisabled = false; // 在成功處理完成後啟用按鈕
      });
    } else {
      print('Failed to download video');
      // 如果影片下載失敗，回復 UI 狀態
      setState(() {
        _isButtonDisabled = false; // 即使失敗也要啟用按鈕
        isLoading = false; // 停止顯示“讀取中”
      });
    }
  }

  // 監聽影片，播放結束時自動 UI 更新
  void _onVideoPlayerStateChanged() {
    if (_videoPlayerController!.value.position == _videoPlayerController!.value.duration) {
      _videoPlayerController!.removeListener(_onVideoPlayerStateChanged); // 移除監聽器，避免重複觸發
      _videoPlayerController!.pause();
      setState(() {
        _isVideoPlaying = false; // 切換回非播放狀態
        _isButtonDisabled = false; // 播放完畢後可再次操作按鈕
      });
    }
  }

  // 控制影片播放暫停
  void _togglePlayPause() {
    // 確保影片控制器存在、已初始化，並且影片處於播放狀態中
    if (_videoPlayerController != null && _videoPlayerController!.value.isInitialized && _isVideoPlaying) {
      if (_videoPlayerController!.value.isPlaying) {
        _videoPlayerController!.pause();
        setState(() {
          _isVideoPaused = true;
        });
      } else {
        _videoPlayerController!.play();
        setState(() {
          _isVideoPaused = false;
        });
      }
    }
  }

  // 建立相機預覽畫面（按照 9:16 長寬比顯示）
  Widget _buildCameraPreview() {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final adjustedWidth = constraints.maxWidth; // 可用最大寬度
          final adjustedHeight = adjustedWidth * 16 / 9;
          return AspectRatio(
            aspectRatio: 9 / 16, // 保持畫面長寬比例
            child: CameraPreview(_controller!), // 顯示相機畫面
          );
        },
      ),
    );
  }

  // 建立影片播放區域，包括播放畫面、控制列、播放時間顯示
  Widget _buildVideoPlayer() {
    return Column(
      children: [
        Expanded(
          child: _videoPlayerController != null &&
              _videoPlayerController!.value.isInitialized
              ? InteractiveViewer(
            // 影片可以手動縮放觀看
            maxScale: 5.0, // 最大縮放倍數
            minScale: 1.0, // 最小縮放倍數
            child: SizedBox(
              width: _videoPlayerController!.value.size.width,
              height: _videoPlayerController!.value.size.height,
              child: VideoPlayer(_videoPlayerController!), // 顯示影片內容
            ),
          )
              : Center(child: CircularProgressIndicator()), // 若尚未初始化完成，顯示 loading 動畫
        ),
        // 若播放器已初始化，顯示控制列
        if (_videoPlayerController != null &&
            _videoPlayerController!.value.isInitialized)
          Column(
            children: [
              Row(
                children: [
                  // 暫停/播放按鈕
                  SizedBox(
                    width: 50,
                    child: IconButton(
                      icon: Icon(
                        _videoPlayerController!.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      iconSize: 36.0,
                      onPressed: () {
                        setState(() {
                          if (_videoPlayerController!.value.isPlaying) {
                            _videoPlayerController!.pause();
                          } else {
                            _videoPlayerController!.play();
                          }
                        });
                      },
                    ),
                  ),
                  // 時間軸Slider
                  Expanded(
                    child: Slider(
                      value: _currentPosition.inMilliseconds
                          .clamp(0, _totalDuration.inMilliseconds)
                          .toDouble(), // 確保 _currentPosition 不會超過範圍
                      max: _totalDuration.inMilliseconds.toDouble(),
                      onChanged: (value) {
                        final newPosition = Duration(milliseconds: value.toInt());
                        _videoPlayerController?.seekTo(newPosition); // 拖曳後跳轉播放位置
                      },
                    ),
                  ),
                ],
              ),
              Row( // 顯示 播放中時間 / 總時長
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDuration(_currentPosition),
                    style: TextStyle(fontSize: 14.0),
                  ),
                  Text(
                    _formatDuration(_totalDuration),
                    style: TextStyle(fontSize: 14.0),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  @override
  void dispose() {
    _controller?.dispose(); // 釋放相機資源，防止記憶體洩漏
    _videoPlayerController?.dispose(); // 釋放影片播放器資源
    super.dispose(); // 呼叫父類別的 dispose
  }

  @override
  Widget build(BuildContext context) {
    // 如果相機尚未初始化，顯示載入中動畫
    if (_controller == null || !_controller!.value.isInitialized) {
      return Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('錄影上傳區'),
      ),
      drawer: SizedBox(
        width: MediaQuery.of(context).size.width * 0.7, // 調整 Drawer 寬度 (70% 的螢幕寬度)
        child: Drawer(
          child: ListView(
            children: [
              DrawerHeader(
                decoration: BoxDecoration(color: Colors.blue),
                child: Align(
                  alignment: Alignment.centerLeft, // 垂直居中且靠左
                  child: Text(
                    "功能選單",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.home),
                title: Text("我要錄影"),
                onTap: () {
                  Navigator.pop(context); // 關閉 Drawer，保持在首頁
                  _initializeCamera(); // 重新初始化相機
                },
              ),
              ListTile(
                leading: Icon(Icons.photo),
                title: Text("我要拍照"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => SecondPage()), // 新畫面
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.live_tv), // 你喜歡的 icon
                title: Text("即時辨識"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => Realtime()), // 跳到 Realtime 頁面
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.history),
                title: Text("辨識紀錄"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => ThirdPage()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      body: Column( // 主畫面內容
        children: [
          Expanded(
            child: Stack(
              children: [
                Center(child: Text(_isUploading ? '辨識中請稍後' : '請點擊按鈕開始\n或左上角切換功能',
                  textAlign: TextAlign.center, // 行內置中
                  style: TextStyle(
                    fontSize: 24, // 設置文字大小
                  ),
                )
                ),
                Visibility( // 顯示相機預覽畫面
                  visible: _isCameraPreview,
                  child: _buildCameraPreview(),
                ),
                Visibility( // 顯示影片播放器
                  visible: _isVideoPlaying,
                  child: _buildVideoPlayer(),
                ),
                Visibility( // 顯示 loading 動畫
                  visible: _isUploading, // 根據上傳狀態顯示轉圈圖示
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 90.0), // 向上移動圖示
                    child: Center(
                      child: CircularProgressIndicator(), // 轉圈圖示
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          Container( // 控制按鈕區域
            margin: EdgeInsets.only(bottom: 5), // 調整按鈕區域向上移動
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ElevatedButton(
                  onPressed: (_isButtonDisabled || _isUploading) ? null : _toggleRecording, // 禁用條件
                  child: Text(_isRecording ? '停止錄影' : '開始錄影'),
                ),
                ElevatedButton(
                  onPressed: (_isProcessingComplete && !_isUploading && !_isButtonDisabled && !isLoading)
                      ? _playResult
                      : null, // 僅在非讀取中且處理完成時啟用按鈕
                  child: Text(
                    isLoading
                        ? '讀取中...' // 顯示讀取中
                        : (_isUploadFailed ? '上傳失敗'
                        : (_isProcessingComplete ? '觀看結果' : '沒有影片')),
                  ),
                ),
                ElevatedButton(
                  onPressed: _togglePlayPause,
                  child: Text(_isVideoPaused ? '繼續播放' : '暫停播放'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// CameraPage 的所有程式碼...
class SecondPage extends StatefulWidget {
  @override
  _SecondPageState createState() => _SecondPageState(); // 建立對應狀態物件
}

class _SecondPageState extends State<SecondPage> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false; // 相機是否初始化完成
  String? _lastCapturedPhotoPath; // 保存最近拍攝的照片路徑
  String? _capturedPhotoPath; // 暫時顯示的照片路徑
  bool _isPhotoPreviewVisible = false; // 控制照片是否顯示
  bool _isUploading = false; // 控制按鈕狀態的變數

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final firstCamera = cameras.first;
    _cameraController = CameraController(
      firstCamera,
      ResolutionPreset.high, // 高分辨率
    );
    await _cameraController?.initialize(); // 初始化相機控制器
    if (mounted) {
      setState(() {
        _isCameraInitialized = true;
      });
    }
  }

  Future<void> _capturePhoto() async {
    if (!_cameraController!.value.isInitialized) {
      print("相機未初始化");
      return;
    }

    try {
      // 拍攝照片並保存到臨時目錄
      final directory = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.jpeg';
      final filePath = '${directory.path}/$fileName';

      final XFile photo = await _cameraController!.takePicture();
      final File photoFile = File(photo.path);
      await photoFile.copy(filePath);

      setState(() {
        _lastCapturedPhotoPath = filePath; // 保存最近的照片
        _capturedPhotoPath = filePath; // 暫時顯示的照片
        _isPhotoPreviewVisible = true; // 顯示照片
      });

      // 0.5秒後隱藏照片預覽
      Future.delayed(Duration(milliseconds: 500), () {
        setState(() {
          _isPhotoPreviewVisible = false;
        });
      });

      print("照片保存成功：$filePath");
      // 上傳照片到伺服器
      await _uploadPhoto(filePath);
    } catch (e) {
      print("拍照失敗：$e");
    }
  }

  Future<void> _uploadPhoto(String filePath) async {
    //須改
    const String serverUrl = 'https://appraisal-cms-pages-may.trycloudflare.com/upload-photo';
    try {
      setState(() {
        _isUploading = true; // 設為上傳中
      });
      final uri = Uri.parse(serverUrl);
      final request = http.MultipartRequest('POST', uri); // 建立 Multipart 請求（可夾帶檔案）
      // 加入照片檔案到請求（欄位名稱為 'photo'，對應後端接收欄位）
      request.files.add(await http.MultipartFile.fromPath('photo', filePath));

      final response = await request.send(); // 發送請求給伺服器
      if (response.statusCode == 200) {
        print('圖片上傳成功');
      } else {
        print('圖片上傳失敗，錯誤代碼：${response.statusCode}');
      }
    } catch (e) {
      print('圖片上傳時發生錯誤：$e');
    }finally {
      setState(() {
        _isUploading = false; // 啟用按鈕
      });
    }
  }

  void _viewLastPhoto() async{
    if (_lastCapturedPhotoPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("尚未拍攝任何照片")),
      );
      return;
    }
    //須改
    const String url = 'https://appraisal-cms-pages-may.trycloudflare.com';
    const String serverUrl = '$url/processed_video';
    final fileName = _lastCapturedPhotoPath!.split('/').last;

    try {
      // 1. 取得最大 exp 資料夾
      final maxDirUrl = '$url/getmax_dir';
      final maxDirResponse = await http.get(Uri.parse(maxDirUrl));
      if (maxDirResponse.statusCode == 200) {
        final maxExpDir = maxDirResponse.body; // 伺服器回傳的 exp 資料夾名稱
        print('伺服器中的最大 exp 資料夾為: $maxExpDir');

        // 準備寫入的內容
        final contentToWrite = '$fileName/$maxExpDir';

        // 檢查並寫入本地檔案
        final directory = await getApplicationDocumentsDirectory();
        final txtFile = File('${directory.path}/maxExpDir.txt');
        String existingContent = '';
        if (await txtFile.exists()) {
          existingContent = await txtFile.readAsString();
        }

        if (!existingContent.contains(contentToWrite)) {
          // 確保換行符處理正確
          final newContent = existingContent.trim().isEmpty
              ? contentToWrite // 如果檔案原本是空的，直接寫入新內容
              : '$existingContent\n$contentToWrite'; // 如果已有內容，追加新內容並換行

          await txtFile.writeAsString(newContent, mode: FileMode.write);
          print('內容 "$contentToWrite" 已寫入到本地 TXT 文件: ${txtFile.path}');
        } else {
          print('內容 "$contentToWrite" 已經存在於本地 TXT 文件中，跳過寫入');
        }
      } else {
        print('Failed to fetch max exp directory');
      }
      // 2. 發送 GET 請求到伺服器
      final uri = Uri.parse('$serverUrl/$fileName');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        // 將取得的圖片存到臨時目錄
        final directory = await getTemporaryDirectory();
        final processedFilePath = '${directory.path}/processed_$fileName';
        final file = File(processedFilePath);
        await file.writeAsBytes(response.bodyBytes);

        print('處理後的圖片已成功下載：$processedFilePath');

        // 導航到照片查看頁面，並傳遞處理後的檔案路徑
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PhotoViewerPage(photoPath: processedFilePath),
          ),
        ).then((_) {
          // 返回時重新初始化相機
          _initializeCamera();
        });
      } else {
        print('無法取得處理後的圖片，錯誤代碼：${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("無法取得處理後的照片")),
        );
      }
    } catch (e) {
      print('取得處理後的圖片時發生錯誤：$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("取得處理後的照片失敗")),
      );
    }
  }

  void _goToTextDisplayPage() async {
    //須改
    const String serverUrl = 'https://appraisal-cms-pages-may.trycloudflare.com'; // 替換為你的伺服器地址
    if (_lastCapturedPhotoPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("尚未拍攝任何照片")),
      );
      return;
    }
    // 從 _lastCapturedPhotoPath 提取檔案名稱
    final String filename = _lastCapturedPhotoPath!.split('/').last.replaceAll('.jpeg', '.txt').replaceAll('.jpg', '.txt');
    try {
      final response = await http.get(Uri.parse('$serverUrl/processed_data/$filename'));
      if (response.statusCode == 200) {
        final responseData = response.body;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TextDisplayPage(content: responseData),
          ),
        ).then((_) {
          // 返回後可執行其他操作，例如重新初始化相機
          _initializeCamera();
        });
      } else {
        print('伺服器返回錯誤代碼：${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('無法取得資料')),
        );
      }
    } catch (e) {
      print('請求時發生錯誤：$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('請求失敗')),
      );
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _cameraController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("拍照上傳區"),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Center(
                  child: _isCameraInitialized
                      ? AspectRatio(
                    aspectRatio: 9 / 16, // 設定顯示比例 9:16（豎屏模式）
                    child: CameraPreview(_cameraController!),
                  )
                      : CircularProgressIndicator(),
                ),
              ),
              Container(
                margin: EdgeInsets.only(bottom: 10), // 調整按鈕區域向上移動
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ElevatedButton(
                      onPressed: _isUploading ? null : _capturePhoto,
                      child: Text("拍照"),
                    ),
                    ElevatedButton(
                      onPressed: _isUploading ? null : _viewLastPhoto,
                      child: Text("查看照片"),
                    ),
                    ElevatedButton(
                      onPressed: _isUploading ? null : _goToTextDisplayPage,
                      child: Text("查看統計結果"),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 照片預覽與鏡頭預覽大小一致
          if (_isPhotoPreviewVisible && _capturedPhotoPath != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: 80, // 預留按鈕區域空間
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10), // 左右間隔
                child: AspectRatio(
                  aspectRatio: 9 / 16, // 與預覽鏡頭比例一致
                  child: Image.file(
                    File(_capturedPhotoPath!),
                    fit: BoxFit.contain, // 確保顯示的照片與預覽鏡頭比例一致
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

//顯示預測照片結果
class PhotoViewerPage extends StatelessWidget {
  final String photoPath;
  PhotoViewerPage({required this.photoPath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("查看照片"),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5.0,
          minScale: 1.0,
          child: Image.file(File(photoPath)),
        ),
      ),
    );
  }
}

//顯示預測文字結果
class TextDisplayPage extends StatelessWidget {
  final String content;
  TextDisplayPage({required this.content});

  @override
  Widget build(BuildContext context) {
    String formattedContent = content.replaceAllMapped(
        RegExp(r'(\d+)\s(\S+)'),
            (match) => '${match.group(1)} 個 ${match.group(2)}'
    );
    return Scaffold(
      appBar: AppBar(
        title: Text("分類數量"),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            formattedContent.isNotEmpty ? formattedContent : '沒有資料可顯示',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

//定義第三頁
class ThirdPage extends StatefulWidget {
  @override
  _ThirdPageState createState() => _ThirdPageState();
}

class _ThirdPageState extends State<ThirdPage> {
  List<Map<String, String>> fileInfoList = []; // 儲存檔案名稱和 exp 的列表

  @override
  void initState() {
    super.initState();
    _loadFileContent(); // 初始化時加載檔案內容
  }

  // 讀取檔案內容並更新列表
  Future<void> _loadFileContent() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final txtFile = File('${directory.path}/maxExpDir.txt');

      // 如果檔案不存在，創建空白檔案
      if (!await txtFile.exists()) {
        await txtFile.create();
        await txtFile.writeAsString(''); // 初始化為空內容
      }

      // 按行讀取檔案內容並處理
      final content = await txtFile.readAsLines();
      final processedFiles = content.map((line) {
        final parts = line.split('/'); // 假設格式為 "檔案名稱/exp"
        return {
          "name": parts.isNotEmpty ? parts.first : "", // 提取檔案名稱
          "exp": parts.length > 1 ? parts.last : "未知 exp", // 提取 exp
        };
      }).where((file) => file["name"]!.isNotEmpty).toList(); // 過濾空行

      setState(() {
        fileInfoList = processedFiles; // 更新檔案資訊列表
      });
    } catch (e) {
      setState(() {
        fileInfoList = []; // 如果出錯，清空列表
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("歷史紀錄"),
      ),
      body: fileInfoList.isEmpty
          ? Center(
        child: Text(
          "目前無紀錄",
          style: TextStyle(fontSize: 20),
        ),
      )
          : ListView.builder(
        itemCount: fileInfoList.length,
        itemBuilder: (context, index) {
          final file = fileInfoList[index];
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade300), // 每行底部分隔線
              ),
            ),
            child: Material(
              color: Colors.transparent, // 背景透明
              child: InkWell(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ExpData(
                        fileName: file["name"]!, // 傳遞檔案名稱
                        exp: file["exp"]!, // 傳遞 exp
                      ), // 傳遞 exp 值
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
                  child: Text(
                    file["name"]!,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

//展示播放歷史紀錄的頁面
class ExpData extends StatefulWidget {
  final String fileName; // 檔案名稱
  final String exp; // 接收的 exp 值

  ExpData({required this.fileName, required this.exp});

  @override
  _ExpDataState createState() => _ExpDataState();
}

class _ExpDataState extends State<ExpData> {
  VideoPlayerController? _videoPlayerController;
  bool isVideo = false; // 判斷是否為影片檔案
  String? filePath; // 本地檔案路徑
  bool isLoading = true; // 請求狀態標誌
  bool hasError = false; // 錯誤標誌
  Duration _currentPosition = Duration.zero; // 當前播放位置
  Duration _totalDuration = Duration.zero; // 總時長

  @override
  void initState() {
    super.initState();
    _fetchFile(); // 初始化時從伺服器下載檔案
  }

  @override
  void dispose() {
    // 清理影片播放器
    _videoPlayerController?.dispose();
    super.dispose();
  }

  // 判斷是否為影片檔案
  bool _isVideoFile(String fileName) {
    return fileName.toLowerCase().endsWith('.mp4');
  }

  // 從伺服器下載檔案
  Future<void> _fetchFile() async {
    //須改
    final url =
        'https://appraisal-cms-pages-may.trycloudflare.com/get_exp_file?exp=${widget.exp}&fileName=${widget.fileName}';

    print('正在請求的 exp：${widget.exp}');
    print('正在請求的 URL：$url');

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final directory = await getTemporaryDirectory();
        final subDir = '${directory.path}/exp_cache';
        await Directory(subDir).create(recursive: true);
        filePath = '$subDir/${widget.exp}_${widget.fileName}';
        final file = File(filePath!);
        await file.writeAsBytes(response.bodyBytes, flush: true);

        print('檔案已成功下載到本地：$filePath');

        isVideo = _isVideoFile(widget.fileName);

        if (isVideo) {
          _initializeVideoPlayer();
        }

        setState(() {
          isLoading = false;
        });
      } else {
        print('伺服器返回錯誤，狀態碼：${response.statusCode}');
        throw Exception('Failed to download file: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        isLoading = false;
        hasError = true;
      });
      print('下載檔案失敗：$e');
    }
  }

  // 初始化影片播放器
  void _initializeVideoPlayer() {
    if (filePath != null) {
      _videoPlayerController = VideoPlayerController.file(File(filePath!))
        ..addListener(() {
          if (_videoPlayerController!.value.isInitialized) {
            setState(() {
              _currentPosition = _videoPlayerController!.value.position;
              _totalDuration = _videoPlayerController!.value.duration;
            });
          }
          if (_videoPlayerController!.value.hasError) {
            print('影片播放錯誤：${_videoPlayerController!.value.errorDescription}');
            setState(() {
              hasError = true;
            });
          }
        })
        ..initialize().then((_) {
          setState(() {});
          _videoPlayerController!.play();
        }).catchError((e) {
          print('影片初始化失敗：$e');
          setState(() {
            hasError = true;
          });
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("檔案內容"),
      ),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : hasError
          ? Center(
        child: Text(
          "檔案下載失敗",
          style: TextStyle(fontSize: 20, color: Colors.red),
        ),
      )
          : isVideo
          ? _buildVideoPlayer()
          : _buildPhotoViewer(),
    );
  }

  // 建立影片播放器
  Widget _buildVideoPlayer() {
    return Column(
      children: [
        Expanded(
          child: _videoPlayerController != null &&
              _videoPlayerController!.value.isInitialized
              ? InteractiveViewer(
            maxScale: 5.0, // 最大縮放倍數
            minScale: 1.0, // 最小縮放倍數
            child: SizedBox(
              width: _videoPlayerController!.value.size.width,
              height: _videoPlayerController!.value.size.height,
              child: VideoPlayer(_videoPlayerController!),
            ),
          )
              : Center(child: CircularProgressIndicator()), // 等待影片初始化
        ),
        if (_videoPlayerController != null &&
            _videoPlayerController!.value.isInitialized)
          Column(
            children: [
              Row(
                children: [
                  // 暫停/播放按鈕
                  SizedBox(
                    width: 50,
                    child: IconButton(
                      icon: Icon(
                        _videoPlayerController!.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      iconSize: 36.0,
                      onPressed: () {
                        setState(() {
                          if (_videoPlayerController!.value.isPlaying) {
                            _videoPlayerController!.pause();
                          } else {
                            _videoPlayerController!.play();
                          }
                        });
                      },
                    ),
                  ),
                  // 時間軸
                  Expanded(
                    child: Slider(
                      value: _currentPosition.inMilliseconds.toDouble(),
                      max: _totalDuration.inMilliseconds.toDouble(),
                      onChanged: (value) {
                        final newPosition =
                        Duration(milliseconds: value.toInt());
                        _videoPlayerController?.seekTo(newPosition);
                      },
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDuration(_currentPosition),
                    style: TextStyle(fontSize: 14.0),
                  ),
                  Text(
                    _formatDuration(_totalDuration),
                    style: TextStyle(fontSize: 14.0),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
  // 建立圖片查看器
  Widget _buildPhotoViewer() {
    if (filePath == null || !File(filePath!).existsSync()) {
      print('圖片檔案不存在，路徑：$filePath');
      return Center(
        child: Text(
          "圖片檔案無法顯示",
          style: TextStyle(fontSize: 20, color: Colors.red),
        ),
      );
    }

    print('顯示圖片，路徑：$filePath');
    return Center(
      child: InteractiveViewer(
        maxScale: 5.0,
        minScale: 1.0,
        child: Image.file(
          File(filePath!),
          fit: BoxFit.contain,
          key: ValueKey(filePath!),
        ),
      ),
    );
  }

  // 格式化時間
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

// 第四頁：即時辨識區 (Realtime)
class Realtime extends StatefulWidget {
  @override
  _RealtimeState createState() => _RealtimeState();
}

class _RealtimeState extends State<Realtime> {
  Uint8List? _imageBytes; // 接收到的 JPEG 圖片二進位資料
  int _lastFrameId = 0; // 記錄最後一張處理的影像編號（防止重複處理）
  late final CameraControllerFlutter _controller; // 自訂的 Flutter <-> 原生相機控制器通道
  StreamSubscription? _cameraSubscription; // 監聽即時影像串流的訂閱物件，用於中途取消
  bool _isDetecting = false; // 是否正在進行辨識

  @override
  void initState() {
    super.initState();
    _controller = CameraControllerFlutter(); // 初始化自訂相機控制器
  }

  //  開始辨識
  void _startCamera() {
    setState(() => _isDetecting = true); // 正在辨識中
    _controller.startCamera(); // 呼叫原生端啟動相機（透過 MethodChannel）
    // 監聽即時影像串流（JPEG bytes）事件
    _cameraSubscription = CameraControllerFlutter.imageStream.listen((event) {
      if (event.length <= 8) return; // 若收到資料小於等於 8 bytes，表示異常直接忽略
      // 前 8 bytes 是 frameId（影像編號），避免重複處理舊影像
      final frameIdBytes = event.sublist(0, 8);
      final frameId = _bytesToInt(frameIdBytes); // 自訂方法：byte 轉 int
      if (frameId > _lastFrameId) {
        _lastFrameId = frameId;
        final imageBytes = event.sublist(8); // 解析影像部分
        setState(() => _imageBytes = imageBytes);
      }
    });
  }

  //  停止辨識
  void _stopCamera() {
    _controller.stopCamera();
    _cameraSubscription?.cancel();
    _cameraSubscription = null;
    setState(() {
      _imageBytes = null;
      _lastFrameId = 0;
      _isDetecting = false;
    });
  }

  @override
  void dispose() {
    _cameraSubscription?.cancel();
    _controller.stopCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("即時辨識區"),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: SizedBox(
                width: 640,
                height: 480,
                child: _imageBytes != null
                    ? Image.memory(
                  _imageBytes!,
                  gaplessPlayback: true,
                  fit: BoxFit.fill,
                )
                    : const Center(child: Text('點擊按鈕進行連線',style: TextStyle(fontSize: 24),)),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _isDetecting ? null : _startCamera, // 辨識中不能重複按
                child: Text('開始辨識'),
              ),
              ElevatedButton(
                onPressed: _isDetecting ? _stopCamera : null, // 沒啟動不能按停止
                child: Text('停止辨識'),
              ),
            ],
          ),
          SizedBox(height: 20),
        ],
      ),
    );
  }

  //  Bytes 轉 Int (frameId)
  int _bytesToInt(Uint8List bytes) {
    ByteData byteData = bytes.buffer.asByteData(); // 將 Uint8List 的 buffer 包裝成 ByteData，方便讀取原始資料
    return byteData.getUint64(0, Endian.big); // 從第 0 位開始，以 Big Endian 格式解析成 64 位無號整數
  }
}