import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webcadroidclient/services/frame_converter.dart';
import 'package:webcadroidclient/services/streaming_server.dart';
import 'package:webcadroidclient/widgets/camera_preview_card.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Pure night theme for minimal OLED/AMOLED power consumption during wakelock
    final darkTheme = ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
        primary: Colors.deepPurpleAccent,
        secondary: Colors.tealAccent,
        surface: Color(0xFF141414),
        surfaceContainerHighest: Color(0xFF222222),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF141414),
      ),
    );

    return MaterialApp(
      title: 'WebCadroid',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: darkTheme,
      darkTheme: darkTheme,
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final StreamingServer _streamingServer = StreamingServer();
  final TextEditingController _portController = TextEditingController(text: "8080");

  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _selectedCameraIndex = 0;

  bool _isInitializing = true;
  bool _isChangingCamera = false;
  bool _isStreaming = false;
  bool _isPreviewPaused = false;
  double? _previousBrightness;

  int _targetFps = 30;
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _controller?.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // App minimized: stop stream if active
      if (_isStreaming) {
        _stopStream();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Re-initialize camera on resume if needed
      _initCameraController(_cameras[_selectedCameraIndex]);
    }
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        await _initCameraController(_cameras[_selectedCameraIndex]);
      }
    } catch (e) {
      debugPrint('[CameraScreen] Error getting cameras: $e');
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  /// Safely disposes the old camera controller and initializes the new camera controller.
  Future<void> _initCameraController(CameraDescription cameraDescription) async {
    if (_isChangingCamera) return;
    _isChangingCamera = true;

    final bool wasStreaming = _isStreaming;
    final bool wasPreviewPaused = _isPreviewPaused;

    // 1. If currently streaming, stop image stream from old controller
    if (_controller != null && _controller!.value.isStreamingImages) {
      try {
        await _controller!.stopImageStream();
      } catch (e) {
        debugPrint('[CameraScreen] Error stopping image stream: $e');
      }
    }

    // 2. Safely dispose the old controller FIRST before allocating the new one
    // On Android Camera2 HAL, two cameras cannot be held open concurrently
    if (_controller != null) {
      final oldController = _controller;
      _controller = null;
      if (mounted) setState(() {});
      await oldController?.dispose();
    }

    // 3. Create and initialize new controller
    final newController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await newController.initialize();
      if (!mounted) {
        await newController.dispose();
        return;
      }

      setState(() {
        _controller = newController;
        _isChangingCamera = false;
      });

      // 4. Restore streaming state if stream was active
      if (wasStreaming) {
        await _startCameraImageStream();
        if (wasPreviewPaused) {
          await _pausePreview();
        }
      }
    } catch (e) {
      debugPrint('[CameraScreen] Error initializing new camera: $e');
      if (mounted) {
        setState(() => _isChangingCamera = false);
      }
    }
  }

  Future<void> _startCameraImageStream() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isStreamingImages) return;

    final frameIntervalMs = (1000 / _targetFps).round();

    await _controller!.startImageStream((CameraImage image) async {
      if (!_isStreaming) return;

      // Skip image processing if no WebSocket clients are listening to conserve battery and CPU
      if (!_streamingServer.hasClients) return;

      final now = DateTime.now();
      if (now.difference(_lastFrameTime).inMilliseconds < frameIntervalMs) {
        return; // FPS limiting
      }

      if (_isProcessingFrame) return; // Drop frame if previous is still compressing
      _isProcessingFrame = true;
      _lastFrameTime = now;

      try {
        final jpegBytes = await FrameConverter.convertYuvToJpeg(image);
        if (jpegBytes != null && jpegBytes.isNotEmpty) {
          _streamingServer.broadcastFrame(jpegBytes);
        }
      } catch (e) {
        debugPrint('[CameraScreen] Frame processing error: $e');
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  Future<void> _pausePreview() async {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        await _controller!.pausePreview();
      } catch (e) {
        debugPrint('[CameraScreen] Error pausing preview: $e');
      }
    }
    if (mounted) {
      setState(() => _isPreviewPaused = true);
    }
  }

  Future<void> _resumePreview() async {
    if (_controller != null && _controller!.value.isInitialized) {
      try {
        await _controller!.resumePreview();
      } catch (e) {
        debugPrint('[CameraScreen] Error resuming preview: $e');
      }
    }
    if (mounted) {
      setState(() => _isPreviewPaused = false);
    }
  }

  Future<void> _togglePreviewPause() async {
    if (_isPreviewPaused) {
      await _resumePreview();
    } else {
      await _pausePreview();
    }
  }

  Future<void> _toggleStream() async {
    final bool usbDebug = await FrameConverter.isUsbDebuggingEnabled();
    if (!mounted) return;

    if (!usbDebug) {
      await showDialog(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('USB Debugging Required', style: TextStyle(color: Colors.white)),
            content: const Text(
              'Please enable USB debugging in Developer Options on your device to forward video to your PC.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK', style: TextStyle(color: Colors.deepPurpleAccent)),
              ),
            ],
          );
        },
      );
      return;
    }

    if (_isStreaming) {
      await _stopStream();
    } else {
      await _startStream();
    }
  }

  Future<void> _startStream() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    final port = int.tryParse(_portController.text) ?? 8080;

    try {
      await _streamingServer.start(port);
      _isStreaming = true;

      // Save previous screen brightness and reduce to 10% (0.1) for energy savings
      _previousBrightness = await FrameConverter.getScreenBrightness();
      await FrameConverter.setScreenBrightness(0.1);

      // Start camera image processing
      await _startCameraImageStream();

      // Pause preview automatically to save battery on OLED screens
      await _pausePreview();

      // Keep screen awake while streaming
      await WakelockPlus.enable();

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[CameraScreen] Error starting stream: $e');
      _isStreaming = false;

      // Restore brightness if failed
      if (_previousBrightness != null) {
        await FrameConverter.setScreenBrightness(_previousBrightness!);
        _previousBrightness = null;
      } else {
        await FrameConverter.resetScreenBrightness();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start server: $e')),
        );
      }
    }
  }

  Future<void> _stopStream() async {
    _isStreaming = false;

    if (_controller != null && _controller!.value.isStreamingImages) {
      try {
        await _controller!.stopImageStream();
      } catch (e) {
        debugPrint('[CameraScreen] Error stopping image stream: $e');
      }
    }

    await _streamingServer.stop();
    await WakelockPlus.disable();
    await _resumePreview();

    // Reset screen brightness back to previous value or system default
    if (_previousBrightness != null) {
      await FrameConverter.setScreenBrightness(_previousBrightness!);
      _previousBrightness = null;
    } else {
      await FrameConverter.resetScreenBrightness();
    }

    if (mounted) setState(() {});
  }

  String _getCameraName(CameraDescription camera) {
    switch (camera.lensDirection) {
      case CameraLensDirection.front:
        return 'Front Camera';
      case CameraLensDirection.back:
        return 'Rear Camera (${camera.name})';
      case CameraLensDirection.external:
        return 'External Camera';
    }
  }

  Future<void> _showCameraSelectionDialog() async {
    if (_cameras.isEmpty) return;

    await showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Select Camera', style: TextStyle(color: Colors.white)),
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
                    color: isSelected ? Colors.deepPurpleAccent : Colors.white70,
                  ),
                  title: Text(
                    _getCameraName(camera),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check, color: Colors.deepPurpleAccent)
                      : null,
                  onTap: () async {
                    Navigator.pop(dialogContext);
                    if (!isSelected && mounted) {
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'WebCadroid',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
      );
    }

    if (_cameras.isEmpty) {
      return const Center(
        child: Text(
          'No camera available on this device',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
      );
    }

    final port = int.tryParse(_portController.text) ?? 8080;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Camera Preview Card
          CameraPreviewCard(
            controller: _controller,
            isStreaming: _isStreaming,
            isPreviewPaused: _isPreviewPaused,
            port: port,
            clientCount: _streamingServer.clientCount,
            onTogglePreviewPause: _togglePreviewPause,
          ),
          const SizedBox(height: 16),

          // Change Camera Button
          OutlinedButton.icon(
            onPressed: (_cameras.length > 1 && !_isChangingCamera)
                ? _showCameraSelectionDialog
                : null,
            icon: const Icon(Icons.switch_camera),
            label: Text(_isChangingCamera ? 'Switching...' : 'Change Camera'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: Colors.white24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),

          // Port Input
          TextField(
            controller: _portController,
            enabled: !_isStreaming,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Port',
              labelStyle: const TextStyle(color: Colors.white70),
              filled: true,
              fillColor: const Color(0xFF181818),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.deepPurpleAccent),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Target FPS Slider
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF181818),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Target FPS', style: TextStyle(color: Colors.white70)),
                    Text(
                      '$_targetFps FPS',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _targetFps.toDouble(),
                  min: 15,
                  max: 60,
                  divisions: 9,
                  label: '$_targetFps FPS',
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: Colors.white24,
                  onChanged: _isStreaming
                      ? null
                      : (val) {
                          setState(() {
                            _targetFps = val.round();
                          });
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Stream Toggle Button
          FilledButton.icon(
            onPressed: (_controller != null && _controller!.value.isInitialized)
                ? _toggleStream
                : null,
            icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
            label: Text(
              _isStreaming ? 'Stop Streaming' : 'Start Streaming to PC',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _isStreaming ? Colors.redAccent.shade700 : Colors.green.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}