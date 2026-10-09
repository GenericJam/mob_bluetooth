// Desktop-JVM scenarios for the pure policy at the bottom of
// priv/native/android/MobBluetoothBridge.kt. Compiled together with the bridge
// and run one scenario per JVM by test/mob_bluetooth/android_policy_test.exs:
// `main(arrayOf(name))` exits 0 on pass, 1 with a message on failure.
package io.mob.bluetooth

import kotlin.system.exitProcess

private const val FINE = "android.permission.ACCESS_FINE_LOCATION"
private const val COARSE = "android.permission.ACCESS_COARSE_LOCATION"
private const val CONNECT = "android.permission.BLUETOOTH_CONNECT"
private const val SCAN = "android.permission.BLUETOOTH_SCAN"
private const val ADVERTISE = "android.permission.BLUETOOTH_ADVERTISE"

private fun <T> expect(expected: T, actual: T, what: String) {
    if (expected != actual) throw AssertionError("$what: expected $expected, got $actual")
}

/** Records every name handed to setName; answers with [accept]. */
private class FakeAdapter(var accept: Boolean = true) {
    val calls = mutableListOf<String>()
    val setName: (String) -> Boolean = { n -> calls.add(n); accept }
}

private val scenarios: Map<String, () -> Unit> = mapOf(
    "permissions_api30_and_below_request_fine_location_only" to {
        for (sdk in listOf(26, 29, 30)) {
            for (disavow in listOf(false, true)) {
                expect(listOf(FINE),
                    MobBluetoothPolicy.bluetoothConnectPermissions(sdk, disavow).toList(),
                    "sdk=$sdk disavow=$disavow")
            }
        }
    },
    "permissions_api31_plus_add_location_unless_scan_disavows_it" to {
        for (sdk in listOf(31, 35)) {
            expect(listOf(CONNECT, SCAN, ADVERTISE, FINE, COARSE),
                MobBluetoothPolicy.bluetoothConnectPermissions(sdk, false).toList(), "sdk=$sdk located")
            expect(listOf(CONNECT, SCAN, ADVERTISE),
                MobBluetoothPolicy.bluetoothConnectPermissions(sdk, true).toList(), "sdk=$sdk neverForLocation")
        }
    },
    "discovery_needs_location_except_api31_plus_with_never_for_location" to {
        expect(true, MobBluetoothPolicy.discoveryNeedsLocation(30, true), "api30 ignores the flag")
        expect(true, MobBluetoothPolicy.discoveryNeedsLocation(35, false), "api35 without flag")
        expect(false, MobBluetoothPolicy.discoveryNeedsLocation(35, true), "api35 with flag")
    },
    "discovery_failure_reason_names_the_location_cause" to {
        expect("location_permission_required",
            MobBluetoothPolicy.discoveryStartFailureReason(true, false, true), "no grant")
        expect("location_permission_required",
            MobBluetoothPolicy.discoveryStartFailureReason(true, false, false), "no grant beats location off")
        expect("location_disabled",
            MobBluetoothPolicy.discoveryStartFailureReason(true, true, false), "location off")
        expect("start_failed",
            MobBluetoothPolicy.discoveryStartFailureReason(true, true, true), "location fine")
        expect("start_failed",
            MobBluetoothPolicy.discoveryStartFailureReason(false, false, false), "location not needed")
    },
    // MOB-418: android.bluetooth.BluetoothAdapter.STATE_OFF/TURNING_ON/ON/
    // TURNING_OFF are 10/11/12/13 (public API constants).
    "adapter_state_codes_cover_every_adapter_state" to {
        expect(MobBluetoothPolicy.ADAPTER_OFF, MobBluetoothPolicy.adapterStateCode(10), "STATE_OFF")
        expect(MobBluetoothPolicy.ADAPTER_TURNING_ON, MobBluetoothPolicy.adapterStateCode(11), "STATE_TURNING_ON")
        expect(MobBluetoothPolicy.ADAPTER_ON, MobBluetoothPolicy.adapterStateCode(12), "STATE_ON")
        expect(MobBluetoothPolicy.ADAPTER_TURNING_OFF, MobBluetoothPolicy.adapterStateCode(13), "STATE_TURNING_OFF")
        expect(MobBluetoothPolicy.ADAPTER_UNKNOWN, MobBluetoothPolicy.adapterStateCode(14), "BLE-only state")
        val codes = listOf(
            MobBluetoothPolicy.ADAPTER_ON, MobBluetoothPolicy.ADAPTER_OFF,
            MobBluetoothPolicy.ADAPTER_TURNING_ON, MobBluetoothPolicy.ADAPTER_TURNING_OFF,
            MobBluetoothPolicy.ADAPTER_UNSUPPORTED, MobBluetoothPolicy.ADAPTER_UNAUTHORIZED,
            MobBluetoothPolicy.ADAPTER_NO_ACTIVITY, MobBluetoothPolicy.ADAPTER_FAILED,
            MobBluetoothPolicy.ADAPTER_UNKNOWN,
        )
        expect(codes.size, codes.toSet().size, "codes are distinct")
        expect(false, 0 in codes, "0 (a thrown CallStaticIntMethod) is no code")
    },
    "bond_second_caller_joins_and_both_get_the_outcome" to {
        val w = BondWaiters()
        expect(true, w.join("AA", 1), "first caller starts the bond")
        expect(false, w.join("AA", 2), "second caller joins")
        expect(true, w.join("BB", 3), "other device is independent")
        expect(listOf(1L, 2L), w.takeAll("AA"), "both AA callers in call order")
        expect(emptyList<Long>(), w.takeAll("AA"), "taken once")
        expect(true, w.join("AA", 4), "a pair after the outcome starts a fresh bond")
        expect(listOf(3L), w.takeAll("BB"), "BB untouched by AA")
    },
    "bond_drain_all_hands_back_every_waiter_once" to {
        val w = BondWaiters()
        w.join("AA", 1)
        w.join("AA", 2)
        w.join("BB", 3)
        expect(setOf("AA" to 1L, "AA" to 2L, "BB" to 3L), w.drainAll().toSet(), "every waiter drained")
        expect(emptyList<Pair<String, Long>>(), w.drainAll(), "drained once")
        expect(true, w.join("AA", 4), "after a drain the next pair starts a bond")
    },
    "name_rename_then_restore_puts_the_original_back_once" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(true, g.rename("Moto", "Midi", a.setName), "rename applied")
        g.restore(a.setName)
        g.restore(a.setName)
        expect(listOf("Midi", "Moto"), a.calls, "renamed, restored once")
    },
    "name_re_advertise_keeps_the_first_original" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "A", a.setName)
        g.rename("A", "B", a.setName)
        g.restore(a.setName)
        expect(listOf("A", "B", "Moto"), a.calls, "restores the adapter's own name, not A")
    },
    "name_unreadable_adapter_name_is_never_replaced" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(false, g.rename(null, "Midi", a.setName), "no rename without a name to restore")
        g.restore(a.setName)
        expect(emptyList<String>(), a.calls, "adapter untouched")
    },
    "name_refused_rename_saves_nothing" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter(accept = false)
        expect(false, g.rename("Moto", "Midi", a.setName), "rename refused")
        a.accept = true
        g.restore(a.setName)
        expect(listOf("Midi"), a.calls, "nothing to restore after a refused rename")
    },
    "name_refused_restore_is_retried" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "Midi", a.setName)
        a.accept = false
        g.restore(a.setName)
        a.accept = true
        g.restore(a.setName)
        expect(listOf("Midi", "Moto", "Moto"), a.calls, "second restore retries the original")
    },
    "name_stop_then_start_sees_through_a_pending_restore" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "Midi", a.setName)
        g.restore(a.setName)
        // setName is async: the adapter can still report "Midi" right after.
        g.rename("Midi", "Midi 2", a.setName)
        g.restore(a.setName)
        expect("Moto", a.calls.last(), "original survives a stop -> start race")
    },
    "name_restart_stop_start_before_any_rename_lands_keeps_the_original" to {
        // Review sequence: start A, restart B, stop, start C, with none of
        // the async setName calls landed — the adapter still reports A when
        // C starts. A is ours, not the adapter's own name.
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "A", a.setName)
        g.rename("Moto", "B", a.setName)
        g.restore(a.setName)
        g.rename("A", "C", a.setName)
        g.restore(a.setName)
        expect("Moto", a.calls.last(), "restores the adapter's own name, not the pending A")
    },
    "name_observed_restore_lets_a_later_user_rename_become_the_original" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "Midi", a.setName)
        g.restore(a.setName)
        g.observe("Midi")
        g.observe("Moto")
        // The user renames the phone in Settings while nothing advertises.
        g.rename("Phone", "Midi", a.setName)
        g.restore(a.setName)
        expect("Phone", a.calls.last(), "restores the user's new name")
    },
    "name_observing_another_name_does_not_confirm_a_restore" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.rename("Moto", "Midi", a.setName)
        g.restore(a.setName)
        g.observe("Midi")
        g.rename("Midi", "Midi 2", a.setName)
        g.restore(a.setName)
        expect("Moto", a.calls.last(), "a late echo of our rename is not the original")
    },
    "name_advert_rename_waits_for_its_own_broadcast" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(false, g.prepareAdvert("Moto", "Midi", a.setName), "setName is async: stack still packs Moto")
        expect(listOf("Midi"), a.calls, "renamed")
        g.observe("Moto")
        g.observe(null)
        expect(false, g.settled, "other names don't land it")
        g.observe("Midi")
        expect(true, g.settled, "landed")
    },
    "name_advert_already_carried_or_refused_starts_at_once" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(true, g.prepareAdvert("Midi", "Midi", a.setName), "adapter already named so")
        expect(emptyList<String>(), a.calls, "no setName, so no broadcast to wait for")
        a.accept = false
        expect(true, g.prepareAdvert("Moto", "Midi", a.setName), "refused: name won't change")
    },
    "name_advert_same_name_while_in_flight_waits_without_a_second_setName" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        expect(false, g.prepareAdvert("Moto", "Midi", a.setName), "still on its way")
        expect(listOf("Midi"), a.calls, "headed there already")
        g.observe("Midi")
        expect(true, g.prepareAdvert("Midi", "Midi", a.setName), "landed")
        expect(listOf("Midi"), a.calls, "carried")
    },
    "name_advert_without_a_name_on_the_own_name_starts_at_once" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(true, g.prepareAdvert("Moto", null, a.setName), "never renamed")
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.restore(a.setName)
        g.observe("Midi")
        g.observe("Moto")
        expect(true, g.prepareAdvert("Moto", null, a.setName), "restore landed")
        expect(listOf("Midi", "Moto"), a.calls, "no extra setName")
    },
    "name_advert_without_a_name_after_a_named_one_waits_for_the_restore" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.observe("Midi")
        // The restore is as async as the rename: the scan response would
        // still pack "Midi" if advertising started now.
        expect(false, g.prepareAdvert("Midi", null, a.setName), "restore requested now")
        expect(listOf("Midi", "Moto"), a.calls, "restored")
        g.observe("Moto")
        expect(true, g.settled, "own name back")
    },
    "name_advert_without_a_name_during_a_pending_restore_waits_for_it" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.restore(a.setName) // stop_advertising
        expect(false, g.prepareAdvert("Midi", null, a.setName), "restore still on its way")
        expect(listOf("Midi", "Moto"), a.calls, "not asked twice")
    },
    "name_stale_read_of_the_original_while_in_flight_keeps_it_owned" to {
        // Gate review replay: start A, stop before A lands, start without a
        // name while getName() still reads Moto, A lands, start C (reads A),
        // stop. The read must not release Moto, or C saves A as the original.
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "A", a.setName)
        g.restore(a.setName)
        expect(false, g.prepareAdvert("Moto", null, a.setName), "Moto read while A, Moto are in flight")
        g.observe("A")
        g.prepareAdvert("A", "C", a.setName)
        g.restore(a.setName)
        expect(listOf("A", "Moto", "C", "Moto"), a.calls, "stop restores the adapter's own name")
    },
    "name_stale_broadcast_of_the_same_name_does_not_release_a_later_start" to {
        // start A, stop, start A again before anything lands: the first A's
        // broadcast must not release the third start while Moto and the
        // second A are still to land.
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "A", a.setName)
        g.restore(a.setName)
        expect(false, g.prepareAdvert("Moto", "A", a.setName), "waits")
        expect(listOf("A", "Moto", "A"), a.calls, "renamed again")
        g.observe("A")
        expect(false, g.settled, "the first A's broadcast")
        g.observe("Moto")
        expect(false, g.settled, "the restore's broadcast")
        g.observe("A")
        expect(true, g.settled, "this start's own A")
    },
    "name_broadcast_lands_every_earlier_request" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "A", a.setName)
        g.prepareAdvert("Moto", "B", a.setName)
        g.observe("B") // A's broadcast was missed
        expect(true, g.settled, "B landed, so A did")
        g.restore(a.setName)
        g.observe("Moto")
        expect(true, g.prepareAdvert("Moto", null, a.setName), "own name back and released")
        g.prepareAdvert("Phone", "C", a.setName) // user renamed in Settings
        g.restore(a.setName)
        expect("Phone", a.calls.last(), "the new own name is saved")
    },
    "adv_ready_start_launches_now" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin(true) { launched.add(it) }
        expect(listOf(t), launched, "launched at once")
        expect(false, gate.isWaiting(t), "not waiting")
        expect(true, gate.isCurrent(t), "its outcome is delivered")
    },
    "adv_held_start_launches_once_released" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin(false) { launched.add(it) }
        expect(emptyList<Int>(), launched, "held")
        expect(true, gate.isWaiting(t), "waiting")
        gate.release()
        expect(listOf(t), launched, "released")
        gate.release()
        expect(false, gate.timeout(t), "timeout after release is a no-op")
        expect(listOf(t), launched, "launched exactly once")
    },
    "adv_held_start_launches_on_timeout" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin(false) { launched.add(it) }
        expect(true, gate.timeout(t), "still held at the deadline")
        expect(listOf(t), launched, "started anyway")
        gate.release()
        expect(false, gate.timeout(t), "second timeout")
        expect(listOf(t), launched, "launched exactly once")
        expect(true, gate.isCurrent(t), "its outcome is delivered")
    },
    "adv_stop_cancels_a_held_start" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin(false) { launched.add(it) }
        gate.cancel()
        gate.release()
        expect(false, gate.timeout(t), "its timeout finds nothing to start")
        expect(emptyList<Int>(), launched, "no startAdvertising after stop")
        expect(false, gate.isCurrent(t), "no late event either")
    },
    "adv_stop_makes_a_launched_starts_late_outcome_stale" to {
        val gate = AdvertStartGate()
        val t = gate.begin(true) {}
        gate.cancel()
        expect(false, gate.isCurrent(t), "onStartSuccess after stop is dropped")
    },
    "adv_newer_start_supersedes_a_held_one" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<String>()
        val a = gate.begin(false) { launched.add("A") }
        val b = gate.begin(false) { launched.add("B") }
        expect(false, gate.timeout(a), "A's timeout")
        gate.release()
        expect(listOf("B"), launched, "only B starts")
        expect(false, gate.isCurrent(a), "A gets no event")
        expect(true, gate.isCurrent(b), "B's outcome is delivered")
    },
    "adv_newer_start_that_fails_at_once_retires_a_held_one" to {
        // A newer start that fails (e.g. bad_service_uuid) is a start too:
        // the held A must neither launch nor report after B's failure.
        val gate = AdvertStartGate()
        val events = mutableListOf<String>()
        val a = gate.begin(false) { events.add("A launched") }
        gate.begin(true) { events.add("B failed (A waiting: ${gate.isWaiting(a)})") }
        gate.release()
        expect(false, gate.timeout(a), "A's timeout")
        expect(listOf("B failed (A waiting: false)"), events, "B's failure is the only outcome")
        expect(false, gate.isCurrent(a), "A's late callbacks are dropped")
    },
)

fun main(args: Array<String>) {
    val name = args.firstOrNull()
    val scenario = scenarios[name] ?: run {
        System.err.println("unknown scenario: $name (known: ${scenarios.keys.joinToString()})")
        exitProcess(2)
    }
    try {
        scenario()
    } catch (e: AssertionError) {
        System.err.println("FAIL $name: ${e.message}")
        exitProcess(1)
    }
    println("PASS $name")
}
