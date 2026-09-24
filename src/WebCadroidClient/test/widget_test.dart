import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcadroidclient/main.dart';
import 'package:webcadroidclient/services/streaming_server.dart';

void main() {
  testWidgets('MyApp smoke test - renders dark theme and app bar', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Verify title in AppBar
    expect(find.text('WebCadroid'), findsOneWidget);

    // Verify that night/dark theme is applied
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
    expect(materialApp.darkTheme?.scaffoldBackgroundColor, Colors.black);
  });

  group('StreamingServer tests', () {
    test('Server starts, accepts WebSocket connections, and broadcasts', () async {
      final server = StreamingServer();
      const testPort = 18080;

      await server.start(testPort);
      expect(server.isRunning, isTrue);
      expect(server.port, testPort);
      expect(server.hasClients, isFalse);

      // Connect a test WebSocket client
      final client = await WebSocket.connect('ws://127.0.0.1:$testPort/ws');
      await Future.delayed(const Duration(milliseconds: 100));

      expect(server.hasClients, isTrue);
      expect(server.clientCount, 1);

      // Test broadcasting a frame
      final testFrame = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9]);
      final receivedDataCompleter = Completer<List<int>>();

      client.listen((data) {
        if (!receivedDataCompleter.isCompleted) {
          receivedDataCompleter.complete(data as List<int>);
        }
      });

      server.broadcastFrame(testFrame);

      final receivedData = await receivedDataCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(receivedData, testFrame);

      // Clean up
      await client.close();
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(server.hasClients, isFalse);
    });
  });
}
