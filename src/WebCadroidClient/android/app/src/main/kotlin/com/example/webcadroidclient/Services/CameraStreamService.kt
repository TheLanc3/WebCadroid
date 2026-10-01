package ru.thelanc3.webcadroidclient.Services

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import fi.iki.elonen.NanoWSD
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer

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

        var isRunning = false
            private set
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private var webSocketServer: StreamWebSocketServer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private var targetFps = 30
    private var lastFrameTime = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_START) {
            val port = intent.getIntExtra(EXTRA_PORT, 8080)
            targetFps = intent.getIntExtra(EXTRA_FPS, 30)
            val cameraId = intent.getStringExtra(EXTRA_CAMERA_ID) ?: "0"

            startForegroundServiceWithNotification(port)
            acquireWakeLock()
            startBackgroundThread()
            startWebSocketServer(port)
            openCamera(cameraId)

            isRunning = true
        } else if (action == ACTION_STOP) {
            stopServiceAndCleanup()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundServiceWithNotification(port: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "WebCadroid Streaming Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WebCadroid Camera Active")
            .setContentText("Broadcasting camera feed on port $port (Background Native)")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        startForeground(NOTIFICATION_ID, notification)
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "WebCadroid::CameraWakeLock"
        ).apply {
            acquire(10 * 60 * 1000L /*10 minutes fallback*/)
        }
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("CameraBackgroundThread").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
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
            Log.d(TAG, "Native WebSocket Server running on port $port")
        } catch (e: IOException) {
            Log.e(TAG, "Failed to start WebSocket Server", e)
        }
    }

    private fun openCamera(cameraId: String) {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            
            // Выбираем оптимальный размер кадра (HD / Full HD)
            val choices = map?.getOutputSizes(ImageFormat.YUV_420_888)
            val selectedSize = choices?.firstOrNull { it.width <= 1280 } ?: choices?.get(0)
            val width = selectedSize?.width ?: 1280
            val height = selectedSize?.height ?: 720

            imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)
            imageReader?.setOnImageAvailableListener({ reader ->
                val now = System.currentTimeMillis()
                val interval = 1000 / targetFps
                if (now - lastFrameTime >= interval) {
                    lastFrameTime = now
                    val image = reader.acquireLatestImage()
                    if (image != null) {
                        processAndBroadcastImage(image)
                        image.close()
                    }
                } else {
                    reader.acquireLatestImage()?.close()
                }
            }, backgroundHandler)

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    createCameraCaptureSession()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                    Log.e(TAG, "Camera open error: $error")
                }
            }, backgroundHandler)

        } catch (e: SecurityException) {
            Log.e(TAG, "Camera permission missing", e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open camera", e)
        }
    }

    private fun createCameraCaptureSession() {
        try {
            val surface = imageReader!!.surface
            val captureRequestBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            captureRequestBuilder.addTarget(surface)

            cameraDevice!!.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cameraDevice == null) return
                        captureSession = session
                        captureRequestBuilder.set(
                            CaptureRequest.CONTROL_AF_MODE,
                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                        )
                        captureSession!!.setRepeatingRequest(
                            captureRequestBuilder.build(),
                            null,
                            backgroundHandler
                        )
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Capture session configuration failed")
                    }
                },
                backgroundHandler
            )
        } catch (e: CameraAccessException) {
            Log.e(TAG, "Access exception during capture session", e)
        }
    }

    private fun processAndBroadcastImage(image: android.media.Image) {
        if (webSocketServer == null || !webSocketServer!!.hasConnections()) return

        try {
            val nv21 = yuv420ToNv21(image)
            val out = ByteArrayOutputStream()
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
            yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 70, out)
            val jpegBytes = out.toByteArray()

            webSocketServer?.broadcastBytes(jpegBytes)
        } catch (e: Exception) {
            Log.e(TAG, "Error compressing image: ${e.message}")
        }
    }

    private fun yuv420ToNv21(image: android.media.Image): ByteArray {
        val width = image.width
        val height = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer

        val nv21 = ByteArray(width * height * 3 / 2)

        // Y Plane
        var pos = 0
        val yRowStride = yPlane.rowStride
        if (yRowStride == width) {
            yBuffer.get(nv21, 0, width * height)
            pos = width * height
        } else {
            for (row in 0 until height) {
                yBuffer.position(row * yRowStride)
                yBuffer.get(nv21, pos, width)
                pos += width
            }
        }

        // UV Planes
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        val halfHeight = height / 2
        val halfWidth = width / 2

        for (row in 0 until halfHeight) {
            val uRowOffset = row * uvRowStride
            for (col in 0 until halfWidth) {
                val uIndex = uRowOffset + col * uvPixelStride
                nv21[pos++] = vBuffer.get(uIndex)
                nv21[pos++] = uBuffer.get(uIndex)
            }
        }

        return nv21
    }

    private fun stopServiceAndCleanup() {
        isRunning = false
        try {
            captureSession?.close()
            captureSession = null
            cameraDevice?.close()
            cameraDevice = null
            imageReader?.close()
            imageReader = null
            webSocketServer?.stop()
            webSocketServer = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        } finally {
            stopBackgroundThread()
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        stopServiceAndCleanup()
        super.onDestroy()
    }

    // --- Embedded WebSocket Server ---
    private inner class StreamWebSocketServer(port: Int) : NanoWSD(port) {
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
                    }
                }
            }
        }

        private inner class StreamSocket(handshake: IHTTPSession?) : WebSocket(handshake) {
            override fun onOpen() {
                synchronized(connections) { connections.add(this) }
            }

            override fun onClose(code: WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) {
                synchronized(connections) { connections.remove(this) }
            }

            override fun onMessage(message: WebSocketFrame?) {}
            override fun java.lang.Exception.onException(exception: java.lang.Exception?) {}
            override fun onPong(pong: WebSocketFrame?) {}
        }
    }
}