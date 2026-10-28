#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <dlfcn.h>
@interface HotspotSession : NSObject
- (void)setDelegate:(id)delegate;
- (void)startBrowsing;
- (void)stopBrowsing;
- (void)enableHotspotForDevice:(id)device withCompletionHandler:(void (^)(id,id))handler;
@end
@interface SharingProbe : NSObject
@property BOOL sawDevice;
@property NSString *target;
@property BOOL attempted;
@property BOOL finished;
@property int result;
@end
@implementation SharingProbe
- (void)session:(id)session updatedFoundDevices:(id)devices {
    if (![devices conformsToProtocol:@protocol(NSFastEnumeration)]) return;
    NSMutableArray *matches = [NSMutableArray array];
    for (id device in devices) {
        if (![device respondsToSelector:NSSelectorFromString(@"deviceName")]) continue;
        NSString *name = [device valueForKey:@"deviceName"];
        if ([name isKindOfClass:NSString.class]) {
            self.sawDevice = YES; printf("FOUND: %s\n",name.UTF8String);
            if(self.target && [name isEqualToString:self.target]) [matches addObject:device];
        }
    }
    if (!self.target || self.attempted || !matches.count) return;
    self.attempted = YES;
    if(matches.count != 1 || ![session respondsToSelector:@selector(enableHotspotForDevice:withCompletionHandler:)]) {
        puts("Ambiguous name or unavailable enable API."); self.result=3; self.finished=YES; return;
    }
    puts("Requesting iPhone hotspot activation...");
    [(HotspotSession *)session enableHotspotForDevice:matches.firstObject withCompletionHandler:^(id first,id second) {
        // Private callback observed in existing implementations: SSID, password.
        // Validate types; never log either callback object (it may hold credentials).
        if(![first isKindOfClass:NSString.class] || ![first length] ||
           (second && ![second isKindOfClass:NSString.class])) {
            dispatch_async(dispatch_get_main_queue(), ^{ puts("Activation failed or unexpected callback format (credentials redacted)."); self.result=4; self.finished=YES; }); return;
        }
        NSString *ssid = first;
        puts("Hotspot credentials received; stopping discovery and allowing hotspot to become ready...");
        [(HotspotSession *)session stopBrowsing];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            CWInterface *iface = [CWWiFiClient sharedWiFiClient].interface;
            // At most one join request. Command output is not connection state.
            BOOL joined = [iface.ssid isEqualToString:ssid];
            if(!joined && iface.interfaceName.length) {
                puts("Sending ONE system join request; no scan/reconnect fallback...");
                NSTask *task=[NSTask new];
                task.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/networksetup"];
                task.arguments=@[@"-setairportnetwork",iface.interfaceName,ssid];
                task.standardOutput=[NSFileHandle fileHandleWithNullDevice];
                task.standardError=[NSFileHandle fileHandleWithNullDevice];
                NSError *error=nil;
                if([task launchAndReturnError:&error]) {
                    [task waitUntilExit];
                    printf("Join command exited %d; observing state only...\n",task.terminationStatus);
                } else { puts("System join could not start."); }
            }
            for(int attempt=0; attempt<15 && !joined; attempt++) {
                joined = [iface.ssid isEqualToString:ssid];
                if(!joined) [NSThread sleepForTimeInterval:1];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                puts(joined ? "CONNECTED: target SSID confirmed. No further connection requests." : "UNCONFIRMED: macOS may hide SSID. Check Wi-Fi manually; no reconnect will be attempted.");
                self.result=joined ? 0 : 6; self.finished=YES;
            });
        });
    }];
}
@end

// Private API observed on macOS 15.7.7; may change in other versions.
@interface CWWiFiClient (HotspotPrivate)
- (BOOL)startBrowsingForTetherDevicesAndReturnError:(NSError **)error;
- (BOOL)stopBrowsingForTetherDevicesAndReturnError:(NSError **)error;
@end
@interface CWInterface (HotspotPrivate)
- (BOOL)connectToTetherDevice:(id)device remember:(BOOL)remember error:(NSError **)error;
@end
@interface NSObject (TetherName)
- (NSString *)deviceName;
@end
@interface Probe : NSObject <CWEventDelegate>
@property CWWiFiClient *client;
@property NSString *target;
@property BOOL attempted;
@property BOOL sawDevice;
@end
@implementation Probe
- (void)foundTetherDevices:(id)devices {
    if (![devices conformsToProtocol:@protocol(NSFastEnumeration)]) {
        fprintf(stderr,"Unexpected callback payload\n"); return;
    }
    NSMutableArray *matches = [NSMutableArray array];
    for (id device in devices) {
        if (![device respondsToSelector:@selector(deviceName)]) continue;
        NSString *name = [device deviceName];
        if (!name) continue;
        self.sawDevice = YES;
        printf("FOUND: %s\n", name.UTF8String);
        if (self.target && [name isEqualToString:self.target]) [matches addObject:device];
    }
    if (matches.count > 1) { fprintf(stderr,"Ambiguous device name; refusing to connect\n"); exit(5); }
    if (matches.count != 1 || self.attempted) return;
    self.attempted = YES;
    id device = matches.firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        CWInterface *iface = self.client.interface;
        if (![iface respondsToSelector:@selector(connectToTetherDevice:remember:error:)]) {
            fprintf(stderr,"Connection API unavailable\n"); exit(3);
        }
        NSError *error = nil;
        BOOL ok = [iface connectToTetherDevice:device remember:NO error:&error];
        printf("CONNECT: %s\n",ok ? "accepted/succeeded; verify Internet separately" : "failed");
        if(error) fprintf(stderr,"%s\n",error.description.UTF8String);
        [self.client stopBrowsingForTetherDevicesAndReturnError:NULL];
        exit(ok ? 0 : 4);
    });
}
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    setbuf(stdout,NULL);
    BOOL sharingConnect = argc == 3 && !strcmp(argv[1],"connect-sharing") && strlen(argv[2]);
    if(sharingConnect && [[[CWWiFiClient sharedWiFiClient].interface ssid] isEqualToString:[NSString stringWithUTF8String:argv[2]]]) {
        puts("Already connected to target SSID; no activation or join requested."); return 0;
    }
    if((argc == 2 && !strcmp(argv[1],"scan-sharing")) || sharingConnect) {
        if(!dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing",RTLD_LAZY)) return 3;
        HotspotSession *session = [NSClassFromString(@"SFRemoteHotspotSession") new];
        if(![session respondsToSelector:@selector(startBrowsing)] || ![session respondsToSelector:@selector(stopBrowsing)]) return 3;
        SharingProbe *observer = [SharingProbe new];
        observer.result=6;
        if(sharingConnect) observer.target=[NSString stringWithUTF8String:argv[2]];
        [session setDelegate:observer]; [session startBrowsing];
        puts(sharingConnect ? "Discovering target; connection may switch current Wi-Fi (60-second timeout)..." : "Sharing discovery started (20 seconds, no connection)...");
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:sharingConnect ? 60 : 20];
        while(end.timeIntervalSinceNow > 0 && !observer.finished) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        [session stopBrowsing];
        if(sharingConnect) { if(!observer.finished) puts("Connection timed out; not confirmed."); return observer.result; }
        puts(observer.sawDevice ? "Discovery succeeded. Connection not tested." : "No devices received; result inconclusive.");
        return observer.sawDevice ? 0 : 6;
    }
    BOOL scan = argc == 2 && !strcmp(argv[1],"scan");
    BOOL connect = argc == 3 && !strcmp(argv[1],"connect") && strlen(argv[2]);
    if (!scan && !connect) {
        puts("Usage: hotspot-probe scan-sharing (recommended)\n       hotspot-probe connect-sharing 'exact iPhone name'\n       hotspot-probe scan (legacy CoreWLAN probe)\n       hotspot-probe connect 'exact iPhone name'\nscan: 20 seconds, no connection. connect: may switch current Wi-Fi; 60-second timeout.");
        return argc == 2 && !strcmp(argv[1],"--help") ? 0 : 2;
    }
    Probe *probe = [Probe new];
    probe.client = [CWWiFiClient sharedWiFiClient];
    probe.client.delegate = probe;
    if(connect) probe.target = [NSString stringWithUTF8String:argv[2]];
    if (![probe.client respondsToSelector:@selector(startBrowsingForTetherDevicesAndReturnError:)]) {
        fprintf(stderr,"Discovery API unavailable\n"); return 3;
    }
    NSError *error = nil;
    if (![probe.client startBrowsingForTetherDevicesAndReturnError:&error]) {
        fprintf(stderr,"Discovery rejected: %s\n",error.description.UTF8String ?: "unknown error"); return 3;
    }
    puts("Discovery started; waiting for system callbacks...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(connect ? 60 : 20)*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [probe.client stopBrowsingForTetherDevicesAndReturnError:NULL];
        puts(probe.sawDevice ? "Discovery finished." : "No device callback. This does NOT prove no iPhone is nearby; permissions or callback routing may block this private API.");
        exit(connect ? 6 : (probe.sawDevice ? 0 : 6));
    });
    [[NSRunLoop currentRunLoop] run];
} return 0; }
