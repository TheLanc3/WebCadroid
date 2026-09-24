package com.example.webcadroidclient

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.webcadroidclient/settings"
    private val backgroundExecutor = Executors.newFixedThreadPool(2)
    private var cachedNv21Buffer: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isUsbDebuggingEnabled" -> {
                    try {
                        val adbEnabled = Settings.Global.getInt(
                            contentResolver,
                            Settings.Global.ADB_ENABLED, 0
                        ) != 0
                        result.success(adbEnabled)
                    } catch (e: Exception) {
                        result.error("ADB_CHECK_FAILED", e.message, null)
                    }
                }
                "getScreenBrightness" -> {
                    try {
                        val layoutParams = window.attributes
                        var brightness = layoutParams.screenBrightness
                        if (brightness < 0) {
                            val systemBrightness = Settings.System.getInt(
                                contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS, 128
                            )
                            brightness = systemBrightness / 255.0f
                        }
                        result.success(brightness.toDouble())
                    } catch (e: Exception) {
                        result.error("BRIGHTNESS_ERROR", e.message, null)
                    }
                }
                "setScreenBrightness" -> {
                    val brightness = call.argument<Double>("brightness")?.toFloat()
                    if (brightness != null) {
                        runOnUiThread {
                            try {
                                val layoutParams = window.attributes
                                layoutParams.screenBrightness = brightness.coerceIn(0.01f, 1.0f)
                                window.attributes = layoutParams
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("BRIGHTNESS_ERROR", e.message, null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Brightness argument is missing", null)
                    }
                }
                "resetScreenBrightness" -> {
                    runOnUiThread {
                        try {
                            val layoutParams = window.attributes
                            layoutParams.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = layoutParams
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BRIGHTNESS_ERROR", e.message, null)
                        }
                    }
                }
                "convertYuvToJpeg" -> {
                    val width = call.argument<Int>("width")
                    val height = call.argument<Int>("height")
                    val quality = call.argument<Int>("quality") ?: 70

                    if (width == null || height == null || width <= 0 || height <= 0) {
                        result.error("INVALID_ARGUMENT", "Invalid width or height", null)
                        return@setMethodCallHandler
                    }

                    // Check if planes were passed (zero-overhead from Dart)
                    val yBytes = call.argument<ByteArray>("y")
                    val uBytes = call.argument<ByteArray>("u")
                    val vBytes = call.argument<ByteArray>("v")
                    val nv21Direct = call.argument<ByteArray>("nv21")

                    backgroundExecutor.execute {
                        try {
                            val nv21: ByteArray
                            if (yBytes != null && uBytes != null && vBytes != null) {
                                val yRowStride = call.argument<Int>("yRowStride") ?: width
                                val uvRowStride = call.argument<Int>("uvRowStride") ?: width
                                val uvPixelStride = call.argument<Int>("uvPixelStride") ?: 2

                                val requiredSize = width * height * 3 / 2
                                val buffer = synchronized(this) {
                                    if (cachedNv21Buffer == null || cachedNv21Buffer!!.size != requiredSize) {
                                        cachedNv21Buffer = ByteArray(requiredSize)
                                    }
                                    cachedNv21Buffer!!
                                }

                                // 1. Copy Y plane
                                if (yRowStride == width) {
                                    System.arraycopy(yBytes, 0, buffer, 0, width * height)
                                } else {
                                    var srcPos = 0
                                    var dstPos = 0
                                    for (row in 0 until height) {
                                        System.arraycopy(yBytes, srcPos, buffer, dstPos, width)
                                        srcPos += yRowStride
                                        dstPos += width
                                    }
                                }

                                // 2. Copy UV planes (NV21 format: Y... V U V U...)
                                var dstUvPos = width * height
                                val halfHeight = height / 2
                                val halfWidth = width / 2
                                for (row in 0 until halfHeight) {
                                    val rowOffset = row * uvRowStride
                                    for (col in 0 until halfWidth) {
                                        val uvIndex = rowOffset + col * uvPixelStride
                                        buffer[dstUvPos++] = vBytes[uvIndex]
                                        buffer[dstUvPos++] = uBytes[uvIndex]
                                    }
                                }
                                nv21 = buffer
                            } else if (nv21Direct != null) {
                                nv21 = nv21Direct
                            } else {
                                runOnUiThread {
                                    result.error("INVALID_ARGUMENT", "No image data provided", null)
                                }
                                return@execute
                            }

                            val out = ByteArrayOutputStream(width * height / 3)
                            val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
                            yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
                            val jpegBytes = out.toByteArray()

                            runOnUiThread {
                                result.success(jpegBytes)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("COMPRESSION_ERROR", e.message, null)
                            }
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        backgroundExecutor.shutdown()
        super.onDestroy()
    }
}
