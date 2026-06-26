// mob_bluetooth_jni.c — JNI delivery thunks for the mob_bluetooth plugin.
//
// Copied VERBATIM from mob-core's beam_jni.c Bluetooth section, with ONLY the
// JNI symbol prefix renamed:
//   Java_com_example_mob_1plugin_1demo_MobBridge_nativeDeliverBt*
//     →  Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBt*
//
// Compiled as a plain C object via the plugin `jni_source` pipeline
// (build.zig `-Dplugin_jni_sources`) — NOT a NIF init (no
// STATIC_ERLANG_NIF_LIBNAME). Each thunk unmarshals the Java args into C
// primitives, calls the matching `mob_deliver_bt_*` export (defined in the
// sibling zig NIF `mob_bluetooth_nif.zig`, linked into the same .so), then
// releases.
//
// mob-core's beam_jni.c gets these `mob_deliver_bt_*` prototypes from
// `mob_beam.h`; this plugin source isn't built against that header, so the
// prototypes are declared inline below (copied byte-for-byte from the
// `mob_deliver_bt_*` block of mob_beam.h, which mirrors the zig export
// signatures).

#include <jni.h>
#include <stddef.h>

// ── mob_deliver_bt_* prototypes (from the zig NIF, replicating mob_beam.h) ──

// Discovery (no-payload 2-tuples)
void mob_deliver_bt_discovery_started(jlong pid);
void mob_deliver_bt_discovery_finished(jlong pid);
void mob_deliver_bt_discovery_cancelled(jlong pid);

// Discovery / pairing events (3-tuples, no session)
void mob_deliver_bt_discovered(jlong pid, const char *address, const char *name,
                               int bonded);
void mob_deliver_bt_paired(jlong pid, const char *address, const char *name,
                           int bonded);
void mob_deliver_bt_pair_failed(jlong pid, const char *address,
                                const char *reason);
void mob_deliver_bt_unpaired(jlong pid, const char *address);
void mob_deliver_bt_error(jlong pid, const char *reason);

// Paired-list streaming (begin / entry / finish)
void mob_deliver_bt_paired_list_begin(jlong pid);
void mob_deliver_bt_paired_list_entry(jlong pid, const char *address,
                                      const char *name, int bonded);
void mob_deliver_bt_paired_list_finish(jlong pid);

// HFP profile
void mob_deliver_bt_hfp_connecting(jlong pid, int session, const char *address);
void mob_deliver_bt_hfp_connected(jlong pid, int session, const char *address,
                                  const char *name);
void mob_deliver_bt_hfp_connect_failed(jlong pid, const char *address,
                                       const char *reason);
void mob_deliver_bt_hfp_disconnected(jlong pid, int session,
                                     const char *reason_atom);
void mob_deliver_bt_hfp_vendor_subscribed(jlong pid, int session);
void mob_deliver_bt_hfp_vendor_at(jlong pid, int session, const char *cmd,
                                  int cmd_type, const char *args,
                                  const char *address);
void mob_deliver_bt_hfp_sco_started(jlong pid, int session,
                                    const char *address);
void mob_deliver_bt_hfp_sco_stopped(jlong pid, int session);
void mob_deliver_bt_hfp_error(jlong pid, int session, const char *reason);

// SPP profile
void mob_deliver_bt_spp_connected(jlong pid, int session, const char *address,
                                  const char *name);
void mob_deliver_bt_spp_connect_failed(jlong pid, const char *address,
                                       const char *reason);
void mob_deliver_bt_spp_disconnected(jlong pid, int session,
                                     const char *reason_atom);
void mob_deliver_bt_spp_data(jlong pid, int session, const char *bytes,
                             size_t len);
void mob_deliver_bt_spp_written(jlong pid, int session, int size);
void mob_deliver_bt_spp_error(jlong pid, int session, const char *reason);

// ── Bluetooth Classic (Mob.Bt suite) — JNI thunks ───────────────────────
// Each thunk unmarshals Java args into C primitives, calls the matching
// mob_deliver_bt_* helper, then releases.

// ── Adapter-level events (no session) ──────────────────────────────────

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtDiscoveryStarted(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_bt_discovery_started(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtDiscoveryFinished(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_bt_discovery_finished(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtDiscoveryCancelled(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_bt_discovery_cancelled(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtDiscovered(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring name,
    jboolean bonded) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
  mob_deliver_bt_discovered(pid, c_address, c_name, bonded ? 1 : 0);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, name, c_name);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtPaired(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring name,
    jboolean bonded) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
  mob_deliver_bt_paired(pid, c_address, c_name, bonded ? 1 : 0);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, name, c_name);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtPairFailed(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring reason) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_pair_failed(pid, c_address, c_reason);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtUnpaired(
    JNIEnv *env, jclass cls, jlong pid, jstring address) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  mob_deliver_bt_unpaired(pid, c_address);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtError(JNIEnv *env,
                                                              jclass cls,
                                                              jlong pid,
                                                              jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_error(pid, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

// ── Paired-list streaming builder ──────────────────────────────────────

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtPairedListBegin(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_bt_paired_list_begin(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtPairedListEntry(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring name,
    jboolean bonded) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
  mob_deliver_bt_paired_list_entry(pid, c_address, c_name, bonded ? 1 : 0);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, name, c_name);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtPairedListFinish(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_bt_paired_list_finish(pid);
}

// ── HFP profile ────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpConnecting(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring address) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  mob_deliver_bt_hfp_connecting(pid, (int)session, c_address);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpConnected(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring address,
    jstring name) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
  mob_deliver_bt_hfp_connected(pid, (int)session, c_address, c_name);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, name, c_name);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpConnectFailed(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring reason) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_hfp_connect_failed(pid, c_address, c_reason);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpDisconnected(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_hfp_disconnected(pid, (int)session, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpVendorSubscribed(
    JNIEnv *env, jclass cls, jlong pid, jint session) {
  mob_deliver_bt_hfp_vendor_subscribed(pid, (int)session);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpVendorAt(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring cmd,
    jint cmd_type, jstring args, jstring address) {
  const char *c_cmd = (*env)->GetStringUTFChars(env, cmd, NULL);
  const char *c_args = (*env)->GetStringUTFChars(env, args, NULL);
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  mob_deliver_bt_hfp_vendor_at(pid, (int)session, c_cmd, (int)cmd_type, c_args,
                               c_address);
  (*env)->ReleaseStringUTFChars(env, cmd, c_cmd);
  (*env)->ReleaseStringUTFChars(env, args, c_args);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpScoStarted(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring address) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  mob_deliver_bt_hfp_sco_started(pid, (int)session, c_address);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpScoStopped(
    JNIEnv *env, jclass cls, jlong pid, jint session) {
  mob_deliver_bt_hfp_sco_stopped(pid, (int)session);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtHfpError(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_hfp_error(pid, (int)session, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

// ── SPP profile ────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppConnected(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring address,
    jstring name) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
  mob_deliver_bt_spp_connected(pid, (int)session, c_address, c_name);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, name, c_name);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppConnectFailed(
    JNIEnv *env, jclass cls, jlong pid, jstring address, jstring reason) {
  const char *c_address = (*env)->GetStringUTFChars(env, address, NULL);
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_spp_connect_failed(pid, c_address, c_reason);
  (*env)->ReleaseStringUTFChars(env, address, c_address);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppDisconnected(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_spp_disconnected(pid, (int)session, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppData(
    JNIEnv *env, jclass cls, jlong pid, jint session, jbyteArray data) {
  jsize len = (*env)->GetArrayLength(env, data);
  jbyte *buf = (*env)->GetByteArrayElements(env, data, NULL);
  mob_deliver_bt_spp_data(pid, (int)session, (const char *)buf, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppWritten(
    JNIEnv *env, jclass cls, jlong pid, jint session, jint size) {
  mob_deliver_bt_spp_written(pid, (int)session, (int)size);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBtSppError(
    JNIEnv *env, jclass cls, jlong pid, jint session, jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_bt_spp_error(pid, (int)session, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

// ── BLE (Low Energy) peripheral — mob_deliver_ble_* prototypes + thunks ──

void mob_deliver_ble_advertising_started(jlong pid);
void mob_deliver_ble_advertising_failed(jlong pid, const char *reason);
void mob_deliver_ble_central_connected(jlong pid, int central);
void mob_deliver_ble_central_disconnected(jlong pid, int central);
void mob_deliver_ble_subscribed(jlong pid, const char *characteristic);
void mob_deliver_ble_unsubscribed(jlong pid, const char *characteristic);
void mob_deliver_ble_write(jlong pid, const char *characteristic,
                           const char *bytes, size_t len);

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleAdvertisingStarted(
    JNIEnv *env, jclass cls, jlong pid) {
  mob_deliver_ble_advertising_started(pid);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleAdvertisingFailed(
    JNIEnv *env, jclass cls, jlong pid, jstring reason) {
  const char *c_reason = (*env)->GetStringUTFChars(env, reason, NULL);
  mob_deliver_ble_advertising_failed(pid, c_reason);
  (*env)->ReleaseStringUTFChars(env, reason, c_reason);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleCentralConnected(
    JNIEnv *env, jclass cls, jlong pid, jint central) {
  mob_deliver_ble_central_connected(pid, (int)central);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleCentralDisconnected(
    JNIEnv *env, jclass cls, jlong pid, jint central) {
  mob_deliver_ble_central_disconnected(pid, (int)central);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleSubscribed(
    JNIEnv *env, jclass cls, jlong pid, jstring characteristic) {
  const char *c_char = (*env)->GetStringUTFChars(env, characteristic, NULL);
  mob_deliver_ble_subscribed(pid, c_char);
  (*env)->ReleaseStringUTFChars(env, characteristic, c_char);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleUnsubscribed(
    JNIEnv *env, jclass cls, jlong pid, jstring characteristic) {
  const char *c_char = (*env)->GetStringUTFChars(env, characteristic, NULL);
  mob_deliver_ble_unsubscribed(pid, c_char);
  (*env)->ReleaseStringUTFChars(env, characteristic, c_char);
}

JNIEXPORT void JNICALL
Java_io_mob_bluetooth_MobBluetoothBridge_nativeDeliverBleWrite(
    JNIEnv *env, jclass cls, jlong pid, jstring characteristic,
    jbyteArray data) {
  const char *c_char = (*env)->GetStringUTFChars(env, characteristic, NULL);
  jsize len = (*env)->GetArrayLength(env, data);
  jbyte *buf = (*env)->GetByteArrayElements(env, data, NULL);
  mob_deliver_ble_write(pid, c_char, (const char *)buf, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
  (*env)->ReleaseStringUTFChars(env, characteristic, c_char);
}
