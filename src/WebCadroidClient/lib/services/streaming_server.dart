import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Manages a WebSocket server for broadcasting binary camera frames (MJPEG over WS).
class StreamingServer {
  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  int _port = 8080;
  bool _isRunning = false;

  int get port => _port;
  bool get isRunning => _isRunning;
  int get clientCount => _clients.length;
  bool get hasClients => _clients.isNotEmpty;

  /// Starts the HTTP server and accepts WebSocket upgrade requests.
  Future<void> start(int port) async {
    await stop();
    _port = port;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _isRunning = true;
      debugPrint('[StreamingServer] WebSocket server started on port $_port');

      _server!.listen(
        (HttpRequest request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            try {
              final socket = await WebSocketTransformer.upgrade(request);
              _handleNewClient(socket);
            } catch (e) {
              debugPrint('[StreamingServer] Error upgrading WebSocket: $e');
            }
          } else {
            // Provide a friendly response for plain HTTP requests (e.g. browser healthcheck)
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.text;
            request.response.write('WebCadroid WebSocket Server is running on port $_port');
            await request.response.close();
          }
        },
        onError: (e) {
          debugPrint('[StreamingServer] Server error: $e');
        },
      );
    } catch (e) {
      _isRunning = false;
      debugPrint('[StreamingServer] Failed to bind port $_port: $e');
      rethrow;
    }
  }

  void _handleNewClient(WebSocket socket) {
    _clients.add(socket);
    debugPrint('[StreamingServer] Client connected. Total clients: ${_clients.length}');

    socket.listen(
      (data) {
        // We can handle incoming control messages here if needed in the future
      },
      onDone: () {
        _clients.remove(socket);
        debugPrint('[StreamingServer] Client disconnected. Total clients: ${_clients.length}');
      },
      onError: (e) {
        _clients.remove(socket);
        debugPrint('[StreamingServer] Client socket error: $e');
      },
      cancelOnError: true,
    );
  }

  /// Sends a binary JPEG frame to all connected WebSocket clients.
  void broadcastFrame(Uint8List frameBytes) {
    if (!_isRunning || _clients.isEmpty) return;

    for (final client in _clients.toList()) {
      try {
        client.add(frameBytes);
      } catch (e) {
        debugPrint('[StreamingServer] Failed to send frame to client: $e');
        _clients.remove(client);
        try {
          client.close();
        } catch (_) {}
      }
    }
  }

  /// Closes all active client connections and shuts down the server.
  Future<void> stop() async {
    _isRunning = false;
    for (final client in _clients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();

    if (_server != null) {
      try {
        await _server!.close(force: true);
      } catch (e) {
        debugPrint('[StreamingServer] Error closing server: $e');
      }
      _server = null;
    }
  }
}
