package ru.thelanc3.webcadroidclient.Services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.net.wifi.WifiManager
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoWSD
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class CameraStreamService : Service() {

    companion object {
        const val TAG = "CameraStreamService"
        const val CHANNEL_ID = "webcadroid_camera_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_PORT = "EXTRA_PORT"
        const val EXTRA_FPS = "EXTRA_FPS"
        const val EXTRA_CAMERA_ID = "EXTRA_CAMERA_ID"
        const val EXTRA_WIDTH = "EXTRA_WIDTH"
        const val EXTRA_HEIGHT = "EXTRA_HEIGHT"
        const val EXTRA_QUALITY = "EXTRA_QUALITY"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var clientCount = 0
            private set
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private var webSocketServer: StreamWebSocketServer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private var targetFps = 30
    private var quality = 70
    private var lastFrameTime = 0L
    private val isCompressing = AtomicBoolean(false)
    private var cachedNv21Buffer: ByteArray? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_START) {
            val port = intent.getIntExtra(EXTRA_PORT, 8080)
            targetFps = intent.getIntExtra(EXTRA_FPS, 30)
            val cameraId = intent.getStringExtra(EXTRA_CAMERA_ID) ?: "0"
            val reqWidth = intent.getIntExtra(EXTRA_WIDTH, 1280)
            val reqHeight = intent.getIntExtra(EXTRA_HEIGHT, 720)
            quality = intent.getIntExtra(EXTRA_QUALITY, 70)

            startForegroundNotification(port)
            acquireLocks()
            startBackgroundThread()
            startWebSocketServer(port)
            openCamera(cameraId, reqWidth, reqHeight)

            isRunning = true
            Log.d(TAG, "CameraStreamService started on port $port with Camera ID $cameraId ($targetFps FPS)")
        } else if (action == ACTION_STOP) {
            stopServiceAndCleanup()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundNotification(port: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "WebCadroid Camera Stream",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps camera and streaming server active in background"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WebCadroid Stream Active")
            .setContentText("Camera stream running on port $port (Screen can be locked)")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "WebCadroid::CameraWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring wake lock", e)
        }

        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifiManager?.createWifiLock(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                },
                "WebCadroid::WifiLock"
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring wifi lock", e)
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wakeLock", e)
        }
        wakeLock = null

        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wifiLock", e)
        }
        wifiLock = null
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("WebCadroidCameraThread").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join(1000)
            backgroundThread = null
            backgroundHandler = null
        } catch (e: InterruptedException) {
            Log.e(TAG, "Error stopping background thread", e)
        }
    }

    private fun startWebSocketServer(port: Int) {
        try {
            webSocketServer = StreamWebSocketServer(port)
            webSocketServer?.start(5000, false)
            Log.d(TAG, "Native WebSocket Server started on port $port")
        } catch (e: IOException) {
            Log.e(TAG, "Failed to start WebSocket Server", e)
        }
    }

    private fun openCamera(cameraId: String, reqWidth: Int, reqHeight: Int) {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val outputSizes = map?.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray()

            // Find closest supported size to requested dimensions
            val chosenSize = outputSizes.minByOrNull {
                val diffW = kotlin.math.abs(it.width - reqWidth)
                val diffH = kotlin.math.abs(it.height - reqHeight)
                diffW + diffH
            } ?: outputSizes.firstOrNull()

            val streamWidth = chosenSize?.width ?: 1280
            val streamHeight = chosenSize?.height ?: 720
            Log.d(TAG, "Selected resolution: ${streamWidth}x${streamHeight} for camera $cameraId")

            imageReader = ImageReader.newInstance(streamWidth, streamHeight, ImageFormat.YUV_420_888, 2).apply {
                setOnImageAvailableListener({ reader ->
                    onImageAvailable(reader)
                }, backgroundHandler)
            }

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    createCaptureSession()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    Log.w(TAG, "Camera disconnected")
                    camera.close()
                    cameraDevice = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.e(TAG, "Camera error: $error")
                    camera.close()
                    cameraDevice = null
                }
            }, backgroundHandler)

        } catch (e: SecurityException) {
            Log.e(TAG, "Camera permission missing", e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open camera: ${e.message}", e)
        }
    }

    private fun createCaptureSession() {
        val device = cameraDevice ?: return
        val reader = imageReader ?: return
        try {
            val surface = reader.surface
            val requestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            }

            device.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cameraDevice == null) return
                        captureSession = session
                        try {
                            session.setRepeatingRequest(requestBuilder.build(), null, backgroundHandler)
                            Log.d(TAG, "Capture session configured and active")
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to set repeating request", e)
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Capture session configuration failed")
                    }
                },
                backgroundHandler
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error creating capture session", e)
        }
    }

    private fun onImageAvailable(reader: ImageReader) {
        val now = System.currentTimeMillis()
        val intervalMs = (1000 / targetFps)

        // If no clients are connected, discard frame immediately to save CPU and battery
        if (webSocketServer == null || !webSocketServer!!.hasConnections()) {
            reader.acquireLatestImage()?.close()
            return
        }

        if (now - lastFrameTime < intervalMs) {
            reader.acquireLatestImage()?.close()
            return
        }

        if (isCompressing.get()) {
            reader.acquireLatestImage()?.close()
            return
        }

        val image = reader.acquireLatestImage() ?: return
        lastFrameTime = now
        isCompressing.set(true)

        backgroundHandler?.post {
            try {
                processAndBroadcastImage(image)
            } finally {
                image.close()
                isCompressing.set(false)
            }
        }
    }

    private fun processAndBroadcastImage(image: Image) {
        val width = image.width
        val height = image.height
        val requiredSize = width * height * 3 / 2

        val buffer = synchronized(this) {
            if (cachedNv21Buffer == null || cachedNv21Buffer!!.size != requiredSize) {
                cachedNv21Buffer = ByteArray(requiredSize)
            }
            cachedNv21Buffer!!
        }

        yuv420ToNv21(image, buffer)

        try {
            val out = ByteArrayOutputStream(requiredSize / 4)
            val yuvImage = YuvImage(buffer, ImageFormat.NV21, width, height, null)
            yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
            val jpegBytes = out.toByteArray()

            webSocketServer?.broadcastBytes(jpegBytes)
        } catch (e: Exception) {
            Log.e(TAG, "JPEG compression error: ${e.message}")
        }
    }

    private fun yuv420ToNv21(image: Image, buffer: ByteArray) {
        val width = image.width
        val height = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer

        // 1. Copy Y plane
        val yRowStride = yPlane.rowStride
        var pos = 0
        if (yRowStride == width) {
            yBuffer.position(0)
            yBuffer.get(buffer, 0, width * height)
            pos = width * height
        } else {
            for (row in 0 until height) {
                yBuffer.position(row * yRowStride)
                yBuffer.get(buffer, pos, width)
                pos += width
            }
        }

        // 2. Copy UV planes (NV21 format: V U V U)
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        val halfHeight = height / 2
        val halfWidth = width / 2

        for (row in 0 until halfHeight) {
            val rowOffset = row * uvRowStride
            for (col in 0 until halfWidth) {
                val uIndex = rowOffset + col * uvPixelStride
                buffer[pos++] = vBuffer.get(uIndex)
                buffer[pos++] = uBuffer.get(uIndex)
            }
        }
    }

    private fun stopServiceAndCleanup() {
        isRunning = false
        clientCount = 0

        try {
            captureSession?.close()
            captureSession = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing capture session", e)
        }

        try {
            cameraDevice?.close()
            cameraDevice = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing camera device", e)
        }

        try {
            imageReader?.close()
            imageReader = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing imageReader", e)
        }

        try {
            webSocketServer?.stop()
            webSocketServer = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping webSocketServer", e)
        }

        stopBackgroundThread()
        releaseLocks()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        Log.d(TAG, "CameraStreamService stopped and cleaned up")
    }

    override fun onDestroy() {
        stopServiceAndCleanup()
        super.onDestroy()
    }

    // --- Embedded WebSocket Server (NanoWSD) ---
    private inner class StreamWebSocketServer(serverPort: Int) : NanoWSD(serverPort) {
        private val connections = mutableSetOf<WebSocket>()

        override fun openWebSocket(handshake: IHTTPSession?): WebSocket {
            return StreamSocket(handshake)
        }

        fun hasConnections(): Boolean = synchronized(connections) { connections.isNotEmpty() }

        fun broadcastBytes(bytes: ByteArray) {
            synchronized(connections) {
                val iterator = connections.iterator()
                while (iterator.hasNext()) {
                    val socket = iterator.next()
                    try {
                        socket.send(bytes)
                    } catch (e: IOException) {
                        iterator.remove()
                        clientCount = connections.size
                    }
                }
            }
        }

        override fun serveHttp(session: IHTTPSession?): Response {
            return newFixedLengthResponse(
                Response.Status.OK,
                "text/plain",
                "WebCadroid Native Camera2 Server running on port ${listeningPort}"
            )
        }

        private inner class StreamSocket(handshake: IHTTPSession?) : WebSocket(handshake) {
            override fun onOpen() {
                synchronized(connections) {
                    connections.add(this)
                    clientCount = connections.size
                }
                Log.d(TAG, "WebSocket client connected. Total clients: $clientCount")
            }

            override fun onClose(code: WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) {
                synchronized(connections) {
                    connections.remove(this)
                    clientCount = connections.size
                }
                Log.d(TAG, "WebSocket client disconnected. Total clients: $clientCount")
            }

            override fun onMessage(message: WebSocketFrame?) {}
            override fun onPong(pong: WebSocketFrame?) {}

            override fun onException(exception: IOException?) {
                synchronized(connections) {
                    connections.remove(this)
                    clientCount = connections.size
                }
            }
        }
    }
}
