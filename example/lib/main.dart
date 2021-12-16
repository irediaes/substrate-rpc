import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:substrate_rpc/substrate_rpc.dart' as subrpc;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';

  @override
  void initState() {
    super.initState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    final ws = subrpc.WsProvider(
      endpoints: ["wss://fd42-197-210-65-220.ngrok.io"],
    );
    await ws.connect();
    print("CONNECTED: ${ws.isConnected}");
    print("READY: ${ws.isReady}");
    ws.subscribe("type", "method", [], (error, result) {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: ElevatedButton(
            child: const Text("Connect"),
            onPressed: () {
              initPlatformState();
            },
          ),
        ),
      ),
    );
  }
}
