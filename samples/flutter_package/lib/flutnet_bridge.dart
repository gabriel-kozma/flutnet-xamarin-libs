﻿import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import 'package:flutter/widgets.dart';
import 'package:synchronized/synchronized.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:flutter_package/flutnet/service_model/platform_operation_exception.dart';

///
/// The bridge communication type with native side.
///
enum FlutnetBridgeMode {
  PlatformChannel,
  WebSocket,
}

///
/// The configuration used by the [FlutnetBridge].
/// Setup this before running the flutter application.
/// [main.dart] --> void main()
///
class FlutnetBridgeConfig {
  static FlutnetBridgeMode mode = FlutnetBridgeMode.PlatformChannel;
}

class FlutnetBridge {
  // Events from native side (Xamarin)
  static const EventChannel _events = EventChannel('flutnetbridge.outgoing');

  // The real event stream from navive side
  static final Stream<_FlutnetEventInfo> _channelEvent =
      _events.receiveBroadcastStream().map(_mapEvent);

  // The event stream exposed to all the services
  final Stream<_FlutnetEventInfo>
      _netEvent; // = _events.receiveBroadcastStream().map(_mapEvent);

  //
  // Filter the bridge event stream
  // using a specific instanceId, event
  //
  Stream<Map> events({
    String instanceId,
    String event,
  }) {
    // Filter the stream by instanceId and event name.
    return _netEvent
        .where((e) => e.instanceId == instanceId && e.event == event)
        .map((e) => e.args);
  }

  static final FlutnetBridge _instance =
      FlutnetBridge._internal(FlutnetBridgeConfig.mode);

  FlutnetBridge._internal(FlutnetBridgeMode mode)
      : invokeMethod = (buildMode == _BuildMode.release)
            ? _invokeOnChannel
            : (mode == FlutnetBridgeMode.WebSocket)
                ? _invokeOnSocket
                : _invokeOnChannel,
        _netEvent = (buildMode == _BuildMode.release)
            ? _channelEvent
            : (mode == FlutnetBridgeMode.WebSocket)
                ? _WebSocketChannel().events
                : _channelEvent;

  factory FlutnetBridge() => _instance;

  /// Invoke the message on the channel
  final Future<Map<String, dynamic>> Function({
    @required String instanceId,
    @required String service,
    @required String operation,
    @required Map<String, dynamic> arguments,
  }) invokeMethod;

  static Future<Map<String, dynamic>> _invokeOnChannel({
    @required String instanceId,
    @required String service,
    @required String operation,
    @required Map<String, dynamic> arguments,
  }) {
    print(
      "Invoking on platform channel $operation on $service :$instanceId: build mode:$buildMode",
    );
    return _PlatformChannel().invokeMethod(
      instanceId: instanceId,
      service: service,
      operation: operation,
      arguments: arguments,
    );
  }

  static Future<Map<String, dynamic>> _invokeOnSocket({
    @required String instanceId,
    @required String service,
    @required String operation,
    @required Map<String, dynamic> arguments,
  }) {
    print(
      "Invoking on socket $operation on $service :$instanceId: build mode:$buildMode",
    );
    return _WebSocketChannel().invokeMethod(
      instanceId: instanceId,
      service: service,
      operation: operation,
      arguments: arguments,
    );
  }

  ///
  /// Decoding events function
  ///
  static _FlutnetEventInfo _mapEvent(dynamic event) {
    try {
      Map json = jsonDecode(event as String);
      return _FlutnetEventInfo.fromJson(json);
    } on Exception catch (ex) {
      print("Error decoding event: $ex");
      return null;
    }
  }

  @mustCallSuper
  void dispose() {
    // Release debug socket resources
    if (invokeMethod == _invokeOnSocket) {
      _WebSocketChannel().dispose();
    }
  }
}

class _FlutnetEventInfo {
  final String instanceId; // The instance id that have the event
  final String event; // The reference for the event
  final Map args; // The data sended throw the event

  _FlutnetEventInfo({
    @required this.instanceId,
    @required this.event,
    this.args,
  });

  Map<String, dynamic> toJson() {
    return {
      'instanceId': instanceId,
      'event': event,
      'args': args,
    };
  }

  static _FlutnetEventInfo fromJson(Map json) {
    if (json == null) return null;

    return _FlutnetEventInfo(
      instanceId: json['instanceId'] as String,
      event: json['event'] as String,
      args: json['args'] as Map,
    );
  }
}

class _FlutnetMethodInfo {
  final int requestId;
  final String instance;
  final String service;
  final String operation;

  _FlutnetMethodInfo({
    @required this.requestId,
    @required this.instance,
    @required this.service,
    @required this.operation,
  });

  Map<String, dynamic> toJson() {
    return {
      'requestId': requestId,
      'instance': instance,
      'service': service,
      'operation': operation,
    };
  }

  static _FlutnetMethodInfo fromJson(Map json) {
    if (json == null) return null;

    return _FlutnetMethodInfo(
      requestId: json['requestId'] as int,
      instance: json['instance'] as String,
      service: json['service'] as String,
      operation: json['operation'] as String,
    );
  }
}

class _FlutnetMessage {
  final _FlutnetMethodInfo methodInfo;
  final Map<String, dynamic> arguments;
  final Map<String, dynamic> result;
  final String errorCode;
  final String errorMessage;
  final Map event;
  final Map exception;

  _FlutnetMessage({
    this.methodInfo,
    this.arguments,
    this.result,
    this.errorCode,
    this.errorMessage,
    this.event,
    this.exception,
  });

  Map<String, dynamic> toJson() {
    return {
      'methodInfo': methodInfo?.toJson() ?? null,
      'arguments': arguments,
      'result': result,
      'errorCode': errorCode,
      'errorMessage': errorMessage,
      'event': event,
      'exception': exception,
    };
  }

  static _FlutnetMessage fromJson(Map json) {
    if (json == null) return null;

    return _FlutnetMessage(
      methodInfo: json.containsKey('methodInfo')
          ? _FlutnetMethodInfo.fromJson(json['methodInfo'] as Map)
          : null,
      arguments: json['arguments'],
      result: json['result'],
      errorCode: json['errorCode'],
      errorMessage: json['errorMessage'],
      event: json['event'],
      exception: json['exception'],
    );
  }
}

class _PlatformChannel {
  static _PlatformChannel _instance = _PlatformChannel._internal();

  factory _PlatformChannel() => _instance;

  // Send request id
  int _uniqueId = 0;

  Lock _sendLock = new Lock();

  /// All the request to be satisfied by channel.
  Map<int, Completer<dynamic>> _sendRequestMap = {};

  // The real communication channel with native platform
  final _platformChannel = MethodChannel('flutnetbridge.incoming');

  // Native channel used to verify if flutter is embedded or not
  final _supportChannel = MethodChannel('flutnetbridge.support');

  Future<bool> _isAppEmbedded() async {
    try {
      var value = await _supportChannel.invokeMethod("test", "test");
      return true;
    } catch (ex) {
      return false;
    }
  }

  _PlatformChannel._internal() {
    _platformChannel.setMethodCallHandler(_onMessageReceived);
  }

  _releaseMemory() {
    try {
      _sendRequestMap?.clear();
    } catch (ex) {}
  }

  static const _emptyString = "";

  /// How manage data reception from native channel.
  Future<dynamic> _onMessageReceived(MethodCall call) async {
    // Manage message received
    try {
      String jsonMessage = call.arguments as String;

      // Json decoding
      Map<String, dynamic> json = jsonDecode(jsonMessage);
      _FlutnetMessage msg = _FlutnetMessage.fromJson(json);

      // Insert the response the the map
      await _sendLock.synchronized(() {
        if (_sendRequestMap.containsKey(msg.methodInfo.requestId)) {
          // Invoke the task completion
          Completer<Map<String, dynamic>> request =
              _sendRequestMap[msg.methodInfo.requestId];

          bool isFailed = msg.errorCode != null && msg.errorCode.isNotEmpty;
          if (msg.exception != null) {
            var exception = PlatformOperationException.fromJsonDynamic(
              msg.exception as Map<String, dynamic>,
            );
            request.completeError(exception);
          } else if (isFailed) {
            //* Handle invoke error
            String errorMessage = "${msg.errorCode}, ${msg.errorMessage ?? ''}";
            request.completeError(Exception(errorMessage));
          } else {
            //* handle invoke complete
            request.complete(msg.result);
          }

          _sendRequestMap.remove(msg.methodInfo.requestId);
        }
      });
    } catch (e) {
      // Error during deserialization
      print(
        "flutter_xamarin_debug: error during _onMessageReceived deserialization.",
      );
    }

    return _emptyString;
  }

  Future<Map<String, dynamic>> invokeMethod({
    @required String instanceId,
    @required String service,
    @required String operation,
    @required Map<String, dynamic> arguments,
  }) {
    final Completer<Map<String, dynamic>> completer =
        new Completer<Map<String, dynamic>>();

    _sendLock.synchronized(
      () async {
        int sendRequestId = ++_uniqueId;

        try {
          final _FlutnetMethodInfo methodInfo = _FlutnetMethodInfo(
            requestId: sendRequestId,
            instance: instanceId,
            service: service,
            operation: operation,
          );

          // Save the request
          _sendRequestMap.putIfAbsent(
            methodInfo.requestId,
            () => completer,
          );

          // Seriliaze all the method info as Json String
          final String jsonMethodInfo = jsonEncode(methodInfo);

          // Serialize all the args as Json string
          final Map<String, String> args = arguments
              .map((argName, value) => MapEntry(argName, jsonEncode(value)));

          // Send to platform channel
          await _platformChannel.invokeMethod(
            jsonMethodInfo,
            args,
          );
        } on MissingPluginException catch (ex) {
          _sendRequestMap.remove(sendRequestId);

          bool isAppEmbedded = await _isAppEmbedded();

          if (isAppEmbedded) {
            // Invalid call in embedded app
            completer.completeError(Exception(
              "Flutter is running as an EMBEDDED module inside your Xamarin app, but your Xamarin project have the FlutnetBrigde configuration set to ${FlutnetBridgeMode.WebSocket}.\n"
              "If you want to run your Flutter project as a STANDALONE application, use your preferred Flutter IDE (like Visual Studio Code).\n"
              "Otherwise configure your Xamarin project to use ${FlutnetBridgeMode.PlatformChannel}.\n"
              "Ensure to have the same FlutnetBrigde configuration for both Flutter and Xamarin project.",
            ));
          } else {
            // The user have run flutter using visual studio code, but the configuration cannot be BridgeMode.PlatformChannel
            completer.completeError(Exception(
              "Flutter is running as a STANDALONE application, so the FlutnetBrigde configuration must be ${FlutnetBridgeMode.WebSocket}.\n"
              "Set 'FlutnetBridgeConfig.mode = ${FlutnetBridgeMode.WebSocket}' in your Flutter project.\n"
              "Remember to start your Xamarin project with the same FlutnetBridgeMode configuration.",
            ));
          }
        } on Exception catch (ex) {
          debugPrint("Error during invokeMethod on platform channel");
          _sendRequestMap.remove(sendRequestId);
          // Error during send
          completer.completeError(ex);
        }
      },
    );

    return completer.future;
  }

  @mustCallSuper
  void dispose() {
    _sendLock.synchronized(() {
      _releaseMemory();
    });
  }
}

class _WebSocketChannel {
  static _WebSocketChannel _instance;

  final StreamController<_FlutnetEventInfo> _eventsController;
  final Stream<_FlutnetEventInfo> _eventsOut;
  final Sink<_FlutnetEventInfo> _eventsIn;

  Stream<_FlutnetEventInfo> get events => _eventsOut;

  // Native channel used to verify if flutter is embedded or not
  final _supportChannel = MethodChannel('flutnetbridge.support');

  Future<bool> _isAppEmbedded() async {
    try {
      var value = await _supportChannel.invokeMethod("test", "test");
      return true;
    } catch (ex) {
      return false;
    }
  }

  Future<FlutnetBridgeMode> _getXamarinBridgeMode() async {
    try {
      String value = await _supportChannel.invokeMethod("FlutnetBridgeMode");
      switch (value) {
        case "PlatformChannel":
          return FlutnetBridgeMode.PlatformChannel;
        case "WebSocket":
          return FlutnetBridgeMode.WebSocket;
        default:
          return null;
      }
    } catch (ex) {
      return null;
    }
  }

  _WebSocketChannel._internal(
      this._eventsController, this._eventsIn, this._eventsOut) {
    _sendLock.synchronized(() async {
      // Check if the app is embedded
      bool isAppEmbedded = await _isAppEmbedded();

      if (isAppEmbedded) return;

      // Wait until the connection open
      while (_socketChannelConnected == false) {
        try {
          await _autoConnect(
            delay: const Duration(seconds: 1),
            forceOpen: true,
          );
        } catch (ex) {
          // Error during connection opening
          debugPrint(ex);
        }
      }
    });
  }

  factory _WebSocketChannel() {
    if (_instance == null) {
      StreamController<_FlutnetEventInfo> controller =
          StreamController<_FlutnetEventInfo>();
      Stream<_FlutnetEventInfo> outEvent =
          controller.stream.asBroadcastStream();
      _instance =
          _WebSocketChannel._internal(controller, controller.sink, outEvent);
    }
    return _instance;
  }

  // Dispose state
  bool _disposed = false;

  ///
  /// The url user for the connection
  ///
  String _url = "ws://127.0.0.1:12345/flutter";

  //
  // Channel used to invoke methods from Flutter to web socket native backend application.
  //
  WebSocketChannel _socketChannel;

  // Status of the debug connection
  bool _socketChannelConnected = false;

  // Send request id
  int _uniqueId = 0;

  Lock _sendLock = new Lock();

  ///
  /// All the request to be satisfied by debug WEB SOCKET.
  ///
  Map<int, Completer<dynamic>> _sendRequestMap = {};

  ///
  /// All message sended to debug server
  /// that wait a respose
  ///
  Map<int, String> _outboxMessages = {};

  ///
  /// Oopen the connection resending all the queued messages with no response.
  ///
  Future<void> _autoConnect({Duration delay, bool forceOpen = false}) async {
    // * If disposed we release the memory
    if (_disposed) {
      await _closeConnection();
      _socketChannelConnected = false;
      await _releaseMemory();
    }
    // * If the connectin is open, but not message: close the connection.
    else if (_outboxMessages.length <= 0 &&
        _socketChannelConnected == true &&
        forceOpen == false) {
      await _closeConnection();
      _socketChannelConnected = false;
      await _releaseMemory();
    }
    // * Reopen the connection
    else if ((_outboxMessages.length > 0 && _socketChannelConnected == false) ||
        (forceOpen == true && _socketChannelConnected == false)) {
      // Aspetto un po prima di collegarmi
      if (delay != null) {
        await Future.delayed(delay);
      }

      //* --------------------------------------------------------------
      //* IOWebSocketChannel.connect("ws://127.0.0.1:12345/flutter");
      //* OPEN THE CONNECCTION
      //* --------------------------------------------------------------
      _socketChannel = IOWebSocketChannel.connect(this._url);

      _socketChannel.stream.listen(
        _onMessageReceived,
        cancelOnError: false,
        onDone: _onConnectionClosed,
        //! in caso di erroe sull'apertura viene emesso l'evento qui
        onError: _onConnectionError,
      );

      //* IMPORTANT NOTE: the connection never fail during the opening call.
      //* Only after that will be invoked the error event.
      _socketChannelConnected = true;

      // Se sono connesso provo ad inviare i messaggi
      if (_socketChannelConnected) {
        try {
          //* Try to resend all the append messages (IN SORT ORDER)
          List<int> sortedRequests = _outboxMessages.keys.toList()..sort();

          sortedRequests.forEach((reqId) {
            String msg = _outboxMessages[reqId];

            _socketChannel.sink.add(msg);
          });
        } catch (ex) {
          debugPrint("Error sending messages");
          _socketChannelConnected = false;
          _closeConnection();
        }
      } else {
        //! Error after N try
        throw Exception("Error opening channel!");
      }
    }
  }

  Future _closeConnection() async {
    try {
      await _socketChannel?.sink?.close(status.normalClosure);
    } catch (ex) {}
  }

  /// Release all the resources.
  _releaseMemory() async {
    // Try to resend all the append messages (IN SORT ORDER)
    List<int> sortedRequests = _sendRequestMap.keys.toList()..sort();

    sortedRequests.forEach((reqId) {
      _sendRequestMap[reqId].completeError(
        Exception("Connection closed by client."),
      );
    });

    try {
      _sendRequestMap?.clear();
    } catch (ex) {}

    try {
      _outboxMessages?.clear();
    } catch (ex) {}

    _eventsController.close();
  }

  /// Connection close event.
  Future _onConnectionClosed() async {
    print("Connection closed.");
    await _sendLock.synchronized(() async {
      _socketChannelConnected = false;

      //* ----------------------------------------------------------------
      //* Wait until the connection open (IF THIS OBJECT IS NOT DISPOSED)
      //* ----------------------------------------------------------------
      while (_socketChannelConnected == false && _disposed == false) {
        try {
          print("Restoring the connection....");
          await _autoConnect(
            delay: const Duration(seconds: 1),
            forceOpen: true,
          );
        } catch (ex) {
          // Error during connection opening
          debugPrint(ex);
        }
      }
    });
  }

  /// Connection error handler.
  Future _onConnectionError(dynamic error, dynamic stacktrace) async {
    print("Connection error: closing the connection.");
    await _sendLock.synchronized(() {
      _socketChannelConnected = false;
      try {
        if (error is WebSocketChannelException) {
          log(error.message);
        } else {
          log(error.toString());
        }
      } catch (ex) {}
    });
  }

  /// How manage data reception from websocket.
  void _onMessageReceived(dynamic jsonMessage) async {
    if (jsonMessage is String) {
      // Manage message received
      try {
        // Json decoding
        Map<String, dynamic> json = jsonDecode(jsonMessage);
        _FlutnetMessage msg = _FlutnetMessage.fromJson(json);

        // Handlig for event
        if (msg.event != null) {
          _eventsIn.add(_FlutnetEventInfo.fromJson(msg.event));
        }

        // Deserialize the real application message
        //FNetMessage result = FNetSerializer.deserialize(msg.fnetMessage);

        // Insert the response the the map
        await _sendLock.synchronized(() {
          if (_outboxMessages.containsKey(msg.methodInfo.requestId)) {
            _outboxMessages.remove(msg.methodInfo.requestId);
          }

          if (_sendRequestMap.containsKey(msg.methodInfo.requestId)) {
            // Invoke the task completion
            Completer<Map<String, dynamic>> request =
                _sendRequestMap[msg.methodInfo.requestId];

            bool isFailed = msg.errorCode != null && msg.errorCode.isNotEmpty;
            if (msg.exception != null) {
              var exception = PlatformOperationException.fromJsonDynamic(
                msg.exception as Map<String, dynamic>,
              );
              request.completeError(exception);
            } else if (isFailed) {
              //* Handle invoke error
              String errorMessage =
                  "${msg.errorCode}, ${msg.errorMessage ?? ''}";
              request.completeError(Exception(errorMessage));
            } else {
              //* handle invoke complete
              request.complete(msg.result);
            }

            _sendRequestMap.remove(msg.methodInfo.requestId);
          }
        });
      } catch (e) {
        // Error during deserialization
        print(
          "flutter_xamarin_debug: error during _onMessageReceived deserialization.",
        );
      }
    } else {
      // Message not managed: protocol debug error.
    }
  }

  Future<Map<String, dynamic>> invokeMethod({
    @required String instanceId,
    @required String service,
    @required String operation,
    @required Map<String, dynamic> arguments,
  }) {
    final Completer<Map<String, dynamic>> completer =
        new Completer<Map<String, dynamic>>();

    _sendLock.synchronized(
      () async {
        // Check if the app is embedded
        bool isAppEmbedded = await _isAppEmbedded();

        if (isAppEmbedded) {
          var xamarinBridgeMode = await _getXamarinBridgeMode();

          bool isWebSocket = xamarinBridgeMode != null &&
              xamarinBridgeMode == FlutnetBridgeMode.WebSocket;

          if (isWebSocket) {
            // Invalid call
            completer.completeError(Exception(
              "Your Xamarin project is configured in ${FlutnetBridgeMode.WebSocket} mode.\n"
              "You probably want run Flutter project as a STANDALONE application, using your preferred Flutter IDE (like Visual Studio Code).",
            ));
          } else {
            // Invalid call
            completer.completeError(Exception(
              "Flutter is running as an EMBEDDED module inside your Xamarin app, so the FlutnetBrigde configuration must be ${FlutnetBridgeMode.PlatformChannel}.\n"
              "Set 'FlutnetBridgeConfig.mode = ${FlutnetBridgeMode.PlatformChannel}' and recompile both Flutter and Xamarin projects.",
            ));
          }
          return;
        }

        int sendRequestId = ++_uniqueId;

        try {
          final _FlutnetMethodInfo methodInfo = _FlutnetMethodInfo(
              requestId: sendRequestId,
              instance: instanceId,
              service: service,
              operation: operation);

          final _FlutnetMessage debugMessage = _FlutnetMessage(
            methodInfo: methodInfo,
            arguments: arguments,
          );

          // Encode the message
          final String jsonDegubMessage = jsonEncode(debugMessage);

          // Save the request
          _sendRequestMap.putIfAbsent(
            methodInfo.requestId,
            () => completer,
          );
          _outboxMessages.putIfAbsent(
            methodInfo.requestId,
            () => jsonDegubMessage,
          );

          // Wait until the connection open
          while (_socketChannelConnected == false) {
            try {
              await _autoConnect(
                delay: const Duration(seconds: 1),
                forceOpen: true,
              );
            } catch (ex) {
              // Error during connection opening
              debugPrint(ex);
            }
          }

          // Send data using network
          _socketChannel.sink.add(jsonDegubMessage);
        } catch (ex) {
          if (ex is WebSocketChannelException) {}
          debugPrint("Error during invokeMethod on debug channel");
          //
          // Error during send
          //
          //completer.completeError(ex);
        }
      },
    );

    return completer.future;
  }

  @mustCallSuper
  void dispose() {
    _sendLock.synchronized(() {
      _disposed = true;
      _closeConnection();
      _socketChannelConnected = false;
      _releaseMemory();
    });
  }
}

enum _BuildMode {
  release,
  debug,
  profile,
}

_BuildMode buildMode = (() {
  if (const bool.fromEnvironment('dart.vm.product')) {
    return _BuildMode.release;
  }
  var result = _BuildMode.profile;
  assert(() {
    result = _BuildMode.debug;
    return true;
  }());
  return result;
}());
