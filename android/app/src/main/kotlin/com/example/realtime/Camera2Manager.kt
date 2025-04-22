package com.example.realtime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import okhttp3.*
import okio.ByteString
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

class Camera2Manager(
    private val context: Context,
    private val onImageAvailable: (ByteArray) -> Unit // 傳送影像給 Flutter 顯示
) {
    private var cameraDevice: CameraDevice? = null // 相機實例，用來開啟與控制實體相機
    private var captureSession: CameraCaptureSession? = null // 相機預覽與影像擷取的控制 session
    private var imageReader: ImageReader? = null // 用來接收相機輸出的資料JPEG 格式
    private var cameraHandler: Handler? = null // 相機後台執行緒上的事件處理器
    private var handlerThread: HandlerThread? = null // 負責處理相機後台工作的執行緒
    private var webSocket: WebSocket? = null // 與伺服器的 WebSocket 連線，用來傳送影像與接收結果
    private var lastFrameTime: Long = 0

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    //  請替換成你的 wss 網址
    private val webSocketUrl = "wss://memories-bleeding-standard-entry.trycloudflare.com/ws"

    // 相機啟動
    @SuppressLint("MissingPermission") // 關閉檢查警告
    fun startCamera() {
        connectWebSocket() // 建立 WebSocket

        // 啟動一個背景執行緒，用來處理相機相關操作
        handlerThread = HandlerThread("CameraBackground").also { it.start() }
        cameraHandler = Handler(handlerThread!!.looper)

        // 取得系統相機服務（CameraManager）
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = manager.cameraIdList[0] // 使用第一顆相機

        // 設定影像接收器，格式為 JPEG，解析度 640x480，最多暫存 2 張影像
        imageReader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 2)
        // 當相機有新影像輸出時會觸發這個 listener
        imageReader?.setOnImageAvailableListener({ reader ->
            val currentTime = System.currentTimeMillis()
            if (currentTime - lastFrameTime < 50) { // 限制影像更新速度為最多 10 FPS（每幀間隔至少 50ms）
                reader.acquireNextImage().close() // 超過頻率則直接丟掉
                return@setOnImageAvailableListener
            }
            lastFrameTime = currentTime

            // 抓取最新影像
            val image = reader.acquireNextImage()
            image?.let {
                try {
                    // 從 image buffer 中擷取出 JPEG 原始位元資料
                    val buffer = it.planes[0].buffer
                    val jpegBytes = ByteArray(buffer.remaining())
                    buffer.get(jpegBytes)

                    // 將 JPEG bytes 解碼為 Bitmap，然後將圖片旋轉 90 度（直立）
                    val originalBitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size)
                    val matrix = Matrix().apply { postRotate(90f) } // 右轉 90 度
                    val rotatedBitmap = Bitmap.createBitmap(
                        originalBitmap, 0, 0,
                        originalBitmap.width, originalBitmap.height,
                        matrix, true
                    )

                    // 將旋轉後的影像重新壓縮成 JPEG 格式
                    val outputStream = ByteArrayOutputStream()
                    rotatedBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
                    val rotatedJpegBytes = outputStream.toByteArray()

                    // 將影像資料傳給後端進行即時辨識
                    webSocket?.send(ByteString.of(*rotatedJpegBytes))

                    // 同時回傳影像給 Flutter 做即時畫面預覽
                    onImageAvailable(rotatedJpegBytes)
                    Log.d("Camera2Manager", "送出影像大小: ${rotatedJpegBytes.size} bytes (已旋轉)")

                } catch (e: Exception) {
                    Log.e("Camera2Manager", "影像處理錯誤: ${e.message}") // 處理過程有錯誤（例如解碼、壓縮、傳送失敗）
                } finally {
                    image.close() // 釋放 image
                }
            }
        }, cameraHandler)

        // 正式開啟相機（需權限），並設定開啟後要建立 Session
        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            // 相機成功打開時呼叫，準備建立預覽 Session
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createCameraSession(listOf(imageReader!!.surface))
                Log.d("Camera2Manager", "相機已開啟")
            }
            // 相機連線被中斷時呼叫
            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                Log.d("Camera2Manager", "相機斷線")
            }
            // 相機開啟失敗時呼叫
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                Log.e("Camera2Manager", "相機錯誤: $error")
            }
        }, cameraHandler)
    }

    // 建立預覽 Session（讓相機開始連續擷取畫面）
    private fun createCameraSession(surfaces: List<Surface>) {
        // 使用相機裝置建立一個新的 Capture Session
        // surfaces：指定影像要輸出到哪（例如 imageReader.surface）
        cameraDevice?.createCaptureSession(
            surfaces,
            object : CameraCaptureSession.StateCallback() {
                // 當 Session 建立成功時呼叫
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session // 儲存目前這個 session
                    try {
                        // 建立一個影像擷取請求（Request）用來進行即時預覽
                        val builder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        builder.addTarget(surfaces[0]) // 設定輸出畫面的位置（這邊是 imageReader 接收的 surface）
                        // 自動對焦模式設定為持續對焦模式
                        builder.set(
                            CaptureRequest.CONTROL_AF_MODE,
                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                        )
                        // 啟動連續的影像擷取（重複送出預覽請求）這樣才會一直抓畫面而不是只拍一張
                        session.setRepeatingRequest(builder.build(), null, cameraHandler)
                        Log.d("Camera2Manager", "Session 已啟動")
                    } catch (e: CameraAccessException) {
                        Log.e("Camera2Manager", "預覽錯誤: ${e.message}")
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e("Camera2Manager", "Session 配置失敗")
                }
            },
            cameraHandler
        )
    }

    // 建立 WebSocket
    private fun connectWebSocket() {
        // 建立 WebSocket 連線請求，使用指定的網址
        val request = Request.Builder().url(webSocketUrl).build()
        // 使用 OkHttp 建立 WebSocket 並註冊事件監聽器
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d("WebSocket", "已連線: $webSocketUrl")
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e("WebSocket", "WebSocket 錯誤: ${t.message}")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d("WebSocket", "WebSocket 已關閉: $reason")
            }

            // 當伺服器回傳訊息（這裡是影像的 byte 資料）時自動觸發
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                Log.d("WebSocket", "收到辨識結果: ${bytes.size} bytes")
                onImageAvailable(bytes.toByteArray())  // 將收到的影像資料傳回 Flutter 顯示辨識後的結果
            }
        })
    }

    // 關閉相機
    fun stopCamera() {
        captureSession?.close()
        cameraDevice?.close()
        imageReader?.close()
        handlerThread?.quitSafely()

        webSocket?.close(1000, "Camera 停止")
        webSocket = null

        captureSession = null
        cameraDevice = null
        imageReader = null
        handlerThread = null
        cameraHandler = null

        Log.d("Camera2Manager", "相機已關閉")
    }
}
