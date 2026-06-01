// MobBluetoothBridge.kt — plugin-owned Kotlin bridge class for mob_bluetooth.
//
// Extracted wholesale from mob-core's app `MobBridge.kt` (the bt suite): the 16
// implemented `bt_*` methods (BluetoothAdapter / socket / HFP / SCO code), the
// 32 `nativeDeliverBt*` externals, and the bt companion state. Re-homed to the
// plugin's OWN package `io.mob.bluetooth` so the JNI thunk symbol names
// (`Java_io_mob_bluetooth_MobBluetoothBridge_*`) are package-stable and
// shippable (they live in the sibling mob_bluetooth_jni.c).
//
// Registration: mob_dev copies this file into the app Kotlin sourceSet at build
// time and generates `MobPluginBootstrap.registerAll(activity)` (called from
// MainActivity.onCreate) which invokes `register()`. `register()` calls the
// `nativeRegister` thunk (in the zig NIF), which receives THIS class as its
// `cls` arg and caches the jclass + bt_* method ids — no FindClass, no
// classloader problem. The NIF's outbound CallStaticVoidMethod uses that cache;
// these methods' inbound nativeDeliverBt* externs resolve to the plugin's own
// JNI thunks.
//
// Activity access: the bt methods need an Android Activity. mob-core's
// MobBridge holds a private `activityRef` set from `init(activity)`. This
// plugin class can't see that private field (different package), so it keeps
// its OWN `activityRef`. It opts into the generic handoff by implementing
// `io.mob.plugin.MobActivityAware`; the generated bootstrap calls
// `setActivity(activity)` right after `register()`. No plugin-specific wiring
// in the host (see mob_dev decisions/2026-05-31-plugin-activity-handoff.md).
package io.mob.bluetooth

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.util.Log
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

object MobBluetoothBridge : io.mob.plugin.MobActivityAware {

  // ── Bridge-class registration (caches this jclass + bt_* method ids) ─────
  @JvmStatic external fun nativeRegister()

  @JvmStatic
  fun register() {
    nativeRegister()
  }

  // ── Activity reference (see NOTE in the file header) ─────────────────────
  private var activityRef: WeakReference<Activity>? = null

  /**
   * Supplied by the generated MobPluginBootstrap.registerAll(activity) at
   * startup (MobActivityAware contract). Held weakly to avoid leaking the
   * Activity across its lifecycle.
   */
  // Not @JvmStatic: it overrides MobActivityAware.setActivity, and @JvmStatic
  // is illegal on an interface override in an object. Called via the interface
  // (instance dispatch) from the generated bootstrap's handOff, so no static
  // accessor is needed.
  override fun setActivity(activity: Activity) {
    activityRef = WeakReference(activity)
  }

  // ── Mob.Bt — typed delivery externs (resolve to mob_bluetooth_jni.c) ─────
  @JvmStatic external fun nativeDeliverBtDiscoveryStarted(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscoveryFinished(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscoveryCancelled(pid: Long)
  @JvmStatic external fun nativeDeliverBtDiscovered(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPaired(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPairFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtUnpaired(pid: Long, address: String)
  @JvmStatic external fun nativeDeliverBtError(pid: Long, reason: String)
  @JvmStatic external fun nativeDeliverBtPairedListBegin(pid: Long)
  @JvmStatic external fun nativeDeliverBtPairedListEntry(pid: Long, address: String, name: String, bonded: Boolean)
  @JvmStatic external fun nativeDeliverBtPairedListFinish(pid: Long)
  @JvmStatic external fun nativeDeliverBtHfpConnecting(pid: Long, session: Int, address: String)
  @JvmStatic external fun nativeDeliverBtHfpConnected(pid: Long, session: Int, address: String, name: String)
  @JvmStatic external fun nativeDeliverBtHfpConnectFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtHfpDisconnected(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtHfpVendorSubscribed(pid: Long, session: Int)
  @JvmStatic external fun nativeDeliverBtHfpVendorAt(pid: Long, session: Int, cmd: String, cmdType: Int, args: String, address: String)
  @JvmStatic external fun nativeDeliverBtHfpScoStarted(pid: Long, session: Int, address: String)
  @JvmStatic external fun nativeDeliverBtHfpScoStopped(pid: Long, session: Int)
  @JvmStatic external fun nativeDeliverBtHfpError(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtSppConnected(pid: Long, session: Int, address: String, name: String)
  @JvmStatic external fun nativeDeliverBtSppConnectFailed(pid: Long, address: String, reason: String)
  @JvmStatic external fun nativeDeliverBtSppDisconnected(pid: Long, session: Int, reason: String)
  @JvmStatic external fun nativeDeliverBtSppData(pid: Long, session: Int, data: ByteArray)
  @JvmStatic external fun nativeDeliverBtSppWritten(pid: Long, session: Int, size: Int)
  @JvmStatic external fun nativeDeliverBtSppError(pid: Long, session: Int, reason: String)

  // ── BT companion state ───────────────────────────────────────────────────
  private val btSessionMap = ConcurrentHashMap<Int, BluetoothDevice>()
  private val btSessionCounter = AtomicInteger(1)
  private var btDiscoveryReceiver: BroadcastReceiver? = null
  private var btDiscoveryPid: Long = 0
  private var btBondReceiver: BroadcastReceiver? = null
  private val btBondPids = ConcurrentHashMap<String, Long>()
  private var btHfpProxy: BluetoothHeadset? = null
  private val btHfpVendorPids = ConcurrentHashMap<Int, Long>()
  private var btHfpVendorReceiver: BroadcastReceiver? = null
  private val btSppSockets = ConcurrentHashMap<Int, BluetoothSocket>()
  private val btSppReadThreads = ConcurrentHashMap<Int, Thread>()

  private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

  private fun btAdapter(): BluetoothAdapter? {
      val ctx = activityRef?.get() ?: return null
      val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
      return mgr?.adapter
  }

  private fun btSessionFor(device: BluetoothDevice): Int {
      for ((id, dev) in btSessionMap) {
          if (dev.address == device.address) return id
      }
      val id = btSessionCounter.getAndIncrement()
      btSessionMap[id] = device
      return id
  }

  private fun btSafeName(device: BluetoothDevice): String =
      try { device.name ?: device.address } catch (_: SecurityException) { device.address }

  // ── Discovery / pair / list paired ──────────────────────────────────────

  @JvmStatic
  fun bt_list_paired(pid: Long) {
      val adapter = btAdapter() ?: run { Log.d("MobBT", "no_adapter"); nativeDeliverBtError(pid, "no_adapter"); Log.d("MobBT", "after no_adapter delivery"); return }
      if (!adapter.isEnabled) { Log.d("MobBT", "adapter_disabled"); nativeDeliverBtError(pid, "adapter_disabled"); Log.d("MobBT", "after adapter_disabled delivery"); return }
      try {
          nativeDeliverBtPairedListBegin(pid)
          for (dev in adapter.bondedDevices ?: emptySet()) {
              nativeDeliverBtPairedListEntry(pid,
                  dev.address,
                  btSafeName(dev),
                  dev.bondState == BluetoothDevice.BOND_BONDED)
          }
          nativeDeliverBtPairedListFinish(pid)
      } catch (e: SecurityException) {
          nativeDeliverBtError(pid, "permission_denied")
      }
  }

  @JvmStatic
  fun bt_start_discovery(pid: Long) {
      Log.d("MobBT", "bt_start_discovery entered, pid=$pid")
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get() ?: run { Log.d("MobBT", "no_activity"); nativeDeliverBtError(pid, "no_activity"); Log.d("MobBT", "after no_activity delivery"); return }
      if (!adapter.isEnabled) { nativeDeliverBtError(pid, "adapter_disabled"); return }

      Log.d("MobBT", "step1: about to unregister old receiver if exists")
      if (btDiscoveryReceiver != null) {
          try { activity.unregisterReceiver(btDiscoveryReceiver) } catch (_: Exception) {}
          btDiscoveryReceiver = null
      }
      Log.d("MobBT", "step2: setting btDiscoveryPid")

      btDiscoveryPid = pid
      Log.d("MobBT", "step3: about to create receiver")
      val receiver = object : BroadcastReceiver() {
          override fun onReceive(ctx: Context, intent: Intent) {
              val deliveryPid = btDiscoveryPid
              if (deliveryPid == 0L) return
              when (intent.action) {
                  BluetoothDevice.ACTION_FOUND -> {
                      val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                          intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                      else
                          @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                      if (device != null) {
                          nativeDeliverBtDiscovered(deliveryPid,
                              device.address,
                              btSafeName(device),
                              device.bondState == BluetoothDevice.BOND_BONDED)
                      }
                  }
                  BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                      nativeDeliverBtDiscoveryFinished(deliveryPid)
                  }
              }
          }
      }
      Log.d("MobBT", "step4: assigning receiver")
      btDiscoveryReceiver = receiver
      Log.d("MobBT", "step5: building filter")
      val filter = IntentFilter().apply {
          addAction(BluetoothDevice.ACTION_FOUND)
          addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
      }
      Log.d("MobBT", "step6: registering receiver, SDK=${Build.VERSION.SDK_INT}")
      try {
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(receiver, filter)
          }
          Log.d("MobBT", "step7: receiver registered OK")
      } catch (e: Exception) {
          Log.e("MobBT", "registerReceiver threw: ${e.javaClass.simpleName}: ${e.message}", e)
          nativeDeliverBtError(pid, "register_failed")
          return
      }

      try {
          Log.d("MobBT", "step8: checking isDiscovering")
          if (adapter.isDiscovering) {
              Log.d("MobBT", "step9: already discovering, cancelling")
              adapter.cancelDiscovery()
          }
          Log.d("MobBT", "step10: calling adapter.startDiscovery()")
          val result = adapter.startDiscovery()
          Log.d("MobBT", "step11: startDiscovery returned $result")
          if (!result) {
              Log.d("MobBT", "step12: start_failed")
              nativeDeliverBtError(pid, "start_failed")
              return
          }
          Log.d("MobBT", "step13: calling nativeDeliverBtDiscoveryStarted, pid=$pid")
          nativeDeliverBtDiscoveryStarted(pid)
          Log.d("MobBT", "step14: nativeDeliverBtDiscoveryStarted returned")
      } catch (e: SecurityException) {
          Log.e("MobBT", "SecurityException: ${e.message}", e)
          nativeDeliverBtError(pid, "permission_denied")
      } catch (e: Exception) {
          Log.e("MobBT", "Unexpected exception: ${e.javaClass.simpleName}: ${e.message}", e)
          nativeDeliverBtError(pid, "exception")
      }
  }

  @JvmStatic
  fun bt_cancel_discovery(pid: Long) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get()
      try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
      btDiscoveryReceiver?.let {
          try { activity?.unregisterReceiver(it) } catch (_: Exception) {}
          btDiscoveryReceiver = null
      }
      nativeDeliverBtDiscoveryCancelled(pid)
  }

  @JvmStatic
  fun bt_pair(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val activity = activityRef?.get() ?: run { nativeDeliverBtError(pid, "no_activity"); return }
      val mac = try { JSONObject(json).optString("address").takeIf { it.isNotEmpty() } }
                catch (_: Exception) { null }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }

      if (device.bondState == BluetoothDevice.BOND_BONDED) {
          nativeDeliverBtPaired(pid, device.address, btSafeName(device), true)
          return
      }

      if (btBondReceiver == null) {
          btBondReceiver = object : BroadcastReceiver() {
              override fun onReceive(ctx: Context, intent: Intent) {
                  if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                  val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                  else
                      @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                  if (dev == null) return
                  val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                  val waitingPid = btBondPids[dev.address] ?: return
                  when (state) {
                      BluetoothDevice.BOND_BONDED -> {
                          nativeDeliverBtPaired(waitingPid, dev.address, btSafeName(dev), true)
                          btBondPids.remove(dev.address)
                      }
                      BluetoothDevice.BOND_NONE -> {
                          nativeDeliverBtPairFailed(waitingPid, dev.address, "bond_none")
                          btBondPids.remove(dev.address)
                      }
                  }
              }
          }
          val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(btBondReceiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(btBondReceiver, filter)
          }
      }

      btBondPids[device.address] = pid
      try {
          if (!device.createBond()) {
              btBondPids.remove(device.address)
              nativeDeliverBtPairFailed(pid, device.address, "create_bond_failed")
          }
      } catch (e: SecurityException) {
          btBondPids.remove(device.address)
          nativeDeliverBtPairFailed(pid, device.address, "permission_denied")
      }
  }

  @JvmStatic
  fun bt_unpair(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val mac = try { JSONObject(json).optString("address").takeIf { it.isNotEmpty() } }
                catch (_: Exception) { null }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }
      try {
          val method = device.javaClass.getMethod("removeBond")
          val ok = method.invoke(device) as? Boolean ?: false
          if (ok) nativeDeliverBtUnpaired(pid, device.address)
          else    nativeDeliverBtError(pid, "remove_bond_failed")
      } catch (e: Exception) {
          nativeDeliverBtError(pid, "remove_bond_unavailable")
      }
  }

  // ── Generic disconnect by session ───────────────────────────────────────

  @JvmStatic
  fun bt_disconnect(pid: Long, session: Int) {
      val device = btSessionMap[session]
      if (device == null) {
          nativeDeliverBtError(pid, "no_session")
          return
      }
      btSppSockets.remove(session)?.let {
          try { it.close() } catch (_: Exception) {}
      }
      btSppReadThreads.remove(session)?.interrupt()
      btHfpVendorPids.remove(session)
      btSessionMap.remove(session)
      nativeDeliverBtSppDisconnected(pid, session, "local")
  }

  // ── HFP profile ────────────────────────────────────────────────────────

  private fun acquireHfpProxy(activity: Activity, onReady: (BluetoothHeadset?) -> Unit) {
      if (btHfpProxy != null) { onReady(btHfpProxy); return }
      val adapter = btAdapter() ?: run { onReady(null); return }
      val listener = object : BluetoothProfile.ServiceListener {
          override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
              if (profile == BluetoothProfile.HEADSET) {
                  btHfpProxy = proxy as? BluetoothHeadset
                  onReady(btHfpProxy)
              }
          }
          override fun onServiceDisconnected(profile: Int) {
              if (profile == BluetoothProfile.HEADSET) btHfpProxy = null
          }
      }
      adapter.getProfileProxy(activity, listener, BluetoothProfile.HEADSET)
  }

  @JvmStatic
  fun bt_hfp_connect(pid: Long, json: String) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtError(pid, "no_activity"); return }
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val mac = try { JSONObject(json).optString("address").takeIf { it.isNotEmpty() } }
                catch (_: Exception) { null }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }

      acquireHfpProxy(activity) { proxy ->
          if (proxy == null) {
              nativeDeliverBtHfpConnectFailed(pid, mac, "hfp_proxy_unavailable")
              return@acquireHfpProxy
          }
          val session = btSessionFor(device)
          val connected = proxy.connectedDevices.any { it.address == device.address }
          if (connected) {
              nativeDeliverBtHfpConnected(pid, session, device.address, btSafeName(device))
          } else {
              try {
                  val method = proxy.javaClass.getMethod("connect", BluetoothDevice::class.java)
                  val ok = method.invoke(proxy, device) as? Boolean ?: false
                  if (ok) {
                      nativeDeliverBtHfpConnecting(pid, session, device.address)
                  } else {
                      nativeDeliverBtHfpConnectFailed(pid, device.address, "hfp_connect_failed")
                  }
              } catch (e: Exception) {
                  nativeDeliverBtHfpConnectFailed(pid, device.address, "hfp_connect_unavailable")
              }
          }
      }
  }

  @JvmStatic
  fun bt_hfp_subscribe_vendor_at(pid: Long, session: Int, companyIdsJson: String) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      btHfpVendorPids[session] = pid

      // Parse company_ids from JSON envelope {"company_ids":[int, int, ...]}.
      // Empty list is valid: the receiver registers, but no events route through.
      val companyIds: List<Int> = try {
          val obj = org.json.JSONObject(companyIdsJson)
          val arr = obj.getJSONArray("company_ids")
          (0 until arr.length()).map { arr.getInt(it) }
      } catch (e: Exception) {
          emptyList()
      }

      if (btHfpVendorReceiver == null) {
          btHfpVendorReceiver = object : BroadcastReceiver() {
              override fun onReceive(ctx: Context, intent: Intent) {
                  if (intent.action != BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT) return
                  val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                  else
                      @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                  val cmd = intent.getStringExtra(
                      BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD)
                  val cmdType = intent.getIntExtra(
                      BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD_TYPE, -1)
                  val args = intent.getSerializableExtra(
                      "android.bluetooth.headset.extra.VENDOR_SPECIFIC_HEADSET_EVENT_ARGS")
                  if (dev == null || cmd == null) return
                  val devSession = btSessionMap.entries.firstOrNull { it.value.address == dev.address }?.key
                      ?: btSessionFor(dev)
                  val deliveryPid = btHfpVendorPids[devSession] ?: return
                  nativeDeliverBtHfpVendorAt(deliveryPid, devSession,
                      cmd, cmdType,
                      args?.toString() ?: "",
                      dev.address)
              }
          }
          val filter = IntentFilter(BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT).apply {
              // Register only the company IDs the caller asked for.
              // Android's ACTION_VENDOR_SPECIFIC_HEADSET_EVENT is only delivered
              // for explicitly-registered IDs — events from other vendors get dropped.
              for (companyId in companyIds) {
                  addCategory("android.bluetooth.headset.intent.category.companyid.$companyId")
              }
          }
          if (Build.VERSION.SDK_INT >= 33) {
              activity.registerReceiver(btHfpVendorReceiver, filter, Context.RECEIVER_EXPORTED)
          } else {
              @Suppress("UnspecifiedRegisterReceiverFlag")
              activity.registerReceiver(btHfpVendorReceiver, filter)
          }
      }
      nativeDeliverBtHfpVendorSubscribed(pid, session)
  }

  @JvmStatic
  fun bt_hfp_send_vendor_at(pid: Long, session: Int, cmd: String, args: String) {
      nativeDeliverBtHfpError(pid, session, "not_supported_by_android_api")
  }

  @JvmStatic
  fun bt_hfp_start_sco(pid: Long, session: Int) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      val proxy = btHfpProxy ?: run { nativeDeliverBtHfpError(pid, session, "hfp_not_connected"); return }
      try {
          val method = proxy.javaClass.getMethod("startScoUsingVirtualVoiceCall", BluetoothDevice::class.java)
          val ok = method.invoke(proxy, device) as? Boolean ?: false
          if (ok) {
              val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
              am.mode = AudioManager.MODE_IN_COMMUNICATION
              nativeDeliverBtHfpScoStarted(pid, session, device.address)
          } else {
              nativeDeliverBtHfpError(pid, session, "sco_start_failed")
          }
      } catch (e: Exception) {
          nativeDeliverBtHfpError(pid, session, "sco_unavailable")
      }
  }

  @JvmStatic
  fun bt_hfp_stop_sco(pid: Long, session: Int) {
      val activity = activityRef?.get() ?: run { nativeDeliverBtHfpError(pid, session, "no_activity"); return }
      val device = btSessionMap[session] ?: run { nativeDeliverBtHfpError(pid, session, "no_session"); return }
      val proxy = btHfpProxy ?: run { nativeDeliverBtHfpError(pid, session, "hfp_not_connected"); return }
      try {
          val method = proxy.javaClass.getMethod("stopScoUsingVirtualVoiceCall", BluetoothDevice::class.java)
          method.invoke(proxy, device)
          val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
          am.mode = AudioManager.MODE_NORMAL
          nativeDeliverBtHfpScoStopped(pid, session)
      } catch (e: Exception) {
          nativeDeliverBtHfpError(pid, session, "sco_stop_failed")
      }
  }

  // ── SPP profile ────────────────────────────────────────────────────────

  @JvmStatic
  fun bt_spp_connect(pid: Long, json: String) {
      val adapter = btAdapter() ?: run { nativeDeliverBtError(pid, "no_adapter"); return }
      val opts = try { JSONObject(json) } catch (_: Exception) { JSONObject() }
      val mac = opts.optString("address").takeIf { it.isNotEmpty() }
          ?: run { nativeDeliverBtError(pid, "no_address"); return }
      val device = try { adapter.getRemoteDevice(mac) }
                   catch (_: Exception) { nativeDeliverBtError(pid, "invalid_address"); return }
      val uuidStr = opts.optString("uuid").takeIf { it.isNotEmpty() }
      val uuid = try { if (uuidStr != null) UUID.fromString(uuidStr) else SPP_UUID }
                 catch (_: Exception) { SPP_UUID }
      val secure = opts.optBoolean("secure", true)

      val session = btSessionFor(device)
      Thread {
          try {
              try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
              val socket = if (secure) device.createRfcommSocketToServiceRecord(uuid)
                           else device.createInsecureRfcommSocketToServiceRecord(uuid)
              socket.connect()
              btSppSockets[session] = socket
              nativeDeliverBtSppConnected(pid, session, device.address, btSafeName(device))

              val readThread = Thread {
                  val buf = ByteArray(1024)
                  try {
                      val input = socket.inputStream
                      while (!Thread.currentThread().isInterrupted) {
                          val n = input.read(buf)
                          if (n <= 0) break
                          val slice = buf.copyOfRange(0, n)
                          nativeDeliverBtSppData(pid, session, slice)
                      }
                  } catch (_: Exception) {}
                  nativeDeliverBtSppDisconnected(pid, session, "remote")
                  btSppSockets.remove(session)
                  btSppReadThreads.remove(session)
              }
              btSppReadThreads[session] = readThread
              readThread.start()
          } catch (e: SecurityException) {
              nativeDeliverBtSppConnectFailed(pid, mac, "permission_denied")
          } catch (e: Exception) {
              nativeDeliverBtSppConnectFailed(pid, mac, "spp_connect_failed")
          }
      }.start()
  }

  @JvmStatic
  fun bt_spp_write(pid: Long, session: Int, bytes: ByteArray) {
      val socket = btSppSockets[session] ?: run { nativeDeliverBtSppError(pid, session, "no_session"); return }
      Thread {
          try {
              socket.outputStream.write(bytes)
              socket.outputStream.flush()
              nativeDeliverBtSppWritten(pid, session, bytes.size)
          } catch (e: Exception) {
              nativeDeliverBtSppError(pid, session, "spp_write_failed")
          }
      }.start()
  }
}
