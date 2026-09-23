import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const _platform = MethodChannel('com.example.webcadroidclient/settings');
  
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _selectedCameraIndex = 0;
  bool _isInitializing = true;

  HttpServer? _server;

  bool _isStreaming = false;

  int _targetFps = 30;
  int _port = 8080;

  final TextEditingController _portController = TextEditingController(text: "8080");

  List<int>? _lastJpegFrame;
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initCameras();
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        await _initCameraController(_cameras[_selectedCameraIndex]);
      }
    } catch (e) {
      debugPrint('Ошибка получения камер: $e');
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  Future<void> _initCameraController(CameraDescription cameraDescription) async {
    final bool wasStreaming = _isStreaming;

    // 2. Если стрим активен, останавливаем получение кадров со старой камеры
    if (_controller != null && _controller!.value.isStreamingImages) {
      try {
        await _controller!.stopImageStream();
      } catch (e) {
        debugPrint('Ошибка при остановке ImageStream: $e');
      }
    }

    // 3. Создаем новый контроллер
    final newController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // Явно задаем YUV420 для Android
    );

    // 4. Инициализируем НОВЫЙ контроллер, пока старый еще существует в памяти
    try {
      await newController.initialize();
    } catch (e) {
      debugPrint('Ошибка инициализации новой камеры: $e');
      return;
    }

    // 5. Безопасно уничтожаем СТАРЫЙ контроллер
    final oldController = _controller;
    _controller = newController;

    if (mounted) {
      setState(() {});
    }

    await oldController?.dispose();

    // 6. Если стрим был активен — возобновляем его на НОВОЙ камере
    if (wasStreaming && _controller != null && _controller!.value.isInitialized) {
      await _startStreamingProcess();
    }
  }

  Future<void> _startStreamingProcess() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isStreamingImages) return;

    _isStreaming = true;

    await _controller!.startImageStream((CameraImage image) async {
      if (!_isStreaming) return;

      // Наша нативная конвертация YUV в JPEG
      final jpegBytes = await _convertYuvToJpeg(image);

      if (jpegBytes.isNotEmpty) {
        // Обновляем буфер для HTTP-сервера
        _lastJpegFrame = jpegBytes; 
      }
    });
  }

  Future<bool> _checkUsbDebugging() async {
    try {
      final bool isAdbEnabled = await _platform.invokeMethod('isUsbDebuggingEnabled');
      return isAdbEnabled;
    } on PlatformException catch (e) {
      debugPrint("Failed to check USB-debugging: ${e.message}");
      return false;
    }
  }

  Future<void> _toggleStream() async {
    bool usbDebug = await _checkUsbDebugging();
    if (!usbDebug) {
      await showDialog(
        context: context, 
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text("USB-debugging is not available"),
            content: const Text("You need to enable USB-debugging to allow stream forward"),
          );
        });
    } else if (_isStreaming) {
      await _stopStream();
      WakelockPlus.disable();
    } else {
      await _startStream();
      WakelockPlus.enable();
    }
  }

  Future<void> _startStream() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      // 1. Читаем порт из поля ввода
      _port = int.tryParse(_portController.text) ?? 8080;

      // 2. Запускаем HttpServer на всех сетевых интерфейсах (0.0.0.0)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _listenHttpRequests();

      // 3. Подписываемся на поток кадров с камеры с учетом FPS
      final frameIntervalMs = (1000 / _targetFps).round();

      await _controller!.startImageStream((CameraImage image) async {
        final now = DateTime.now();
        if (now.difference(_lastFrameTime).inMilliseconds < frameIntervalMs) {
          return; // Пропускаем кадры для ограничения FPS
        }
        if (_isProcessingFrame) return;

        _isProcessingFrame = true;
        _lastFrameTime = now;

        try {
          // Преобразование YUV420/NV21 в JPEG (используйте ваш существующий конвертер/пакет)
          _lastJpegFrame = await _convertYuvToJpeg(image); 
        } finally {
          _isProcessingFrame = false;
        }
      });

      setState(() {
        _isStreaming = true;
      });
    } catch (e) {
      debugPrint("Error starting server: $e");
    }
  }

  Future<void> _stopStream() async {
    if (_controller != null && _controller!.value.isStreamingImages) {
      await _controller!.stopImageStream();
    }
    await _server?.close(force: true);
    _server = null;

    setState(() {
      _isStreaming = false;
    });
  }

  void _listenHttpRequests() {
    _server?.listen((HttpRequest request) async {
      if (request.uri.path == '/stream') {
        // Устанавливаем заголовок MJPEG
        request.response.headers.contentType =
            ContentType.parse('multipart/x-mixed-replace; boundary=--frame');

        while (_isStreaming) {
          if (_lastJpegFrame != null) {
            try {
              request.response.write('--frame\r\n');
              request.response.write('Content-Type: image/jpeg\r\n');
              request.response.write('Content-Length: ${_lastJpegFrame!.length}\r\n\r\n');
              request.response.add(_lastJpegFrame!);
              request.response.write('\r\n');
              await request.response.flush();
            } catch (_) {
              // Клиент отключился
              break;
            }
          }
          await Future.delayed(Duration(milliseconds: (1000 / _targetFps).round()));
        }
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  }

  Future<List<int>> _convertYuvToJpeg(CameraImage image) async {
    try {
      // 1. Преобразуем плоскости YUV420 в формат NV21, подходящий для YuvImage в Android
      final Uint8List nv21Bytes = _yuv420ToNv21(image);

      // 2. Вызываем нативный Kotlin-метод
      final Uint8List? jpegBytes = await _platform.invokeMethod<Uint8List>(
        'convertYuvToJpeg',
        {
          'nv21': nv21Bytes,
          'width': 1280,
          'height': 720,
          'quality': 70, // Качество сжатия от 1 до 100
        },
      );

      return jpegBytes ?? [];
    } on PlatformException catch (e) {
      debugPrint("Native conversion error: ${e.message}");
      return [];
    }
  }

  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    
    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;

    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Копируем Y плоскость
    int id = 0;
    for (int i = 0; i < height; i++) {
      for (int j = 0; j < width; j++) {
        nv21[id++] = yPlane.bytes[i * yPlane.bytesPerRow + j];
      }
    }

    // Переплетаем V и U плоскости (NV21 формат: YYYY... VUVU...)
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 2;

    for (int i = 0; i < height ~/ 2; i++) {
      for (int j = 0; j < width ~/ 2; j++) {
        final int uvIndex = i * uvRowStride + j * uvPixelStride;
        nv21[id++] = vPlane.bytes[uvIndex];
        nv21[id++] = uPlane.bytes[uvIndex];
      }
    }

    return nv21;
  }

  String _getCameraName(CameraDescription camera) {
    switch (camera.lensDirection) {
      case CameraLensDirection.front:
        return 'Front camera';
      case CameraLensDirection.back:
        return 'Rear camera (${camera.name})';
      case CameraLensDirection.external:
        return 'External camera';
    }
  }

  Future<void> _showCameraSelectionDialog() async {
    if (_cameras.isEmpty) return;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select camera'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(_cameras.length, (index) {
                final camera = _cameras[index];
                final isSelected = index == _selectedCameraIndex;

                return ListTile(
                  leading: Icon(
                    camera.lensDirection == CameraLensDirection.front
                        ? Icons.camera_front
                        : Icons.camera_rear,
                    color: isSelected ? Theme.of(context).primaryColor : null,
                  ),
                  title: Text(
                    _getCameraName(camera),
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: isSelected
                      ? Icon(Icons.check, color: Theme.of(context).primaryColor)
                      : null,
                  onTap: () async {
                    Navigator.pop(context); // Закрываем диалог
                    if (!isSelected) {
                      setState(() {
                        _selectedCameraIndex = index;
                      });
                      await _initCameraController(camera);
                    }
                  },
                );
              }),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebCadroid', style: TextStyle(fontWeight: FontWeight(750)),),
        centerTitle: true,
      ),
      body: _buildBody(),
    );
  }
  
  Widget _buildBody() {
    if (_isInitializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_cameras.isEmpty || _controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: Text('Camera unavaliable')),
      );
    }

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Container(
              height: 400, // Ограничение высоты контейнера
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 350,
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _controller!.value.previewSize!.height,
                      height: _controller!.value.previewSize!.width,
                      child: CameraPreview(_controller!),
                    ),
                  ),
                ),
              )
            ),
            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: _cameras.length > 1 ? _showCameraSelectionDialog : null,
              icon: const Icon(Icons.switch_camera),
              label: const Text('Change camera'),
            ),

            TextField(
              controller: _portController,
              enabled: !_isStreaming,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // Слайдер FPS (15..60)
            Text('Target FPS: $_targetFps'),
            Slider(
              value: _targetFps.toDouble(),
              min: 15,
              max: 60,
              divisions: 9, // Шаг 5 (15, 20, 25... 60)
              label: '$_targetFps FPS',
              onChanged: _isStreaming
                  ? null
                  : (val) {
                      setState(() {
                        _targetFps = val.round();
                      });
                    },
            ),
            const SizedBox(height: 16),

            // Кнопка переключения трансляции
            ElevatedButton(
              onPressed: _toggleStream,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? const Color.fromARGB(255, 255, 129, 120) : const Color.fromARGB(255, 108, 183, 111),
                foregroundColor: _isStreaming ? const Color.fromARGB(255, 143, 52, 45) : const Color.fromARGB(255, 51, 128, 53),
              ),
              child: Text(_isStreaming ? 'Stop Stream' : 'Translate to PC'),
            ),
          ],
        ),
      ),
    );
  }
}