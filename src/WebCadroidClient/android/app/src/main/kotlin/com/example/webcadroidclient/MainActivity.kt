package com.example.webcadroidclient

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import android.graphics.Rect
import android.graphics.YuvImage
import android.graphics.ImageFormat
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.webcadroidclient/settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isUsbDebuggingEnabled") {
                val adbEnabled = Settings.Global.getInt(
                    contentResolver,
                    Settings.Global.ADB_ENABLED, 0
                ) != 0
                result.success(adbEnabled)
            } 
            if (call.method == "convertYuvToJpeg") {
                val nv21 = call.argument<ByteArray>("nv21")
                val width = call.argument<Int>("width")!!
                val height = call.argument<Int>("height")!!
                val quality = call.argument<Int>("quality") ?: 70

                if (nv21 != null) {
                    val out = ByteArrayOutputStream()
                    val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
                    yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
                    result.success(out.toByteArray())
                } else {
                    result.error("INVALID_ARGUMENT", "Null buffer", null)
                }
            }
            else {
                result.notImplemented()
            }
        }
    }

    
}
