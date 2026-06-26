/* mob_bluetooth_nif — iOS BLE (CoreBluetooth) tier-1 plugin NIF (Objective-C).
 *
 * iOS does NOT expose Bluetooth Classic (the bt_* surface — discovery, pairing,
 * HFP/SPP — is Android-only; see lib/mob_bluetooth/platform.ex). What iOS
 * *does* offer is BLE via CoreBluetooth, a separate, parallel surface. This NIF
 * implements the iOS-only `ble_*` functions:
 *
 *   ble_scan/1           — CBCentralManager scan for nearby BLE peripherals,
 *                          filtered by a list of service-UUID binaries ([] =
 *                          unfiltered; a filter is required for background
 * scan) ble_stop_scan/0      — stop the scan ble_advertise/1      —
 * CBPeripheralManager advertise a local name (the BLE analog of Android's
 * make_discoverable) ble_stop_advertise/0 — stop advertising
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
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#include <erl_nif.h>
#include <string.h>

// ── BEAM delivery helpers ─────────────────────────────────────────────────
// Each message is built in its own freshly-allocated env and sent with a NULL
// caller env (thread-safe from the CoreBluetooth dispatch queue).

// {:bt, <tag>} — a plain 2-tuple device event.
static void ble_send_simple(const ErlNifPid *pid, const char *tag) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg =
      enif_make_tuple2(e, enif_make_atom(e, "bt"), enif_make_atom(e, tag));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// {:bt, :error, %{reason: <atom>}}
static void ble_send_error(const ErlNifPid *pid, const char *reason) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "reason"),
                    enif_make_atom(e, reason), &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "bt"),
                                      enif_make_atom(e, "error"), map);
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static ERL_NIF_TERM ble_nsstr_binary(ErlNifEnv *e, NSString *s) {
  const char *u = [s UTF8String];
  size_t len = u ? strlen(u) : 0;
  ERL_NIF_TERM bin;
  unsigned char *buf = enif_make_new_binary(e, len, &bin);
  if (len)
    memcpy(buf, u, len);
  return bin;
}

static void ble_send_device(const ErlNifPid *pid, NSString *uuid,
                            NSString *name, int rssi) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM map = enif_make_new_map(e);
  enif_make_map_put(e, map, enif_make_atom(e, "id"),
                    ble_nsstr_binary(e, uuid ?: @""), &map);
  ERL_NIF_TERM name_term =
      name ? ble_nsstr_binary(e, name) : enif_make_atom(e, "nil");
  enif_make_map_put(e, map, enif_make_atom(e, "name"), name_term, &map);
  enif_make_map_put(e, map, enif_make_atom(e, "rssi"), enif_make_int(e, rssi),
                    &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "bt"),
                                      enif_make_atom(e, "ble_device"), map);
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

@interface MobBle
    : NSObject <CBCentralManagerDelegate, CBPeripheralManagerDelegate>
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
// CBUUIDs to filter the scan by (nil = scan for everything). iOS REQUIRES an
// explicit service-UUID filter for background scanning — `nil` is silently
// dropped when the app is backgrounded.
@property(nonatomic, strong) NSArray *scanServiceUUIDs;
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
    // self.scanServiceUUIDs is nil for an unfiltered (foreground) scan, or the
    // caller's CBUUID list — required for background scanning.
    [self.central scanForPeripheralsWithServices:self.scanServiceUUIDs
                                         options:nil];
    if (self.haveScanPid)
      ble_send_simple(&self->_scanPid, "ble_scan_started");
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
  if (!self.haveScanPid)
    return;
  NSString *name = peripheral.name;
  if (!name)
    name = advertisementData[CBAdvertisementDataLocalNameKey];
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
  if (!self.haveAdvPid)
    return;
  if (error)
    ble_send_error(&self->_advPid, "advertise_failed");
  else
    ble_send_simple(&self->_advPid, "ble_advertising");
}

@end

// ── NIFs ──────────────────────────────────────────────────────────────────

// ble_scan(ServiceUUIDs) — ServiceUUIDs is a (possibly empty) list of UUID
// binaries. Empty list scans for everything (foreground only); a non-empty
// filter is what makes background scanning work (iOS drops a nil filter when
// backgrounded). Unparseable UUID strings are skipped.
static ERL_NIF_TERM nif_ble_scan(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  (void)argc;
  NSMutableArray *uuids = [NSMutableArray array];
  ERL_NIF_TERM head, tail = argv[0];
  while (enif_get_list_cell(env, tail, &head, &tail)) {
    ErlNifBinary bin;
    if (enif_inspect_binary(env, head, &bin) ||
        enif_inspect_iolist_as_binary(env, head, &bin)) {
      NSString *s = [[NSString alloc] initWithBytes:bin.data
                                             length:bin.size
                                           encoding:NSUTF8StringEncoding];
      @try {
        if (s)
          [uuids addObject:[CBUUID UUIDWithString:s]];
      } @catch (NSException *e) {
        // Skip an invalid UUID string rather than crash the scan.
      }
    }
  }
  NSArray *filter = uuids.count ? [uuids copy] : nil;

  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.scanPid = pid;
    b.haveScanPid = YES;
    b.wantScan = YES;
    b.scanServiceUUIDs = filter;
    if (!b.central)
      b.central = [[CBCentralManager alloc] initWithDelegate:b queue:b.q];
    [b startScanIfReady];
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_stop_scan(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.wantScan = NO;
    if (b.central && b.central.state == CBManagerStatePoweredOn)
      [b.central stopScan];
    ble_send_simple(&pid, "ble_scan_stopped");
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_advertise(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
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
      b.peripheral = [[CBPeripheralManager alloc] initWithDelegate:b
                                                             queue:b.q
                                                           options:nil];
    [b startAdvertiseIfReady];
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_ble_stop_advertise(ErlNifEnv *env, int argc,
                                           const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  MobBle *b = ble_get();
  ErlNifPid pid;
  enif_self(env, &pid);
  dispatch_async(b.q, ^{
    b.wantAdvertise = NO;
    if (b.peripheral)
      [b.peripheral stopAdvertising];
    ble_send_simple(&pid, "ble_advertise_stopped");
  });
  return enif_make_atom(env, "ok");
}

// ═══════════════════════════════════════════════════════════════════════════
// BLE GATT peripheral surface (MobBluetooth.Le) — advertise a service, notify
// subscribed centrals, receive writes. Independent of the MobBle scan/advertise
// subsystem above: its own CBPeripheralManager (g_peripheral) + delegate.
// ═══════════════════════════════════════════════════════════════════════════

// ── Globals (ARC: strong refs keep these alive across NIF calls) ──────────

static CBPeripheralManager *g_peripheral = nil;

// Caller pid captured at ble_start_advertising. Last caller wins (single
// consumer — the screen GenServer that owns the peripheral).
static ErlNifPid g_ble_pid;
static BOOL g_have_pid = NO;

// The parsed service + advertise data, stashed at ble_start_advertising and
// applied once CBPeripheralManager reports CBManagerStatePoweredOn (the manager
// is async: you cannot addService / startAdvertising before then).
static CBMutableService *g_pending_service = nil;
static NSString *g_local_name = nil;
static BOOL g_want_advertise = NO;

// CBUUID(string) → CBMutableCharacteristic, for ble_notify lookup by UUID.
static NSMutableDictionary<CBUUID *, CBMutableCharacteristic *> *g_chars = nil;

// CoreBluetooth's peripheral role exposes NO raw central connect/disconnect
// callback — only subscribe/unsubscribe to a characteristic. We approximate
// connection lifecycle by assigning an incrementing int per distinct
// CBCentral.identifier on first subscribe (central_connected) and reclaiming it
// on last unsubscribe (central_disconnected). This is a per-platform
// APPROXIMATION: on Android these events come from real GATT connection-state
// changes, here they're inferred from subscription. A central that connects but
// never subscribes is invisible to us, and one subscribed to two
// characteristics counts as connected once.
static NSMutableDictionary<NSUUID *, NSNumber *> *g_centrals =
    nil; // identifier → int handle
static int g_next_central = 1;

// The delegate object (held strong so CBPeripheralManager's weak delegate
// pointer stays valid).
static id g_delegate = nil;

// Outbound notification queue. updateValue:onSubscribedCentrals: returns NO
// when CoreBluetooth's transmit queue is full (common with back-to-back
// note-on/off); the value is then dropped unless we retry. We enqueue every
// notification and drain the queue, stopping on the first NO and resuming in
// peripheralManagerIsReadyToUpdateSubscribers: — the standard CoreBluetooth
// pattern, so note-offs don't get lost (which would leave stuck notes). Each
// entry is @{@"ch": CBMutableCharacteristic, @"data": NSData}. Capped so a
// burst with no subscriber can't grow without bound. All access is on the main
// queue.
static NSMutableArray<NSDictionary *> *g_tx_queue = nil;
static const NSUInteger MOB_BLE_TX_CAP = 256;
static void ble_flush_tx(void);

// ── Delivery helpers ──────────────────────────────────────────────────────
//
// Each builds a {:bt_le, tag[, payload]} tuple in a fresh env and posts it to
// g_ble_pid. Map payloads are built with enif_make_map_from_arrays to match the
// zig side's erts.makeMap.

static void ble_send_atom2(const char *tag) {
  if (!g_have_pid)
    return;
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg =
      enif_make_tuple2(e, enif_make_atom(e, "bt_le"), enif_make_atom(e, tag));
  enif_send(NULL, &g_ble_pid, e, msg);
  enif_free_env(e);
}

// {:bt_le, :advertising_failed, %{reason: <atom>}}
static void ble_send_failed(const char *reason) {
  if (!g_have_pid)
    return;
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM key = enif_make_atom(e, "reason");
  ERL_NIF_TERM val = enif_make_atom(e, reason);
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, &key, &val, 1, &map);
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "bt_le"),
                       enif_make_atom(e, "advertising_failed"), map);
  enif_send(NULL, &g_ble_pid, e, msg);
  enif_free_env(e);
}

// {:bt_le, <tag>, %{central: <int>}} — connected / disconnected.
static void ble_send_central(const char *tag, int central) {
  if (!g_have_pid)
    return;
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM key = enif_make_atom(e, "central");
  ERL_NIF_TERM val = enif_make_int(e, central);
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, &key, &val, 1, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "bt_le"),
                                      enif_make_atom(e, tag), map);
  enif_send(NULL, &g_ble_pid, e, msg);
  enif_free_env(e);
}

// {:bt_le, <tag>, %{characteristic: <<uuid>>}} — subscribed / unsubscribed.
// The characteristic value is a UTF-8 BINARY of the UUID string (matches the
// zig mobBleMakeCharMap, which builds a binary from the UUID C string).
static void ble_send_char(const char *tag, NSString *uuid) {
  if (!g_have_pid)
    return;
  const char *s = uuid.UTF8String;
  size_t len = strlen(s);
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM ubin;
  unsigned char *ubuf = enif_make_new_binary(e, len, &ubin);
  memcpy(ubuf, s, len);
  ERL_NIF_TERM key = enif_make_atom(e, "characteristic");
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, &key, &ubin, 1, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "bt_le"),
                                      enif_make_atom(e, tag), map);
  enif_send(NULL, &g_ble_pid, e, msg);
  enif_free_env(e);
}

// {:bt_le, :write, %{characteristic: <<uuid>>, bytes: <<raw>>}}.
static void ble_send_write(NSString *uuid, const uint8_t *bytes, size_t len) {
  if (!g_have_pid)
    return;
  const char *s = uuid.UTF8String;
  size_t ulen = strlen(s);
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM ubin;
  unsigned char *ubuf = enif_make_new_binary(e, ulen, &ubin);
  memcpy(ubuf, s, ulen);
  ERL_NIF_TERM bbin;
  unsigned char *bbuf = enif_make_new_binary(e, len, &bbin);
  if (len && bytes)
    memcpy(bbuf, bytes, len);
  ERL_NIF_TERM keys[2] = {enif_make_atom(e, "characteristic"),
                          enif_make_atom(e, "bytes")};
  ERL_NIF_TERM vals[2] = {ubin, bbin};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(e, keys, vals, 2, &map);
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "bt_le"),
                                      enif_make_atom(e, "write"), map);
  enif_send(NULL, &g_ble_pid, e, msg);
  enif_free_env(e);
}

// ── central-handle bookkeeping (approximation, see g_centrals note) ────────

// Assign/return the int handle for a central; emit central_connected the first
// time we see it.
static int ble_central_handle(CBCentral *central) {
  if (!g_centrals)
    g_centrals = [NSMutableDictionary dictionary];
  NSUUID *key = central.identifier;
  NSNumber *existing = g_centrals[key];
  if (existing)
    return existing.intValue;
  int handle = g_next_central++;
  g_centrals[key] = @(handle);
  ble_send_central("central_connected", handle);
  return handle;
}

// Reclaim a central's handle on unsubscribe; emit central_disconnected.
static void ble_central_drop(CBCentral *central) {
  if (!g_centrals)
    return;
  NSUUID *key = central.identifier;
  NSNumber *existing = g_centrals[key];
  if (!existing)
    return;
  [g_centrals removeObjectForKey:key];
  ble_send_central("central_disconnected", existing.intValue);
}

// ── CBPeripheralManagerDelegate ────────────────────────────────────────────

@interface MobBlePeripheralDelegate : NSObject <CBPeripheralManagerDelegate>
@end

@implementation MobBlePeripheralDelegate

// State transitions. We can only add the service + start advertising once the
// manager is PoweredOn; any earlier intent is held in g_pending_service /
// g_want_advertise and applied here. Non-PoweredOn terminal states map to an
// advertising_failed reason atom.
- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
  switch (peripheral.state) {
  case CBManagerStatePoweredOn:
    if (g_want_advertise && g_pending_service) {
      // addService is async; advertising is kicked off in the
      // didAddService callback so the service is registered first.
      [peripheral addService:g_pending_service];
    }
    break;
  case CBManagerStatePoweredOff:
    ble_send_failed("powered_off");
    break;
  case CBManagerStateUnauthorized:
    ble_send_failed("unauthorized");
    break;
  case CBManagerStateUnsupported:
    ble_send_failed("unsupported");
    break;
  case CBManagerStateResetting:
  case CBManagerStateUnknown:
  default:
    // Transient — wait for the next state update.
    break;
  }
}

// Service registered (or failed). On success, start advertising the service
// UUID + local name; on failure report add_service_failed.
- (void)peripheralManager:(CBPeripheralManager *)peripheral
            didAddService:(CBService *)service
                    error:(NSError *)error {
  if (error) {
    ble_send_failed("add_service_failed");
    return;
  }
  NSMutableDictionary *adv = [NSMutableDictionary dictionary];
  adv[CBAdvertisementDataServiceUUIDsKey] = @[ service.UUID ];
  if (g_local_name)
    adv[CBAdvertisementDataLocalNameKey] = g_local_name;
  [peripheral startAdvertising:adv];
}

// startAdvertising result → advertising_started / advertising_failed.
- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral
                                       error:(NSError *)error {
  if (error) {
    ble_send_failed("advertise_failed");
  } else {
    ble_send_atom2("advertising_started");
  }
}

// A central subscribed to one of our characteristics. Emit central_connected
// (first time we see this central) then subscribed.
- (void)peripheralManager:(CBPeripheralManager *)peripheral
                         central:(CBCentral *)central
    didSubscribeToCharacteristic:(CBCharacteristic *)characteristic {
  ble_central_handle(central);
  ble_send_char("subscribed", characteristic.UUID.UUIDString);
}

// A central unsubscribed. Emit unsubscribed then central_disconnected (we treat
// an unsubscribe as the central leaving — see g_centrals approximation note).
- (void)peripheralManager:(CBPeripheralManager *)peripheral
                             central:(CBCentral *)central
    didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic {
  ble_send_char("unsubscribed", characteristic.UUID.UUIDString);
  ble_central_drop(central);
}

// Incoming writes. CoreBluetooth batches multiple ATT write requests and
// requires EXACTLY ONE respondToRequest: per batch (responding to the first
// request acknowledges the whole batch). BLE-MIDI uses write-without-response,
// so request.value may be nil/empty — handle that safely.
- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
  for (CBATTRequest *req in requests) {
    NSData *data = req.value;
    const uint8_t *bytes = data ? (const uint8_t *)data.bytes : NULL;
    size_t len = data ? (size_t)data.length : 0;
    ble_send_write(req.characteristic.UUID.UUIDString, bytes, len);
  }
  if (requests.count > 0) {
    [peripheral respondToRequest:requests[0] withResult:CBATTErrorSuccess];
  }
}

// CoreBluetooth's transmit queue has space again — drain any notifications that
// got a NO from updateValue: (e.g. a note-off right after its note-on).
- (void)peripheralManagerIsReadyToUpdateSubscribers:
    (CBPeripheralManager *)peripheral {
  ble_flush_tx();
}

@end

// ── JSON → CoreBluetooth mapping ───────────────────────────────────────────

static CBCharacteristicProperties ble_props_from_array(NSArray *props) {
  CBCharacteristicProperties out = 0;
  for (id p in props) {
    if (![p isKindOfClass:[NSString class]])
      continue;
    NSString *s = (NSString *)p;
    if ([s isEqualToString:@"read"])
      out |= CBCharacteristicPropertyRead;
    else if ([s isEqualToString:@"write"])
      out |= CBCharacteristicPropertyWrite;
    else if ([s isEqualToString:@"write_without_response"])
      out |= CBCharacteristicPropertyWriteWithoutResponse;
    else if ([s isEqualToString:@"notify"])
      out |= CBCharacteristicPropertyNotify;
    else if ([s isEqualToString:@"indicate"])
      out |= CBCharacteristicPropertyIndicate;
  }
  return out;
}

static CBAttributePermissions ble_perms_from_array(NSArray *props) {
  CBAttributePermissions out = 0;
  for (id p in props) {
    if (![p isKindOfClass:[NSString class]])
      continue;
    NSString *s = (NSString *)p;
    if ([s isEqualToString:@"read"])
      out |= CBAttributePermissionsReadable;
    else if ([s isEqualToString:@"write"] ||
             [s isEqualToString:@"write_without_response"])
      out |= CBAttributePermissionsWriteable;
  }
  return out;
}

// Build the CBMutableService + characteristics from the advertise JSON, stash
// everything in the globals. Returns YES on a usable parse.
static BOOL ble_build_service(NSDictionary *json) {
  NSString *service_uuid = json[@"service_uuid"];
  if (![service_uuid isKindOfClass:[NSString class]])
    return NO;

  g_local_name = [json[@"local_name"] isKindOfClass:[NSString class]]
                     ? json[@"local_name"]
                     : nil;
  g_chars = [NSMutableDictionary dictionary];

  NSMutableArray<CBMutableCharacteristic *> *char_list = [NSMutableArray array];
  NSArray *chars = json[@"characteristics"];
  if ([chars isKindOfClass:[NSArray class]]) {
    for (id c in chars) {
      if (![c isKindOfClass:[NSDictionary class]])
        continue;
      NSDictionary *cd = (NSDictionary *)c;
      NSString *cuuid = cd[@"uuid"];
      if (![cuuid isKindOfClass:[NSString class]])
        continue;
      NSArray *props = [cd[@"properties"] isKindOfClass:[NSArray class]]
                           ? cd[@"properties"]
                           : @[];
      CBCharacteristicProperties cprops = ble_props_from_array(props);
      CBAttributePermissions cperms = ble_perms_from_array(props);

      // CoreBluetooth requires value:nil for any characteristic that
      // supports notify/indicate (or otherwise has a dynamic value);
      // passing a cached value for such a characteristic raises. We have
      // no initial value to supply anyway, so always create with nil.
      CBUUID *cb_uuid = [CBUUID UUIDWithString:cuuid];
      CBMutableCharacteristic *ch =
          [[CBMutableCharacteristic alloc] initWithType:cb_uuid
                                             properties:cprops
                                                  value:nil
                                            permissions:cperms];
      [char_list addObject:ch];
      g_chars[cb_uuid] = ch;
    }
  }

  CBMutableService *svc = [[CBMutableService alloc]
      initWithType:[CBUUID UUIDWithString:service_uuid]
           primary:YES];
  svc.characteristics = char_list;
  g_pending_service = svc;
  return YES;
}

// Drain the outbound notification queue. MUST run on the CB (main) queue. Stops
// at the first updateValue: NO (transmit queue full);
// peripheralManagerIsReadyToUpdateSubscribers: calls back in to resume.
static void ble_flush_tx(void) {
  if (!g_peripheral || !g_tx_queue)
    return;
  while (g_tx_queue.count > 0) {
    NSDictionary *item = g_tx_queue.firstObject;
    BOOL ok = [g_peripheral updateValue:item[@"data"]
                      forCharacteristic:item[@"ch"]
                   onSubscribedCentrals:nil];
    if (!ok)
      break;
    [g_tx_queue removeObjectAtIndex:0];
  }
}

// ── NIFs ────────────────────────────────────────────────────────────────────

// ble_start_advertising(json_binary) → :ok
// Parses the advertise JSON, builds the service, captures the caller pid, and
// (re)creates the CBPeripheralManager. Actual addService / startAdvertising
// happens asynchronously once the manager reports PoweredOn.
static ERL_NIF_TERM nif_ble_start_advertising(ErlNifEnv *env, int argc,
                                              const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &bin))
    return enif_make_badarg(env);

  NSData *data = [NSData dataWithBytes:bin.data length:bin.size];
  NSError *jerr = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:&jerr];
  if (jerr || ![parsed isKindOfClass:[NSDictionary class]])
    return enif_make_badarg(env);

  enif_self(env, &g_ble_pid);
  g_have_pid = YES;

  if (!ble_build_service((NSDictionary *)parsed)) {
    ble_send_failed("bad_config");
    return enif_make_atom(env, "ok");
  }
  g_want_advertise = YES;

  // Reset central + tx bookkeeping for a fresh advertising session.
  g_centrals = [NSMutableDictionary dictionary];
  g_next_central = 1;
  g_tx_queue = [NSMutableArray array];

  if (!g_delegate)
    g_delegate = [[MobBlePeripheralDelegate alloc] init];

  if (g_peripheral) {
    // Reuse the existing manager; if it's already PoweredOn,
    // peripheralManagerDidUpdateState won't fire again, so drive the
    // add/advertise path directly — on the CB (main) queue.
    if (g_peripheral.state == CBManagerStatePoweredOn) {
      CBMutableService *svc = g_pending_service;
      dispatch_async(dispatch_get_main_queue(), ^{
        [g_peripheral addService:svc];
      });
    }
  } else {
    // nil queue → callbacks on the main queue. Simplest and fine here.
    g_peripheral = [[CBPeripheralManager alloc] initWithDelegate:g_delegate
                                                           queue:nil];
  }
  return enif_make_atom(env, "ok");
}

// ble_stop_advertising() → :ok
static ERL_NIF_TERM nif_ble_stop_advertising(ErlNifEnv *env, int argc,
                                             const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  g_want_advertise = NO;
  // CoreBluetooth calls on the manager's (main) queue.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_peripheral) {
      [g_peripheral stopAdvertising];
      [g_peripheral removeAllServices];
    }
    [g_tx_queue removeAllObjects];
  });
  return enif_make_atom(env, "ok");
}

// ble_notify(char_uuid_binary, bytes_binary) → :ok
// Pushes a value to all subscribed centrals for the named characteristic.
static ERL_NIF_TERM nif_ble_notify(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary ubin, bbin;
  if (!enif_inspect_binary(env, argv[0], &ubin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &ubin))
    return enif_make_badarg(env);
  if (!enif_inspect_binary(env, argv[1], &bbin) &&
      !enif_inspect_iolist_as_binary(env, argv[1], &bbin))
    return enif_make_badarg(env);

  if (!g_peripheral || !g_chars)
    return enif_make_atom(env, "ok");

  NSString *uuid_str = [[NSString alloc] initWithBytes:ubin.data
                                                length:ubin.size
                                              encoding:NSUTF8StringEncoding];
  if (!uuid_str)
    return enif_make_atom(env, "ok");
  CBUUID *cb_uuid = [CBUUID UUIDWithString:uuid_str];
  CBMutableCharacteristic *ch = g_chars[cb_uuid];
  if (!ch)
    return enif_make_atom(env, "ok");

  NSData *payload = [NSData dataWithBytes:bbin.data length:bbin.size];
  CBMutableCharacteristic *target = ch;
  // CoreBluetooth is not thread-safe and must be driven on the manager's queue
  // (main, since we created it with queue:nil). This NIF runs on a BEAM
  // scheduler thread, so hop to main, enqueue, and drain — the queue + the
  // peripheralManagerIsReadyToUpdateSubscribers: resume handle backpressure so
  // a note-off isn't dropped when its note-on filled the transmit queue.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_tx_queue)
      g_tx_queue = [NSMutableArray array];
    if (g_tx_queue.count >= MOB_BLE_TX_CAP) {
      [g_tx_queue removeObjectAtIndex:0]; // sustained backpressure: drop oldest
    }
    [g_tx_queue addObject:@{@"ch" : target, @"data" : payload}];
    ble_flush_tx();
  });
  return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"ble_scan", 1, nif_ble_scan, 0},
    {"ble_stop_scan", 0, nif_ble_stop_scan, 0},
    {"ble_advertise", 1, nif_ble_advertise, 0},
    {"ble_stop_advertise", 0, nif_ble_stop_advertise, 0},
    {"ble_start_advertising", 1, nif_ble_start_advertising, 0},
    {"ble_stop_advertising", 0, nif_ble_stop_advertising, 0},
    {"ble_notify", 2, nif_ble_notify, 0},
};

ERL_NIF_INIT(mob_bluetooth_nif, nif_funcs, NULL, NULL, NULL, NULL)
