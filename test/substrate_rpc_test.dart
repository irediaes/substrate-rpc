import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:substrate_rpc/substrate_rpc.dart';

void main() {
  const MethodChannel channel = MethodChannel('substrate_rpc');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });

  test('getPlatformVersion', () async {});
}
