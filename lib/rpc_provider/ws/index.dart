import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:substrate_rpc/rpc_provider/coder/index.dart';
import 'package:substrate_rpc/rpc_provider/defaults.dart';
import 'package:substrate_rpc/rpc_provider/types.dart';
import 'package:substrate_rpc/rpc_provider/ws/errors.dart';
import 'package:substrate_rpc/rpc_provider/ws/event_emitter.dart';

// import 'package:substrate_rpc/utils/utils.dart';

const RETRY_DELAY = 1000;

const ALIASSES = {
  "chain_finalisedHead": 'chain_finalizedHead',
  "chain_subscribeFinalisedHeads": 'chain_subscribeFinalizedHeads',
  "chain_unsubscribeFinalisedHeads": 'chain_unsubscribeFinalizedHeads'
};

class SubscriptionHandler {
  ProviderInterfaceCallback? callback;
  String? type;
}

class WsStateAwaiting {
  String? json;
  ProviderInterfaceCallback? callback;
  String? method;
  List<dynamic>? params;
  SubscriptionHandler? subscription;
}

class WsStateSubscription extends SubscriptionHandler {
  String? method;
  List<dynamic>? params;
}

class WsProvider implements ProviderInterface {
  late RpcCoder _coder;

  late List<String> _endpoints;

  late Map<String, String> _headers;

  late EventEmitter _eventemitter;

  Map<String, WsStateAwaiting> _handlers = {};

  late Future<WsProvider> _isReadyPromise;

  Map<String, JsonRpcResponse> _waitingForId = {};

  int? _autoConnectMs;

  late int _endpointIndex;

  bool _isConnected = false;

  Map<String, WsStateSubscription> _subscriptions = {};

  // ignore: close_sinks
  WebSocket? _websocket;

  /// @param {string[]}  endpoint    The endpoint url. Usually `ws://ip:9944` or `wss://ip:9944`, may provide an array of endpoint strings.
  /// @param {boolean} autoConnect Whether to connect automatically or not.
  WsProvider(
      {required List<String> endpoints,
      dynamic autoConnectMs = RETRY_DELAY,
      Map<String, String>? headers}) {
    headers ??= <String, String>{};

    if (endpoints.isEmpty) {
      endpoints = [WS_URL];
    }

    assert(endpoints.isNotEmpty, 'WsProvider requires at least one Endpoint');

    for (var endpoint in endpoints) {
      assert((endpoint).startsWith("ws://") || (endpoint).startsWith("wss://"),
          "Endpoint should start with 'ws://', received '$endpoint'");
    }

    _eventemitter = new EventEmitter();
    _autoConnectMs = autoConnectMs is bool ? 0 : autoConnectMs ?? 0;
    _coder = new RpcCoder();
    _endpointIndex = -1;
    _endpoints = endpoints;
    _headers = headers;
    _websocket;

    if (autoConnectMs is int && autoConnectMs > 0) {
      connectWithRetry();
    }

    var _c = new Completer<WsProvider>();
    _eventemitter.once(ProviderInterfaceEmitted.connected.name, (_) {
      _c.complete(this);
    });

    _isReadyPromise = _c.future;
  }

  /// @summary `true` when this provider supports subscriptions
  @override
  bool get hasSubscriptions {
    return true;
  }

  /// @summary Whether the node is connected or not.
  /// @return {boolean} true if connected
  @override
  bool get isConnected {
    return _isConnected;
  }

  /// @description Promise that resolves the first time we are connected and loaded
  Future<WsProvider> get isReady {
    return _isReadyPromise;
  }

  @override
  ProviderInterface clone() {
    // TODO: implement clone
    return WsProvider(endpoints: _endpoints);
  }

  @override
  Future<void> connect() async {
    // TODO: implement connect
    try {
      _endpointIndex = (_endpointIndex + 1) % _endpoints.length;

      _websocket = await WebSocket.connect(_endpoints[_endpointIndex],
          headers: _headers,
          compression: CompressionOptions(
              clientMaxWindowBits: 256 * 1024, enabled: true));

      if (_websocket!.readyState == WebSocket.open) {
        var opened = _onSocketOpen();

        if (opened) {
          _websocket!.listen(
              // listen on message
              _onSocketMessage,
              // listen on close
              onDone: _onSocketClose,
              // listen on error
              onError: _onSocketError
              // nother futher
              );
        }
      }

      // print(this._websocket.connected);
      // this._websocket = typeof global.WebSocket !== 'undefined' && isChildClass(global.WebSocket, WebSocket)
      //   ? new WebSocket(this._endpoints[this._endpointIndex])
      //   // eslint-disable-next-line @typescript-eslint/ban-ts-comment
      //   // @ts-ignore - WS may be an instance of w3cwebsocket, which supports headers
      //   : new WebSocket(this._endpoints[this._endpointIndex], undefined, undefined, this._headers, undefined, {
      //     // default: true
      //     fragmentOutgoingMessages: true,
      //     // default: 16K
      //     fragmentationThreshold: 256 * 1024
      //   });

      // this._websocket.onclose = this._onSocketClose;
      // this._websocket.onerror = this._onSocketError;
      // this._websocket.onmessage = this._onSocketMessage;
      // this._websocket.onopen = this._onSocketOpen;
    } catch (error) {
      print(error);
      _emit(ProviderInterfaceEmitted.error, error);
      throw error;
    }
  }

  /// @description Connect, never throwing an error, but rather forcing a retry
  void connectWithRetry() async {
    try {
      await connect();
    } catch (error) {
      Future.delayed(Duration(milliseconds: _autoConnectMs ?? RETRY_DELAY),
          () => connectWithRetry());
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      assert((_websocket != null),
          'Cannot disconnect on a non-connected websocket');

      // switch off autoConnect, we are in manual mode now
      _autoConnectMs = 0;

      // 1000 - Normal closure; the connection successfully completed
      await _websocket!.close(1000);

      _websocket = null;
    } catch (error) {
      _emit(ProviderInterfaceEmitted.error, error);
      throw error;
    }
  }

  /// @summary Listens on events after having subscribed using the [[subscribe]] function.
  /// @param  {ProviderInterfaceEmitted} type Event
  /// @param  {ProviderInterfaceEmitCb}  sub  Callback
  /// @return unsubscribe function
  @override
  void Function() on(
      ProviderInterfaceEmitted type, ProviderInterfaceEmitCb sub) {
    _eventemitter.on(type.name, sub);

    return () {
      _eventemitter.off(type.name, sub);
    };
  }

  /// @summary Send JSON data using WebSockets to configured HTTP Endpoint or queue.
  /// @param method The RPC methods to execute
  /// @param params Encoded parameters as applicable for the method
  /// @param subscription Subscription details (internally used)
  @override
  Future send(String method, List params, [SubscriptionHandler? subscription]) {
    /// use Completer to simulate Promise((resolve,reject));
    Completer c = new Completer();
    try {
      assert(isConnected && _websocket != null, 'WebSocket is not connected');
      final json = _coder.encodeJson(method, params);
      final id = _coder.getId();
      final callback = ([dynamic error, dynamic result]) {
        if (error != null) {
          c.completeError(error);
        } else {
          c.complete(result);
        }
      };

      _handlers[(id.toString())] = WsStateAwaiting()
        ..json = json
        ..callback = callback
        ..method = method
        ..params = params
        ..subscription = subscription;

      _websocket!.add(json);
    } catch (e) {
      c.completeError(e);
    }
    return c.future;
  }

  @override
  Future subscribe(String? type, String? method, List params,
      ProviderInterfaceCallback cb) async {
    final id = await send(
        method!,
        params,
        SubscriptionHandler()
          ..callback = cb
          ..type = type);

    return id;
  }

  @override
  Future<bool> unsubscribe(String type, String method, id) async {
    final subscription = "$type::$id";

    // // FIXME This now could happen with re-subscriptions. The issue is that with a re-sub
    // // the assigned id now does not match what the API user originally received. It has
    // // a slight complication in solving - since we cannot rely on the send id, but rather
    // // need to find the actual subscription id to map it
    if ((_subscriptions[subscription] == null)) {
      print("Unable to find active subscription=$subscription");

      return false;
    }

    // delete this._subscriptions[subscription];
    _subscriptions.remove(subscription);
    final result = await send(method, [id]);
    return result;
  }

  _emit(ProviderInterfaceEmitted type, [dynamic args]) {
    _eventemitter.emit(type.name, args);
  }

  _onSocketClose() {
    if (_autoConnectMs! > 0) {
      final code = _websocket!.closeCode;
      final reason = _websocket!.closeReason;
      print(
          "disconnected from ${_endpoints[_endpointIndex]}: $code::${reason ?? getWSErrorString(code!)}");
    }

    _isConnected = false;
    _emit(ProviderInterfaceEmitted.disconnected);

    if (_autoConnectMs! > 0) {
      Future.delayed(
          Duration(milliseconds: _autoConnectMs!), () => connectWithRetry());
    }
  }

  _onSocketError(dynamic error) {
    // l.debug(() => ['socket error', error]);
    // this._emit('error', error);
    _emit(ProviderInterfaceEmitted.error, error);
  }

  _onSocketMessage(dynamic message) {
    // l.debug(() => ['received', message.data]);
    JsonRpcResponse? response;
    if (message is String) {
      response = JsonRpcResponse.fromMap(
          Map<String, dynamic>.from(jsonDecode(message)));
    }

    return response?.method == null
        ? _onSocketMessageResult(response!)
        : _onSocketMessageSubscribe(response!);
  }

  _onSocketMessageResult(JsonRpcResponse response) {
    final handler = _handlers[(response.id).toString()];

    if (handler == null) {
      print("Unable to find handler for id=${response.id}");
      return;
    }

    try {
      final method = handler.method;
      final params = handler.params;
      final subscription = handler.subscription;
      final result = _coder.decodeResponse(response);

      // first send the result - in case of subs, we may have an update
      // immediately if we have some queued results already
      handler.callback!(null, result);

      if (subscription != null) {
        final subId = "${subscription.type}::$result";

        _subscriptions[subId] = WsStateSubscription()
          ..method = method
          ..params = params
          ..callback = subscription.callback
          ..type = subscription.type;

        // if we have a result waiting for this subscription already
        if (_waitingForId[subId] != null) {
          _onSocketMessageSubscribe(_waitingForId[subId]);
        }
      }
    } catch (error) {
      handler.callback!(error, null);
    }
    _handlers.remove((response.id).toString());
  }

  _onSocketMessageSubscribe(JsonRpcResponse? response) {
    var method = ALIASSES[response!.method] ?? response.method;
    if (method.isEmpty) {
      method = 'invalid';
    }
    final subId = "$method::${response.params["subscription"]}";
    final handler = _subscriptions[subId];

    if (handler == null) {
      // store the JSON, we could have out-of-order subid coming in
      _waitingForId[subId] = response;
      // l.debug(() => `Unable to find handler for subscription=${subId}`);

      return;
    }

    // // housekeeping
    _waitingForId.remove(subId);

    try {
      final result = _coder.decodeResponse(response);

      handler.callback!(null, result);
    } catch (error) {
      handler.callback!(error, null);
    }
  }

  bool _onSocketOpen() {
    assert(_websocket != null, 'WebSocket cannot be null in onOpen');

    // l.debug(() => ['connected to', this._endpoints[this._endpointIndex]]);

    _isConnected = true;

    _emit(ProviderInterfaceEmitted.connected);

    _resubscribe();
    return true;
  }

  void _resubscribe() {
    final subscriptions = _subscriptions;

    _subscriptions = {};

    Future.wait(subscriptions.keys.map((id) async {
      final sub = subscriptions[id];
      final callback = sub!.callback;
      final method = sub.method;
      final params = sub.params;
      final type = sub.type;

      if (type!.startsWith('author_')) {
        return;
      }
      try {
        await subscribe(type, method, params!, callback!);
      } catch (error) {
        print(error);
      }
    })).catchError((err) {
      print(err);
    });
  }
}
