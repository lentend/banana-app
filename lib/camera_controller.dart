import 'package:flutter/services.dart';
// 封裝與原生 Android Camera 功能互動的控制器
class CameraControllerFlutter {
  // 與原生 Android 溝通的 MethodChannel，用於啟動與停止相機等操作
  static const MethodChannel _channel = MethodChannel('com.example.realtime/camera');
  // 與原生 Android 溝通的 EventChannel，用於接收即時影像串流（以 JPEG 格式）
  static const EventChannel _eventChannel = EventChannel('com.example.realtime/cameraStream');

  /// 啟動相機
  void startCamera() {
    _channel.invokeMethod('startCamera');
  }

  /// 停止相機
  void stopCamera() {
    _channel.invokeMethod('stopCamera');
  }

  /// 取得即時影像串流 (JPEG bytes)
  static Stream<dynamic> get imageStream => _eventChannel.receiveBroadcastStream();
}