import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webcadroidclient/services/frame_converter.dart';
import 'package:webcadroidclient/widgets/camera_preview_card.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Pure night theme for minimal OLED/AMOLED power consumption
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
  final TextEditingController _portController = TextEditingController(text: "8080");

  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _selectedCameraIndex = 0;

  bool _isInitializing = true;
  bool _isChangingCamera = false;
  bool _isStreaming = false;
  bool _isPreviewPaused = false;

  // Stream preview variables
  WebSocket? _previewSocket;
  Uint8List? _streamPreviewFrame;
  Timer? _statusTimer;
  int _clientCount = 0;

  int _targetFps = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStatusTimer();
    _disconnectPreviewSocket(notify: false);
    if (_isStreaming) {
      FrameConverter.stopNativeStream();
    }
    _controller?.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isStreaming) {
      // While streaming, screen lock or background minimizes CPU: disconnect local preview socket.
      // The native CameraStreamService continues capturing and streaming in background.
      if (state == AppLifecycleState.paused) {
        _disconnectPreviewSocket();
      } else if (state == AppLifecycleState.resumed && !_isPreviewPaused) {
        final port = int.tryParse(_portController.text.trim()) ?? 8080;
        _connectPreviewSocket(port);
      }
      return;
    }

    final cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.paused) {
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_cameras.isNotEmpty) {
        _initCameraController(_cameras[_selectedCameraIndex]);
      }
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

  Future<void> _initCameraController(CameraDescription cameraDescription) async {
    if (_isChangingCamera) return;
    _isChangingCamera = true;

    if (_controller != null) {
      final oldController = _controller;
      _controller = null;
      if (mounted) setState(() {});
      await oldController?.dispose();
    }

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
        _isPreviewPaused = false;
      });
    } catch (e) {
      debugPrint('[CameraScreen] Error initializing viewfinder camera: $e');
      if (mounted) {
        setState(() => _isChangingCamera = false);
      }
    }
  }

  void _startStatusTimer() {
    _stopStatusTimer();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!_isStreaming) {
        timer.cancel();
        return;
      }
      final status = await FrameConverter.getNativeStreamStatus();
      if (mounted) {
        setState(() {
          _clientCount = (status['clientCount'] as int?) ?? 0;
        });
      }
    });
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _clientCount = 0;
  }

  void _connectPreviewSocket(int port) async {
    _disconnectPreviewSocket();
    try {
      final ws = await WebSocket.connect('ws://127.0.0.1:$port');
      _previewSocket = ws;
      ws.listen(
        (data) {
          if (data is List<int> && mounted && !_isPreviewPaused) {
            setState(() {
              _streamPreviewFrame = Uint8List.fromList(data);
            });
          }
        },
        onError: (e) {
          _disconnectPreviewSocket();
        },
        onDone: () {
          _disconnectPreviewSocket();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[CameraScreen] Error connecting to local preview stream: $e');
    }
  }

  void _disconnectPreviewSocket({bool notify = true}) {
    try {
      _previewSocket?.close();
    } catch (_) {}
    _previewSocket = null;
    _streamPreviewFrame = null;
    if (notify && mounted) {
      setState(() {});
    }
  }

  Future<void> _togglePreviewPause() async {
    if (_isStreaming) {
      if (_isPreviewPaused) {
        setState(() => _isPreviewPaused = false);
        final port = int.tryParse(_portController.text.trim()) ?? 8080;
        _connectPreviewSocket(port);
      } else {
        _disconnectPreviewSocket();
        setState(() => _isPreviewPaused = true);
      }
    } else {
      if (_controller != null && _controller!.value.isInitialized) {
        if (_isPreviewPaused) {
          await _controller!.resumePreview();
          setState(() => _isPreviewPaused = false);
        } else {
          await _controller!.pausePreview();
          setState(() => _isPreviewPaused = true);
        }
      }
    }
  }

  Future<void> _toggleStream() async {
    final bool usbDebug = await FrameConverter.isUsbDebuggingEnabled();
    if (!mounted) return;

    if (!usbDebug) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('USB Debugging Recommended', style: TextStyle(color: Colors.white)),
            content: const Text(
              'USB debugging is not enabled. If using USB cable forwarding, enable Developer Options -> USB Debugging.\n\nContinue anyway?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue', style: TextStyle(color: Colors.deepPurpleAccent)),
              ),
            ],
          );
        },
      );
      if (proceed != true) return;
    }

    if (_isStreaming) {
      await _stopStream();
    } else {
      await _startStream();
    }
  }

  Future<void> _startStream() async {
    final int port = int.tryParse(_portController.text.trim()) ?? 8080;

    try {
      // 1. Dispose Flutter CameraController to grant exclusive hardware access to the Camera2 native service
      if (_controller != null) {
        final old = _controller;
        _controller = null;
        if (mounted) setState(() {});
        await old?.dispose();
      }

      final cameraId = _cameras.isNotEmpty ? _cameras[_selectedCameraIndex].name : "0";

      // 2. Start native Android Foreground Service with Camera2 API and NanoWSD server
      final started = await FrameConverter.startNativeStream(
        port: port,
        fps: _targetFps,
        cameraId: cameraId,
        width: 1280,
        height: 720,
        quality: 70,
      );

      if (!started) {
        throw Exception('Native Camera2 service failed to start.');
      }

      setState(() {
        _isStreaming = true;
        _isPreviewPaused = true; // Default to energy-saving lock-screen ready mode
      });

      _startStatusTimer();
    } catch (e) {
      debugPrint('[CameraScreen] Error starting stream: $e');
      await _stopStream();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start camera stream: $e')),
        );
      }
    }
  }

  Future<void> _stopStream() async {
    _disconnectPreviewSocket();
    _stopStatusTimer();

    try {
      await FrameConverter.stopNativeStream();
    } catch (e) {
      debugPrint('[CameraScreen] Error stopping native stream: $e');
    }

    setState(() {
      _isStreaming = false;
      _isPreviewPaused = false;
      _streamPreviewFrame = null;
    });

    // Reopen viewfinder preview
    if (_cameras.isNotEmpty && mounted) {
      await _initCameraController(_cameras[_selectedCameraIndex]);
    }
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
    if (_cameras.isEmpty || _isStreaming) return;

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

    final port = int.tryParse(_portController.text.trim()) ?? 8080;

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
            streamPreviewFrame: _streamPreviewFrame,
            port: port,
            clientCount: _clientCount,
            onTogglePreviewPause: _togglePreviewPause,
          ),
          const SizedBox(height: 16),

          // Change Camera Button
          OutlinedButton.icon(
            onPressed: (_cameras.length > 1 && !_isChangingCamera && !_isStreaming)
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
            onPressed: (_controller != null && _controller!.value.isInitialized) || _isStreaming
                ? _toggleStream
                : null,
            icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
            label: Text(
              _isStreaming ? 'Stop Streaming' : 'Start Streaming to PC',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _isStreaming
                  ? Colors.indigoAccent.shade700
                  : Colors.tealAccent.shade700,
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