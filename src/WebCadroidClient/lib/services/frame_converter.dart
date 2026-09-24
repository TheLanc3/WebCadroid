import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service responsible for converting raw camera frames (YUV420) to JPEG bytes
/// and managing hardware settings (USB debugging check, screen brightness).
class FrameConverter {
  static const MethodChannel _platform = MethodChannel('com.example.webcadroidclient/settings');

  /// Converts a [CameraImage] to a compressed JPEG byte array.
  /// Passes image plane buffers directly to native code to avoid costly Dart loops and memory allocations.
  static Future<Uint8List?> convertYuvToJpeg(
    CameraImage image, {
    int quality = 70,
  }) async {
    if (image.planes.length < 3) {
      debugPrint('[FrameConverter] Unexpected plane count: ${image.planes.length}');
      return null;
    }

    try {
      final Uint8List? jpegBytes = await _platform.invokeMethod<Uint8List>(
        'convertYuvToJpeg',
        {
          'y': image.planes[0].bytes,
          'u': image.planes[1].bytes,
          'v': image.planes[2].bytes,
          'yRowStride': image.planes[0].bytesPerRow,
          'uvRowStride': image.planes[1].bytesPerRow,
          'uvPixelStride': image.planes[1].bytesPerPixel ?? 2,
          'width': image.width,
          'height': image.height,
          'quality': quality,
        },
      );
      return jpegBytes;
    } on PlatformException catch (e) {
      debugPrint('[FrameConverter] Native conversion error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[FrameConverter] Unexpected conversion error: $e');
      return null;
    }
  }

  /// Checks if ADB / USB debugging is enabled on the device.
  static Future<bool> isUsbDebuggingEnabled() async {
    try {
      final bool? isAdbEnabled = await _platform.invokeMethod<bool>('isUsbDebuggingEnabled');
      return isAdbEnabled ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FrameConverter] Failed to check USB debugging: ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Gets the current screen brightness (normalized between 0.0 and 1.0).
  static Future<double> getScreenBrightness() async {
    try {
      final double? brightness = await _platform.invokeMethod<double>('getScreenBrightness');
      return brightness ?? 1.0;
    } catch (e) {
      debugPrint('[FrameConverter] Failed to get brightness: $e');
      return 1.0;
    }
  }

  /// Sets the window brightness between 0.0 and 1.0 (e.g. 0.1 for 10%).
  static Future<void> setScreenBrightness(double brightness) async {
    try {
      await _platform.invokeMethod('setScreenBrightness', {'brightness': brightness});
    } catch (e) {
      debugPrint('[FrameConverter] Failed to set brightness: $e');
    }
  }

  /// Resets the window brightness to system default.
  static Future<void> resetScreenBrightness() async {
    try {
      await _platform.invokeMethod('resetScreenBrightness');
    } catch (e) {
      debugPrint('[FrameConverter] Failed to reset brightness: $e');
    }
  }
}
