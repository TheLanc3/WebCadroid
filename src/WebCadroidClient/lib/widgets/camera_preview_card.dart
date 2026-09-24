import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Renders either the live camera preview or an energy-saving AMOLED black placeholder
/// when preview is paused during streaming.
class CameraPreviewCard extends StatelessWidget {
  final CameraController? controller;
  final bool isStreaming;
  final bool isPreviewPaused;
  final int port;
  final int clientCount;
  final VoidCallback onTogglePreviewPause;

  const CameraPreviewCard({
    super.key,
    required this.controller,
    required this.isStreaming,
    required this.isPreviewPaused,
    required this.port,
    required this.clientCount,
    required this.onTogglePreviewPause,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 380,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isStreaming ? Colors.tealAccent.shade700 : Colors.white12,
          width: isStreaming ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (controller == null || !controller!.value.isInitialized) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.deepPurpleAccent),
            SizedBox(height: 16),
            Text(
              'Initializing camera...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    // Energy saving placeholder when preview is paused
    if (isPreviewPaused) {
      return Container(
        color: Colors.black, // Pure black for OLED power savings
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isStreaming ? Icons.wifi_tethering : Icons.visibility_off_outlined,
              size: 56,
              color: isStreaming ? Colors.tealAccent : Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              isStreaming ? 'Streaming Active' : 'Preview Paused',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isStreaming
                  ? 'Port: $port  •  Connected PCs: $clientCount\nPreview paused to minimize power consumption'
                  : 'Tap below to resume camera preview',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onTogglePreviewPause,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Show Preview'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white30),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      );
    }

    // Live preview
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller!.value.previewSize?.height ?? 720,
            height: controller!.value.previewSize?.width ?? 1280,
            child: CameraPreview(controller!),
          ),
        ),
        if (isStreaming)
          Positioned(
            top: 12,
            right: 12,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onTogglePreviewPause,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pause, size: 16, color: Colors.tealAccent),
                      SizedBox(width: 4),
                      Text(
                        'Pause Preview',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

