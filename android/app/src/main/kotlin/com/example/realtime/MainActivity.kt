package com.example.realtime

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.util.Log
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.realtime/camera"
    private val EVENT_CHANNEL = "com.example.realtime/cameraStream"

    private var camera2Manager: Camera2Manager? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel: 控制相機啟動與停止
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startCamera" -> {
                    camera2Manager = Camera2Manager(this) { jpegBytes ->
                        Handler(Looper.getMainLooper()).post { //  永遠切回主執行緒
                            eventSink?.success(jpegBytes)
                        }
                    }
                    camera2Manager?.startCamera()
                    result.success("Camera started")
                    Log.d("MainActivity", "Camera started")
                }
                "stopCamera" -> {
                    camera2Manager?.stopCamera()
                    result.success("Camera stopped")
                    Log.d("MainActivity", "Camera stopped")
                }
                else -> result.notImplemented()
            }
        }

        // EventChannel: 傳遞 JPEG 圖片 bytes 給 Flutter
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                    Log.d("MainActivity", "EventChannel listening")
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    Log.d("MainActivity", "EventChannel canceled")
                }
            })
    }
}