#import "SubstrateRpcPlugin.h"
#if __has_include(<substrate_rpc/substrate_rpc-Swift.h>)
#import <substrate_rpc/substrate_rpc-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "substrate_rpc-Swift.h"
#endif

@implementation SubstrateRpcPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftSubstrateRpcPlugin registerWithRegistrar:registrar];
}
@end
