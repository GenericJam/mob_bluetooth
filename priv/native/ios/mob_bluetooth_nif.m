/* mob_bluetooth_nif — iOS BLE (CoreBluetooth) tier-1 plugin NIF (Objective-C).
 *
 * iOS does NOT expose Bluetooth Classic (the bt_* surface — discovery, pairing,
 * HFP/SPP — is Android-only; see lib/mob_bluetooth/platform.ex). What iOS *does*
 * offer is BLE via CoreBluetooth, a separate, parallel surface. This NIF
 * implements the iOS-only `ble_*` functions:
 *
 *   ble_scan/0           — CBCentralManager scan for nearby BLE peripherals
 *   ble_stop_scan/0      — stop the scan
 *   ble_advertise/1      — CBPeripheralManager advertise a local name (the
 *                          BLE analog of Android's make_discoverable)
 *   ble_stop_advertise/0 — stop advertising
 *
 * Messages match the existing `:bt` device-event family (2-tuples for plain
 * events, 3-tuples when there's a payload — same as the Android discovery
 * deliveries):
 *
 *   {:bt, :ble_scan_started}
 *   {:bt, :ble_device, %{id: <uuid>, name: <name|nil>, rssi: <int>}}
 *   {:bt, :ble_scan_stopped}
 *   {:bt, :ble_advertising}
 *   {:bt, :ble_advertise_stopped}
 *   {:bt, :error, %{reason: <atom>}}   (powered_off / unauthorized /
 *                                       unsupported / resetting / ...)
 *
 * Self-contained (core's send helpers are private statics). Compiled as ObjC
 * (-fobjc-arc) via the plugin objc-NIF path (manifest lang: :objc, platform:
 * :ios). The NIF is statically linked into the host binary on device.
 *
 * NOTE: CoreBluetooth needs a real radio — the iOS Simulator reports
 * CBManagerStateUnsupported, so this is only meaningfully exercised on a
 * physical device.
 */
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <erl_nif.h>
#include <string.h>

// ── BEAM delivery helpers ─────────────────────────────────────────────────
// Each message is built in its own freshly-allocated env and sent with a NULL
// caller env (thread-safe from the CoreBluetooth dispatch queue).

// {:bt, <tag>} — a plain 2-tuple device event.
static void ble_send_simple(const ErlNifPid *pid, const char *tag) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, "bt"), enif_make_atom(e, tag));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// {:bt, :error, %{reason: <atom>}}
static void ble_send_error(const ErlNifPid *pid, const char *reason) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "reason"), enif_make_atom(e, reason), &map);
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "bt"), enif_make_atom(e, "error"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static ERL_NIF_TERM ble_nsstr_binary(ErlNifEnv *e, NSString *s) {
  const char *u = [s UTF8String];
  size_t len = u ? strlen(u) : 0;
  ERL_NIF_TERM bin;
  unsigned char *buf = enif_make_new_binary(e, len, &bin);
  if (len) memcpy(buf, u, len);
  return bin;
}

static void ble_send_device(const ErlNifPid *pid, NSString *uuid, NSString *name, int rssi) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "id"), ble_nsstr_binary(e, uuid ?: @""), &map);
  ERL_NIF_TERM name_term =
      name ? ble_nsstr_binary(e, name) : enif_make_atom(e, "nil");
  enif_make_map_put(e, map, enif_make_atom(e, "name"), name_term, &map);
  enif_make_map_put(e, map, enif_make_atom(e, "rssi"), enif_make_int(e, rssi), &map);
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "bt"), enif_make_atom(e, "ble_device"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static const char *ble_state_reason(CBManagerState s) {
  switch (s) {
    case CBManagerStatePoweredOff:
      return "powered_off";
    case CBManagerStateUnauthorized:
      return "unauthorized";
    case CBManagerStateUnsupported:
      return "unsupported";
    case CBManagerStateResetting:
      return "resetting";
    default:
      return "unavailable";
  }
}

// ── CoreBluetooth delegate + state ────────────────────────────────────────

@interface MobBle : NSObject <CBCentralManagerDelegate, CBPeripheralManagerDelegate>
@property(nonatomic, strong) dispatch_queue_t q;
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) CBPeripheralManager *peripheral;
@property(nonatomic, assign) BOOL wantScan;
@property(nonatomic, assign) BOOL wantAdvertise;
@property(nonatomic, copy) NSString *advName;
@property(nonatomic, assign) ErlNifPid scanPid;
@property(nonatomic, assign) BOOL haveScanPid;
@property(nonatomic, assign) ErlNifPid advPid;
@property(nonatomic, assign) BOOL haveAdvPid;
- (void)startScanIfReady;
- (void)startAdvertiseIfReady;
@end

// Globally retained so the delegate (held weakly by the CB managers) outlives
// every NIF call. Created once on first use.
static MobBle *g_ble = nil;

static MobBle *ble_get(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_ble = [MobBle new];
    g_ble.q = dispatch_queue_create("ca.mob.ble", DISPATCH_QUEUE_SERIAL);
  });
  return g_ble;
}

@implementation MobBle

- (void)startScanIfReady {
  if (self.wantScan && self.central.state == CBManagerStatePoweredOn) {
    [self.central scanForPeripheralsWithServices:nil options:nil];
    if (self.haveScanPid) ble_send_simple(&self->_scanPid, "ble_scan_started");
  }
}

- (void)startAdvertiseIfReady {
  if (self.wantAdvertise && self.peripheral.state == CBManagerStatePoweredOn) {
    NSDictionary *data =
        self.advName ? @{CBAdvertisementDataLocalNameKey : self.advName} : @{};
    [self.peripheral startAdvertising:data];
  }
}

// ── Central (scan) ──
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (central.state == CBManagerStatePoweredOn) {
    [self startScanIfReady];
  } else if (self.wantScan && self.haveScanPid) {
    ble_send_error(&self->_scanPid, ble_state_reason(central.state));
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  if (!self.haveScanPid) return;
  NSString *name = peripheral.name;
  if (!name) name = advertisementData[CBAdvertisementDataLocalNameKey];
  ble_send_device(&self->_scanPid, peripheral.identifier.UUIDString, name,
                  RSSI ? RSSI.intValue : 0);
}

// ── Peripheral (advertise) ──
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
  if (peripheral.state == CBManagerStatePoweredOn) {
    [self startAdvertiseIfReady];
  } else if (self.wantAdvertise && self.haveAdvPid) {
    ble_send_error(&self->_advPid, ble_state_reason(peripheral.state));
  }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral
                                       error:(NSError *)error {
  if (!self.haveAdvPid) return;
  if (error)
    ble_send_error(&self->_advPid, "advertise_failed");
  else
    ble_send_simple(&self->_advPid, "ble_advertising");
}

@end

// ── NIFs ──────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_ble_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.scanPid = pid;
    b.haveScanPid = YES;
    b.wantScan = YES;
    if (!b.central)
      b.central = [[CBCentralManager alloc] initWithDelegate:b queue:b.q];
    [b startScanIfReady];
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_stop_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.wantScan = NO;
    if (b.central && b.central.state == CBManagerStatePoweredOn) [b.central stopScan];
    ble_send_simple(&pid, "ble_scan_stopped");
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_advertise(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &bin))
    return enif_make_badarg(env);
  NSString *name = [[NSString alloc] initWithBytes:bin.data
                                            length:bin.size
                                          encoding:NSUTF8StringEncoding];
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.advPid = pid;
    b.haveAdvPid = YES;
    b.advName = name;
    b.wantAdvertise = YES;
    if (!b.peripheral)
      b.peripheral = [[CBPeripheralManager alloc] initWithDelegate:b queue:b.q options:nil];
    [b startAdvertiseIfReady];
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_stop_advertise(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.wantAdvertise = NO;
    if (b.peripheral) [b.peripheral stopAdvertising];
    ble_send_simple(&pid, "ble_advertise_stopped");
  });
  return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"ble_scan", 0, nif_ble_scan, 0},
    {"ble_stop_scan", 0, nif_ble_stop_scan, 0},
    {"ble_advertise", 1, nif_ble_advertise, 0},
    {"ble_stop_advertise", 0, nif_ble_stop_advertise, 0},
};

ERL_NIF_INIT(mob_bluetooth_nif, nif_funcs, NULL, NULL, NULL, NULL)
