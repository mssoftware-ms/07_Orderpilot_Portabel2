import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants/app_constants.dart';

/// WebSocket client for live candle streams from Bitunix
class BitunixWebSocketClient {
  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _streamController;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  /// Connect to Bitunix kline WebSocket stream
  Future<Stream<Map<String, dynamic>>> connect({
    required String symbol,
    required String interval,
  }) async {
    _streamController = StreamController<Map<String, dynamic>>.broadcast();

    final wsUrl = AppConstants.bitunixWsUrl;
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    _isConnected = true;

    _channel!.stream.listen(
      (data) {
        // Parse and forward to stream controller
        _streamController?.add({'raw': data});
      },
      onError: (error) {
        _isConnected = false;
        _streamController?.addError(error);
      },
      onDone: () {
        _isConnected = false;
        _streamController?.close();
      },
    );

    return _streamController!.stream;
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _channel?.sink.close();
    await _streamController?.close();
  }

  void dispose() {
    disconnect();
  }
}
