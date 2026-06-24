//! mob_bluetooth_nif — Bluetooth Classic (BR/EDR) tier-1 ZIG plugin NIF.
//!
//! Extracted wholesale from mob-core's `mob_nif.zig` (the bt suite): the 16
//! `nif_bt_*` wrappers, the ~33 `mob_deliver_bt_*` delivery exports, the BT
//! atom cache, the term constructors, and the paired-list streaming
//! accumulator. The Kotlin side is the plugin-owned bridge class
//! `io.mob.bluetooth.MobBluetoothBridge`; the JNI delivery thunks live in the
//! sibling `mob_bluetooth_jni.c` (copied verbatim from beam_jni.c with the
//! Java_ symbol prefix renamed).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through the named imports `@import("erts")`
//! (→ mob_erts.zig) and `@import("jni")` (→ mob_zig.zig) that build.zig wires
//! for plugin zig objects. `get_jenv` + `g_jvm` are mob-core exports linked
//! into the same `.so` (extern-declared below, NOT duplicated).
//!
//! Bridge-class registration: the JVM calls
//! `Java_io_mob_bluetooth_MobBluetoothBridge_nativeRegister(jenv, cls)` at
//! startup (via the generated MobPluginBootstrap.registerAll → register()).
//! That thunk caches a global ref to the bridge jclass (`g_bt_cls`) + the 16
//! `bt_*` static method IDs (`g_bt`), with no FindClass / classloader problem.
//! The NIF's outbound `CallStaticVoidMethod` uses that cache; inbound
//! deliveries are reached by the C thunks calling the `mob_deliver_bt_*`
//! exports below.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
// Cached by the nativeRegister thunk. This is the plugin's OWN cache — it does
// NOT touch mob-core's exported `Bridge`. Method signatures match the
// cacheOptional block the bt suite used in mob-core's nif_load.
const BtMethods = struct {
    list_paired: jni.JMethodID = null,
    start_discovery: jni.JMethodID = null,
    cancel_discovery: jni.JMethodID = null,
    make_discoverable: jni.JMethodID = null,
    pair: jni.JMethodID = null,
    unpair: jni.JMethodID = null,
    disconnect: jni.JMethodID = null,
    hfp_connect: jni.JMethodID = null,
    hfp_subscribe_vendor_at: jni.JMethodID = null,
    hfp_send_vendor_at: jni.JMethodID = null,
    hfp_start_sco: jni.JMethodID = null,
    hfp_stop_sco: jni.JMethodID = null,
    spp_connect: jni.JMethodID = null,
    spp_write: jni.JMethodID = null,
};

var g_bt: BtMethods = .{};
var g_bt_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
// The JVM passes the declaring class as `cls` for a static-method thunk, so we
// cache a global ref to it directly — no FindClass, no classloader issue.
// Resolved by name from the loaded .so (zig `export fn` emits the C-ABI
// symbol). Signatures come from the bt cacheOptional block in mob-core's
// nif_load.
export fn Java_io_mob_bluetooth_MobBluetoothBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_bt_cls = jni.newGlobalRef(jenv, cls);
    if (g_bt_cls == null) return;
    g_bt.list_paired = jni.getStaticMethodID(jenv, cls, "bt_list_paired", "(J)V");
    g_bt.start_discovery = jni.getStaticMethodID(jenv, cls, "bt_start_discovery", "(J)V");
    g_bt.cancel_discovery = jni.getStaticMethodID(jenv, cls, "bt_cancel_discovery", "(J)V");
    g_bt.make_discoverable = jni.getStaticMethodID(jenv, cls, "bt_make_discoverable", "(JI)V");
    g_bt.pair = jni.getStaticMethodID(jenv, cls, "bt_pair", "(JLjava/lang/String;)V");
    g_bt.unpair = jni.getStaticMethodID(jenv, cls, "bt_unpair", "(JLjava/lang/String;)V");
    g_bt.disconnect = jni.getStaticMethodID(jenv, cls, "bt_disconnect", "(JI)V");
    g_bt.hfp_connect = jni.getStaticMethodID(jenv, cls, "bt_hfp_connect", "(JLjava/lang/String;)V");
    g_bt.hfp_subscribe_vendor_at = jni.getStaticMethodID(jenv, cls, "bt_hfp_subscribe_vendor_at", "(JILjava/lang/String;)V");
    g_bt.hfp_send_vendor_at = jni.getStaticMethodID(jenv, cls, "bt_hfp_send_vendor_at", "(JILjava/lang/String;Ljava/lang/String;)V");
    g_bt.hfp_start_sco = jni.getStaticMethodID(jenv, cls, "bt_hfp_start_sco", "(JI)V");
    g_bt.hfp_stop_sco = jni.getStaticMethodID(jenv, cls, "bt_hfp_stop_sco", "(JI)V");
    g_bt.spp_connect = jni.getStaticMethodID(jenv, cls, "bt_spp_connect", "(JLjava/lang/String;)V");
    g_bt.spp_write = jni.getStaticMethodID(jenv, cls, "bt_spp_write", "(JI[B)V");
}

// ── Thread-attach helpers ────────────────────────────────────────────────

/// Detach when get_jenv set *attached = 1. Mirrors mob-core's helper.
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── Shared helpers (DUPLICATED from mob-core; mob-core keeps its own) ─────

/// Accept either a plain binary or an iolist (deep-flatten to binary).
fn getBinOrIolist(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM) ?erts.ErlNifBinary {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) != 0) return bin;
    if (erts.enif_inspect_iolist_as_binary(env, term, &bin) != 0) return bin;
    return null;
}

/// Heap-allocate a NUL-terminated copy of an `ErlNifBinary` for NewStringUTF.
fn binToCString(bin: erts.ErlNifBinary) ?[*:0]u8 {
    const buf_ptr = jni.malloc(bin.size + 1) orelse return null;
    const dst: [*]u8 = @ptrCast(buf_ptr);
    @memcpy(dst[0..bin.size], bin.data[0..bin.size]);
    dst[bin.size] = 0;
    return @ptrCast(buf_ptr);
}

inline fn freeCString(p: ?[*:0]u8) void {
    if (p) |ptr| jni.free(@as(?*anyopaque, @ptrCast(ptr)));
}

// ── pid <-> jlong round-trip (bt-only in mob-core; moved wholesale) ───────
//
// Pack an ErlNifPid into a jlong for the JNI-side delivery handle. Kotlin
// hands it back unchanged when it calls one of the mob_deliver_bt_* hooks; we
// round-trip via pidFromLong. On aarch64 ERL_NIF_TERM == jlong width so the
// bitcast is a true reinterpret; on 32-bit ARM we zero-extend / truncate.
inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Call `MobBluetoothBridge.<method>(pid_long, arg)` — the standard async
/// shape. Returns `:ok` unconditionally; results land later via a
/// mob_deliver_bt_* hook. Mirrors mob-core's callBridgePidStr, retargeted at
/// the plugin's own cached class.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_bt_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ═════════════════════════════════════════════════════════════════════════
// BT atom cache
// ═════════════════════════════════════════════════════════════════════════

const MobBtAtoms = struct {
    // Channel atoms
    bt: erts.ERL_NIF_TERM = 0,
    bt_hfp: erts.ERL_NIF_TERM = 0,
    bt_spp: erts.ERL_NIF_TERM = 0,

    // Discovery / pairing tags
    discovery_started: erts.ERL_NIF_TERM = 0,
    discovery_finished: erts.ERL_NIF_TERM = 0,
    discovery_cancelled: erts.ERL_NIF_TERM = 0,
    discovered: erts.ERL_NIF_TERM = 0,
    paired_list: erts.ERL_NIF_TERM = 0,
    paired: erts.ERL_NIF_TERM = 0,
    pair_failed: erts.ERL_NIF_TERM = 0,
    unpaired: erts.ERL_NIF_TERM = 0,
    err: erts.ERL_NIF_TERM = 0,

    // Profile lifecycle tags
    connecting: erts.ERL_NIF_TERM = 0,
    connected: erts.ERL_NIF_TERM = 0,
    connect_failed: erts.ERL_NIF_TERM = 0,
    disconnected: erts.ERL_NIF_TERM = 0,

    // HFP-specific
    vendor_subscribed: erts.ERL_NIF_TERM = 0,
    vendor_at: erts.ERL_NIF_TERM = 0,
    sco_started: erts.ERL_NIF_TERM = 0,
    sco_stopped: erts.ERL_NIF_TERM = 0,

    // SPP-specific
    data: erts.ERL_NIF_TERM = 0,
    written: erts.ERL_NIF_TERM = 0,

    // Map keys
    k_address: erts.ERL_NIF_TERM = 0,
    k_name: erts.ERL_NIF_TERM = 0,
    k_bonded: erts.ERL_NIF_TERM = 0,
    k_reason: erts.ERL_NIF_TERM = 0,
    k_cmd: erts.ERL_NIF_TERM = 0,
    k_cmd_type: erts.ERL_NIF_TERM = 0,
    k_args: erts.ERL_NIF_TERM = 0,
    k_size: erts.ERL_NIF_TERM = 0,

    // Constants
    nil_atom: erts.ERL_NIF_TERM = 0,
    true_atom: erts.ERL_NIF_TERM = 0,
    false_atom: erts.ERL_NIF_TERM = 0,
};

var mob_bt_atoms: MobBtAtoms = .{};

/// Initialise the BT atom cache. Called from the ErlNifEntry `.load`.
pub fn mobBtAtomsInit(env: ?*erts.ErlNifEnv) void {
    mob_bt_atoms.bt = erts.atom(env, "bt");
    mob_bt_atoms.bt_hfp = erts.atom(env, "bt_hfp");
    mob_bt_atoms.bt_spp = erts.atom(env, "bt_spp");

    mob_bt_atoms.discovery_started = erts.atom(env, "discovery_started");
    mob_bt_atoms.discovery_finished = erts.atom(env, "discovery_finished");
    mob_bt_atoms.discovery_cancelled = erts.atom(env, "discovery_cancelled");
    mob_bt_atoms.discovered = erts.atom(env, "discovered");
    mob_bt_atoms.paired_list = erts.atom(env, "paired_list");
    mob_bt_atoms.paired = erts.atom(env, "paired");
    mob_bt_atoms.pair_failed = erts.atom(env, "pair_failed");
    mob_bt_atoms.unpaired = erts.atom(env, "unpaired");
    mob_bt_atoms.err = erts.atom(env, "error");

    mob_bt_atoms.connecting = erts.atom(env, "connecting");
    mob_bt_atoms.connected = erts.atom(env, "connected");
    mob_bt_atoms.connect_failed = erts.atom(env, "connect_failed");
    mob_bt_atoms.disconnected = erts.atom(env, "disconnected");

    mob_bt_atoms.vendor_subscribed = erts.atom(env, "vendor_subscribed");
    mob_bt_atoms.vendor_at = erts.atom(env, "vendor_at");
    mob_bt_atoms.sco_started = erts.atom(env, "sco_started");
    mob_bt_atoms.sco_stopped = erts.atom(env, "sco_stopped");

    mob_bt_atoms.data = erts.atom(env, "data");
    mob_bt_atoms.written = erts.atom(env, "written");

    mob_bt_atoms.k_address = erts.atom(env, "address");
    mob_bt_atoms.k_name = erts.atom(env, "name");
    mob_bt_atoms.k_bonded = erts.atom(env, "bonded");
    mob_bt_atoms.k_reason = erts.atom(env, "reason");
    mob_bt_atoms.k_cmd = erts.atom(env, "cmd");
    mob_bt_atoms.k_cmd_type = erts.atom(env, "cmd_type");
    mob_bt_atoms.k_args = erts.atom(env, "args");
    mob_bt_atoms.k_size = erts.atom(env, "size");

    mob_bt_atoms.nil_atom = erts.atom(env, "nil");
    mob_bt_atoms.true_atom = erts.atom(env, "true");
    mob_bt_atoms.false_atom = erts.atom(env, "false");
}

// ═════════════════════════════════════════════════════════════════════════
// Term constructors — mirror the C mob_bt_make_* helpers
// ═════════════════════════════════════════════════════════════════════════

/// Convert a C string into an Erlang binary term. Empty input → empty binary.
fn mobBtMakeBinaryStr(env: ?*erts.ErlNifEnv, s: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const len: usize = if (s) |p| jni.strlen(p) else 0;
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    if (len > 0) {
        if (s) |p| @memcpy(bin.data[0..len], p[0..len]);
    }
    return erts.enif_make_binary(env, &bin);
}

/// Build a binary term from arbitrary bytes (SPP byte streams, etc).
fn mobBtMakeBinaryBytes(env: ?*erts.ErlNifEnv, bytes: ?[*]const u8, len: usize) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    _ = erts.enif_alloc_binary(len, &bin);
    if (len > 0) {
        if (bytes) |p| @memcpy(bin.data[0..len], p[0..len]);
    }
    return erts.enif_make_binary(env, &bin);
}

/// Build `%{address: <<...>>, name: <<...>>, bonded: bool}`.
fn mobBtMakeDeviceMap(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, name: ?[*:0]const u8, bonded: c_int) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        mob_bt_atoms.k_address,
        mob_bt_atoms.k_name,
        mob_bt_atoms.k_bonded,
    };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        mobBtMakeBinaryStr(env, name),
        if (bonded != 0) mob_bt_atoms.true_atom else mob_bt_atoms.false_atom,
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>}`.
fn mobBtMakeAddressOnly(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_address};
    const vals = [_]erts.ERL_NIF_TERM{mobBtMakeBinaryStr(env, address)};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>, name: <<...>>}`.
fn mobBtMakeAddressName(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, name: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{ mob_bt_atoms.k_address, mob_bt_atoms.k_name };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        mobBtMakeBinaryStr(env, name),
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{address: <<...>>, reason: :reason_atom}`. Reason defaults to
/// `:unknown` for null Kotlin strings — never explodes on missing data.
fn mobBtMakeAddressReason(env: ?*erts.ErlNifEnv, address: ?[*:0]const u8, reason: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const reason_atom = if (reason) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const keys = [_]erts.ERL_NIF_TERM{ mob_bt_atoms.k_address, mob_bt_atoms.k_reason };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, address),
        reason_atom,
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{reason: :reason_atom}`.
fn mobBtMakeReasonOnly(env: ?*erts.ErlNifEnv, reason: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const reason_atom = if (reason) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_reason};
    const vals = [_]erts.ERL_NIF_TERM{reason_atom};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{cmd: <<...>>, cmd_type: int, args: <<...>>, address: <<...>>}` for
/// vendor AT events. cmd_type is the HFP AT command type code.
fn mobBtMakeVendorAtMap(env: ?*erts.ErlNifEnv, cmd: ?[*:0]const u8, cmd_type: c_int, args: ?[*:0]const u8, address: ?[*:0]const u8) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{
        mob_bt_atoms.k_cmd,
        mob_bt_atoms.k_cmd_type,
        mob_bt_atoms.k_args,
        mob_bt_atoms.k_address,
    };
    const vals = [_]erts.ERL_NIF_TERM{
        mobBtMakeBinaryStr(env, cmd),
        erts.enif_make_int(env, cmd_type),
        mobBtMakeBinaryStr(env, args),
        mobBtMakeBinaryStr(env, address),
    };
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}

/// Build `%{size: int}` for write-completion events.
fn mobBtMakeSizeMap(env: ?*erts.ErlNifEnv, size: c_int) erts.ERL_NIF_TERM {
    const keys = [_]erts.ERL_NIF_TERM{mob_bt_atoms.k_size};
    const vals = [_]erts.ERL_NIF_TERM{erts.enif_make_int(env, size)};
    return erts.makeMap(env, &keys, &vals) orelse mob_bt_atoms.err;
}


// ═════════════════════════════════════════════════════════════════════════
// Paired-list streaming accumulator
// ═════════════════════════════════════════════════════════════════════════
//
// Kotlin streams paired devices one at a time (begin → 0..N entries → finish).
// A stable per-pid buffer accumulates entries, since Kotlin can interleave
// streams from concurrent callers. 16 buckets × 128 max entries each. Slot
// lookup/insert/remove holds the table mutex; enif_send happens AFTER the
// mutex is released so a slow consumer doesn't block other accumulators.

const MOB_BT_PAIRED_BUCKETS: usize = 16;
const MOB_BT_PAIRED_MAX_ENTRIES: usize = 128;
const MOB_BT_ADDR_MAX: usize = 24; // "00:11:22:33:44:55" + null + slop
const MOB_BT_NAME_MAX: usize = 248; // BT spec max friendly name + null

const MobBtPairedEntry = extern struct {
    address: [MOB_BT_ADDR_MAX]u8,
    name: [MOB_BT_NAME_MAX]u8,
    bonded: c_int,
};

const MobBtPairedSlot = extern struct {
    pid_long: jni.JLong,
    in_use: c_int,
    count: usize,
    entries: [MOB_BT_PAIRED_MAX_ENTRIES]MobBtPairedEntry,
};

var mob_bt_paired_slots: [MOB_BT_PAIRED_BUCKETS]MobBtPairedSlot = blk: {
    var buf: [MOB_BT_PAIRED_BUCKETS]MobBtPairedSlot = undefined;
    for (&buf) |*s| s.* = std.mem.zeroes(MobBtPairedSlot);
    break :blk buf;
};
var mob_bt_paired_mutex: ?*erts.ErlNifMutex = null;

/// Initialise the paired-list accumulator. Returns 0 on success, -1 on
/// mutex-create failure. Called from the ErlNifEntry `.load`.
pub fn mobBtPairedInit() c_int {
    mob_bt_paired_mutex = erts.enif_mutex_create("mob_bt_paired_mutex") orelse return -1;
    return 0;
}

/// Find an in-use slot matching `pid_long`. Must hold the mutex.
fn mobBtPairedFindLocked(pid_long: jni.JLong) ?*MobBtPairedSlot {
    for (&mob_bt_paired_slots) |*s| {
        if (s.in_use != 0 and s.pid_long == pid_long) return s;
    }
    return null;
}

/// Claim the first free slot for `pid_long`, OR — if `pid_long` already has a
/// slot — reset it for a new accumulation cycle. Must hold mutex.
fn mobBtPairedClaimLocked(pid_long: jni.JLong) ?*MobBtPairedSlot {
    if (mobBtPairedFindLocked(pid_long)) |existing| {
        existing.count = 0;
        return existing;
    }
    for (&mob_bt_paired_slots) |*s| {
        if (s.in_use == 0) {
            s.in_use = 1;
            s.pid_long = pid_long;
            s.count = 0;
            return s;
        }
    }
    return null; // all slots in use — drop this accumulation
}

/// Mark a slot free. Must hold mutex.
fn mobBtPairedReleaseLocked(slot: *MobBtPairedSlot) void {
    slot.in_use = 0;
    slot.pid_long = 0;
    slot.count = 0;
}

// ═════════════════════════════════════════════════════════════════════════
// BT envelope helper — 4-tuple {:bt, tag, session_or_nil, payload}
// ═════════════════════════════════════════════════════════════════════════

/// Return :nil or an integer for the session slot.
inline fn btSessionTerm(env: ?*erts.ErlNifEnv, session: c_int) erts.ERL_NIF_TERM {
    return if (session < 0) mob_bt_atoms.nil_atom else erts.enif_make_int(env, session);
}

// ═════════════════════════════════════════════════════════════════════════
// Delivery functions — `mob_deliver_bt_*` exports
// ═════════════════════════════════════════════════════════════════════════
//
// Called from mob_bluetooth_jni.c's Java_io_mob_bluetooth_MobBluetoothBridge_
// nativeDeliverBt* thunks when Kotlin emits BT events. Each builds the typed
// envelope tuple and posts it to `pid_long` (an ErlNifPid round-tripped
// through Kotlin as a jlong).

// ── Discovery (2-tuples — no payload) ──────────────────────────────────

pub export fn mob_deliver_bt_discovery_started(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_started,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_discovery_finished(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_finished,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_discovery_cancelled(pid_long: jni.JLong) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovery_cancelled,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Discovery / pairing (3-tuples — no session) ────────────────────────

pub export fn mob_deliver_bt_discovered(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.discovered,
        mobBtMakeDeviceMap(env, address, name, bonded),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_paired(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.paired,
        mobBtMakeDeviceMap(env, address, name, bonded),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_pair_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.pair_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_unpaired(pid_long: jni.JLong, address: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.unpaired,
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_error(pid_long: jni.JLong, reason: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.err,
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Legacy JSON paired-devices (unused by current Elixir API but kept for
//    compat with Kotlin templates that pre-date the streamed paired list
//    accumulator). No JNI thunk calls this; kept as an export for parity.
pub export fn mob_deliver_bt_paired_devices(pid_long: jni.JLong, json: ?[*:0]const u8) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        erts.atom(env, "paired_devices_json"),
        mob_bt_atoms.nil_atom,
        mobBtMakeBinaryStr(env, json),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── Paired-list streaming (begin / entry / finish) ─────────────────────

pub export fn mob_deliver_bt_paired_list_begin(pid_long: jni.JLong) callconv(.c) void {
    erts.enif_mutex_lock(mob_bt_paired_mutex);
    _ = mobBtPairedClaimLocked(pid_long);
    erts.enif_mutex_unlock(mob_bt_paired_mutex);
}

pub export fn mob_deliver_bt_paired_list_entry(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
    bonded: c_int,
) callconv(.c) void {
    erts.enif_mutex_lock(mob_bt_paired_mutex);
    defer erts.enif_mutex_unlock(mob_bt_paired_mutex);

    const slot = mobBtPairedFindLocked(pid_long) orelse return;
    if (slot.count >= MOB_BT_PAIRED_MAX_ENTRIES) return;

    const entry = &slot.entries[slot.count];
    if (address) |a| {
        const a_len = jni.strlen(a);
        const a_copy = @min(a_len, entry.address.len - 1);
        @memcpy(entry.address[0..a_copy], a[0..a_copy]);
        entry.address[a_copy] = 0;
    } else {
        entry.address[0] = 0;
    }
    if (name) |n| {
        const n_len = jni.strlen(n);
        const n_copy = @min(n_len, entry.name.len - 1);
        @memcpy(entry.name[0..n_copy], n[0..n_copy]);
        entry.name[n_copy] = 0;
    } else {
        entry.name[0] = 0;
    }
    entry.bonded = if (bonded != 0) 1 else 0;
    slot.count += 1;
}

pub export fn mob_deliver_bt_paired_list_finish(pid_long: jni.JLong) callconv(.c) void {
    // Snapshot under lock, then release before any term allocation.
    var snapshot: MobBtPairedSlot = undefined;

    erts.enif_mutex_lock(mob_bt_paired_mutex);
    const slot = mobBtPairedFindLocked(pid_long);
    if (slot == null) {
        erts.enif_mutex_unlock(mob_bt_paired_mutex);
        return;
    }
    snapshot = slot.?.*;
    mobBtPairedReleaseLocked(slot.?);
    erts.enif_mutex_unlock(mob_bt_paired_mutex);

    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    // Empty list as the cons-cdr seed. enif_make_list is variadic in C and
    // intentionally not exposed in mob_erts.zig; enif_make_list_from_array
    // with count=0 returns the same empty-list term via the non-variadic ABI.
    const empty: [0]erts.ERL_NIF_TERM = .{};
    var list = erts.enif_make_list_from_array(env, &empty, 0);
    var i: usize = snapshot.count;
    while (i > 0) {
        i -= 1;
        const entry = &snapshot.entries[i];
        const addr_ptr: [*:0]const u8 = @ptrCast(&entry.address);
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const dev = mobBtMakeDeviceMap(env, addr_ptr, name_ptr, entry.bonded);
        list = erts.enif_make_list_cell(env, dev, list);
    }

    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt,
        mob_bt_atoms.paired_list,
        list,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── HFP profile deliveries ─────────────────────────────────────────────

pub export fn mob_deliver_bt_hfp_connecting(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connecting,
        erts.enif_make_int(env, session),
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_connected(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connected,
        erts.enif_make_int(env, session),
        mobBtMakeAddressName(env, address, name),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_connect_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.connect_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_disconnected(
    pid_long: jni.JLong,
    session: c_int,
    reason_atom: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason_term = if (reason_atom) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.disconnected,
        erts.enif_make_int(env, session),
        reason_term,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_vendor_subscribed(pid_long: jni.JLong, session: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.vendor_subscribed,
        erts.enif_make_int(env, session),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_vendor_at(
    pid_long: jni.JLong,
    session: c_int,
    cmd: ?[*:0]const u8,
    cmd_type: c_int,
    args: ?[*:0]const u8,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.vendor_at,
        erts.enif_make_int(env, session),
        mobBtMakeVendorAtMap(env, cmd, cmd_type, args, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_sco_started(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.sco_started,
        erts.enif_make_int(env, session),
        mobBtMakeAddressOnly(env, address),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_sco_stopped(pid_long: jni.JLong, session: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.sco_stopped,
        erts.enif_make_int(env, session),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_hfp_error(
    pid_long: jni.JLong,
    session: c_int,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_hfp,
        mob_bt_atoms.err,
        erts.enif_make_int(env, session),
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── SPP profile deliveries ─────────────────────────────────────────────

pub export fn mob_deliver_bt_spp_connected(
    pid_long: jni.JLong,
    session: c_int,
    address: ?[*:0]const u8,
    name: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.connected,
        erts.enif_make_int(env, session),
        mobBtMakeAddressName(env, address, name),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_connect_failed(
    pid_long: jni.JLong,
    address: ?[*:0]const u8,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.connect_failed,
        mobBtMakeAddressReason(env, address, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_disconnected(
    pid_long: jni.JLong,
    session: c_int,
    reason_atom: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason_term = if (reason_atom) |r| erts.enif_make_atom(env, r) else erts.atom(env, "unknown");
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.disconnected,
        erts.enif_make_int(env, session),
        reason_term,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_data(
    pid_long: jni.JLong,
    session: c_int,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.data,
        erts.enif_make_int(env, session),
        mobBtMakeBinaryBytes(env, bytes, len),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_written(pid_long: jni.JLong, session: c_int, size: c_int) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.written,
        erts.enif_make_int(env, session),
        mobBtMakeSizeMap(env, size),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

pub export fn mob_deliver_bt_spp_error(
    pid_long: jni.JLong,
    session: c_int,
    reason: ?[*:0]const u8,
) callconv(.c) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        mob_bt_atoms.bt_spp,
        mob_bt_atoms.err,
        erts.enif_make_int(env, session),
        mobBtMakeReasonOnly(env, reason),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ═════════════════════════════════════════════════════════════════════════
// NIF wrappers — `nif_bt_*`
// ═════════════════════════════════════════════════════════════════════════
//
// Pull caller pid via enif_self, attach JNIEnv, dispatch via the cached
// jmethodID on the plugin's own g_bt_cls, return :ok. All responses come back
// asynchronously through the mob_deliver_bt_* hooks.
//
// `unsupported` short-circuit: if the bridge method id is null (bridge not
// registered, or an older bridge class), emit a single
// `{:bt, :error, nil, %{reason: :unsupported}}` and return :ok.

fn btUnsupported(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    const msg_env = erts.enif_alloc_env() orelse return erts.ok(env);
    defer erts.enif_free_env(msg_env);
    const unsupported = erts.atom(msg_env, "unsupported");
    const keys = [_]erts.ERL_NIF_TERM{erts.atom(msg_env, "reason")};
    const vals = [_]erts.ERL_NIF_TERM{unsupported};
    const map = erts.makeMap(msg_env, &keys, &vals) orelse unsupported;
    const msg = erts.makeTuple(msg_env, .{
        erts.atom(msg_env, "bt"),
        erts.atom(msg_env, "error"),
        erts.atom(msg_env, "nil"),
        map,
    });
    _ = erts.enif_send(null, &pid, msg_env, msg);
    return erts.ok(env);
}

// ── No-arg discovery / paired-list NIFs ──

export fn nif_bt_list_paired(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bt.list_paired == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, g_bt_cls, g_bt.list_paired, pidToJlong(pid));
    return erts.ok(env);
}

export fn nif_bt_start_discovery(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bt.start_discovery == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, g_bt_cls, g_bt.start_discovery, pidToJlong(pid));
    return erts.ok(env);
}

export fn nif_bt_cancel_discovery(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bt.cancel_discovery == null) return btUnsupported(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(jenv, g_bt_cls, g_bt.cancel_discovery, pidToJlong(pid));
    return erts.ok(env);
}

export fn nif_bt_make_discoverable(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.make_discoverable == null) return btUnsupported(env);
    var duration: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &duration) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.make_discoverable,
        pidToJlong(pid),
        @as(jni.JInt, duration),
    );
    return erts.ok(env);
}

// ── JSON-arg NIFs (pair / unpair / hfp_connect / spp_connect) ──

export fn nif_bt_pair(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.pair == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_bt.pair, pid, json);
}

export fn nif_bt_unpair(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.unpair == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_bt.unpair, pid, json);
}

export fn nif_bt_hfp_connect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.hfp_connect == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_bt.hfp_connect, pid, json);
}

export fn nif_bt_spp_connect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.spp_connect == null) return btUnsupported(env);
    const bin = getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_bt.spp_connect, pid, json);
}

// ── Session-only NIFs ──

export fn nif_bt_disconnect(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.disconnect == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.disconnect,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_bt_hfp_subscribe_vendor_at(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.hfp_subscribe_vendor_at == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const json = binToCString(bin) orelse return erts.atom(env, "error");
    defer freeCString(json);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jjson = jni.newStringUTF(jenv, json);
    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.hfp_subscribe_vendor_at,
        pidToJlong(pid),
        @as(jni.JInt, session),
        jjson,
    );
    if (jjson != null) jni.deleteLocalRef(jenv, jjson);
    return erts.ok(env);
}

export fn nif_bt_hfp_start_sco(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.hfp_start_sco == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.hfp_start_sco,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

export fn nif_bt_hfp_stop_sco(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.hfp_stop_sco == null) return btUnsupported(env);
    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.hfp_stop_sco,
        pidToJlong(pid),
        @as(jni.JInt, session),
    );
    return erts.ok(env);
}

// ── Two-string + session NIF (hfp_send_vendor_at/3) ──

export fn nif_bt_hfp_send_vendor_at(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.hfp_send_vendor_at == null) return btUnsupported(env);

    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);

    const cmd_bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);
    const cmd = binToCString(cmd_bin) orelse return erts.atom(env, "error");
    defer freeCString(cmd);

    const args_bin = getBinOrIolist(env, argv[2]) orelse return erts.badarg(env);
    const args = binToCString(args_bin) orelse return erts.atom(env, "error");
    defer freeCString(args);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const jcmd = jni.newStringUTF(jenv, cmd);
    const jargs = jni.newStringUTF(jenv, args);
    jenv.*.CallStaticVoidMethod.?(
        jenv,
        g_bt_cls,
        g_bt.hfp_send_vendor_at,
        pidToJlong(pid),
        @as(jni.JInt, session),
        jcmd,
        jargs,
    );
    if (jcmd != null) jni.deleteLocalRef(jenv, jcmd);
    if (jargs != null) jni.deleteLocalRef(jenv, jargs);
    return erts.ok(env);
}

// ── Byte-array NIF (spp_write/2) — dirty IO ──

export fn nif_bt_spp_write(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_bt.spp_write == null) return btUnsupported(env);

    var session: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &session) == 0) return erts.badarg(env);
    const bin = getBinOrIolist(env, argv[1]) orelse return erts.badarg(env);

    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    defer detachIfAttached(attached);

    const size: jni.JSize = @intCast(bin.size);
    const jbytes = jni.newByteArray(jenv, size);
    if (jbytes != null) {
        jni.setByteArrayRegion(jenv, jbytes, 0, size, @ptrCast(bin.data));
        jenv.*.CallStaticVoidMethod.?(
            jenv,
            g_bt_cls,
            g_bt.spp_write,
            pidToJlong(pid),
            @as(jni.JInt, session),
            jbytes,
        );
        jni.deleteLocalRef(jenv, jbytes);
    }
    return erts.ok(env);
}

// ── ErlNifEntry `.load` — init atom cache + paired-list accumulator ───────

fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = priv;
    _ = info;
    mobBtAtomsInit(env);
    if (mobBtPairedInit() != 0) return -1;
    return 0;
}

// ── NIF table + init entry point ─────────────────────────────────────────

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "bt_list_paired", .arity = 0, .fptr = nif_bt_list_paired, .flags = 0 },
    .{ .name = "bt_start_discovery", .arity = 0, .fptr = nif_bt_start_discovery, .flags = 0 },
    .{ .name = "bt_cancel_discovery", .arity = 0, .fptr = nif_bt_cancel_discovery, .flags = 0 },
    .{ .name = "bt_make_discoverable", .arity = 1, .fptr = nif_bt_make_discoverable, .flags = 0 },
    .{ .name = "bt_pair", .arity = 1, .fptr = nif_bt_pair, .flags = 0 },
    .{ .name = "bt_unpair", .arity = 1, .fptr = nif_bt_unpair, .flags = 0 },
    .{ .name = "bt_disconnect", .arity = 1, .fptr = nif_bt_disconnect, .flags = 0 },
    .{ .name = "bt_hfp_connect", .arity = 1, .fptr = nif_bt_hfp_connect, .flags = 0 },
    .{ .name = "bt_hfp_subscribe_vendor_at", .arity = 2, .fptr = nif_bt_hfp_subscribe_vendor_at, .flags = 0 },
    .{ .name = "bt_hfp_send_vendor_at", .arity = 3, .fptr = nif_bt_hfp_send_vendor_at, .flags = 0 },
    .{ .name = "bt_hfp_start_sco", .arity = 1, .fptr = nif_bt_hfp_start_sco, .flags = 0 },
    .{ .name = "bt_hfp_stop_sco", .arity = 1, .fptr = nif_bt_hfp_stop_sco, .flags = 0 },
    .{ .name = "bt_spp_connect", .arity = 1, .fptr = nif_bt_spp_connect, .flags = 0 },
    .{ .name = "bt_spp_write", .arity = 2, .fptr = nif_bt_spp_write, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_bluetooth_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1, // enable dirty-NIF support (spp_write is dirty IO).
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

/// The symbol the BEAM looks up via the static NIF table (driver_tab) to find
/// this NIF's `ErlNifEntry`. RegenDriverTab extern-declares it as
/// `mob_bluetooth_nif_nif_init` over C ABI.
pub export fn mob_bluetooth_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
