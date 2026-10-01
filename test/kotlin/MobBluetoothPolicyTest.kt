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
    "name_advert_rename_awaits_the_new_name" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(AdvertName("Midi", false), g.prepareAdvert("Moto", "Midi", a.setName), "rename")
        expect(listOf("Midi"), a.calls, "renamed")
    },
    "name_advert_refused_rename_awaits_nothing" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter(accept = false)
        expect(AdvertName(null, false), g.prepareAdvert("Moto", "Midi", a.setName), "refused")
    },
    "name_advert_without_a_name_on_a_settled_adapter_awaits_nothing" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        expect(AdvertName(null, false), g.prepareAdvert("Moto", null, a.setName), "never renamed")
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.restore(a.setName)
        g.observe("Moto")
        expect(AdvertName(null, false), g.prepareAdvert("Moto", null, a.setName), "restore observed")
        expect(listOf("Midi", "Moto"), a.calls, "no extra setName")
    },
    "name_advert_without_a_name_after_a_named_one_awaits_the_restore" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.observe("Midi")
        // The restore is as async as the rename: the scan response would
        // still pack "Midi" if advertising started now.
        expect(AdvertName("Moto", false), g.prepareAdvert("Midi", null, a.setName), "restore requested now")
        expect(listOf("Midi", "Moto"), a.calls, "restored")
    },
    "name_advert_without_a_name_during_a_pending_restore_awaits_it" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.restore(a.setName) // stop_advertising
        expect(AdvertName("Moto", true), g.prepareAdvert("Midi", null, a.setName), "restore still on its way")
        expect(listOf("Midi", "Moto"), a.calls, "not asked twice")
    },
    "name_advert_without_a_name_awaits_nothing_when_the_restore_is_refused" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        a.accept = false
        expect(AdvertName(null, false), g.prepareAdvert("Midi", null, a.setName), "name stays as it is")
    },
    "name_advert_rename_during_a_pending_restore_is_in_flux" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        g.prepareAdvert("Moto", "Midi", a.setName)
        g.restore(a.setName)
        expect(AdvertName("Other", true), g.prepareAdvert("Midi", "Other", a.setName), "restore unobserved")
        g.restore(a.setName)
        g.observe("Moto")
        expect(AdvertName("Midi", false), g.prepareAdvert("Moto", "Midi", a.setName), "restore observed")
    },
    "adv_start_without_a_name_after_a_named_one_waits_for_the_restore" to {
        val g = AdapterNameGuard()
        val a = FakeAdapter()
        val gate = AdvertStartGate()
        val launched = mutableListOf<String>()
        val named = g.prepareAdvert("Moto", "Midi", a.setName)
        gate.begin("Moto", named.awaiting, named.inFlux) { launched.add("named") }
        g.observe("Midi"); gate.observe("Midi")
        gate.cancel() // teardown before re-arming
        val plain = g.prepareAdvert("Midi", null, a.setName)
        gate.begin("Midi", plain.awaiting, plain.inFlux) { launched.add("plain") }
        expect(listOf("named"), launched, "plain start waits while the stack still says Midi")
        g.observe("Moto"); gate.observe("Moto")
        expect(listOf("named", "plain"), launched, "starts once the own name is back")
    },
    "adv_start_without_a_rename_launches_now" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Moto", null, false) { launched.add(it) }
        expect(listOf(t), launched, "no-name start launches at once")
        expect(false, gate.isWaiting(t), "not waiting")
        expect(true, gate.isCurrent(t), "its outcome is delivered")
    },
    "adv_start_with_the_name_already_carried_launches_now" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Midi", "Midi", false) { launched.add(it) }
        expect(listOf(t), launched, "adapter already reports the name")
    },
    "adv_start_after_a_rename_waits_until_the_name_is_observed" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Moto", "Midi", false) { launched.add(it) }
        expect(emptyList<Int>(), launched, "setName is async: the stack still packs Moto")
        expect(true, gate.isWaiting(t), "waiting for Midi")
        gate.observe("Moto")
        gate.observe(null)
        expect(emptyList<Int>(), launched, "other names don't release it")
        gate.observe("Midi")
        expect(listOf(t), launched, "released by the observed rename")
        gate.observe("Midi")
        expect(false, gate.timeout(t), "timeout after release is a no-op")
        expect(listOf(t), launched, "launched exactly once")
    },
    "adv_start_whose_name_is_never_observed_launches_on_timeout" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Moto", "Midi", false) { launched.add(it) }
        expect(true, gate.timeout(t), "still waiting at the deadline")
        expect(listOf(t), launched, "started anyway")
        gate.observe("Midi")
        expect(false, gate.timeout(t), "second timeout")
        expect(listOf(t), launched, "launched exactly once")
        expect(true, gate.isCurrent(t), "its outcome is delivered")
    },
    "adv_stop_cancels_a_waiting_start" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Moto", "Midi", false) { launched.add(it) }
        gate.cancel()
        gate.observe("Midi")
        expect(false, gate.timeout(t), "its timeout finds nothing to start")
        expect(emptyList<Int>(), launched, "no startAdvertising after stop")
        expect(false, gate.isCurrent(t), "no late event either")
    },
    "adv_stop_makes_a_launched_starts_late_outcome_stale" to {
        val gate = AdvertStartGate()
        val t = gate.begin("Moto", null, false) {}
        gate.cancel()
        expect(false, gate.isCurrent(t), "onStartSuccess after stop is dropped")
    },
    "adv_newer_start_supersedes_a_waiting_one" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<String>()
        val a = gate.begin("Moto", "A", false) { launched.add("A") }
        gate.cancel() // the bridge tears down before re-arming
        val b = gate.begin("Moto", "B", false) { launched.add("B") }
        gate.observe("A")
        expect(false, gate.timeout(a), "A's timeout")
        expect(emptyList<String>(), launched, "A never starts")
        gate.observe("B")
        expect(listOf("B"), launched, "B starts once its name lands")
        expect(false, gate.isCurrent(a), "A gets no event")
        expect(true, gate.isCurrent(b), "B's outcome is delivered")
    },
    "adv_name_read_confirms_only_a_settled_rename" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<Int>()
        val t = gate.begin("Moto", "Midi", false) { launched.add(it) }
        gate.recheck(t, "Moto")
        expect(emptyList<Int>(), launched, "still the old name")
        gate.recheck(t, "Midi")
        expect(listOf(t), launched, "getName() reports the new name")

        // With an earlier rename / restore unobserved, getName() may still
        // report an old "Midi" that the stack is about to overwrite.
        val g2 = AdvertStartGate()
        val l2 = mutableListOf<Int>()
        val t2 = g2.begin("Midi", "Midi", true) { l2.add(it) }
        expect(emptyList<Int>(), l2, "an in-flux name doesn't count as carried")
        g2.recheck(t2, "Midi")
        expect(emptyList<Int>(), l2, "a read can't confirm an in-flux name")
        g2.observe("Moto")
        g2.observe("Midi")
        expect(listOf(t2), l2, "the broadcast sequence can")
    },
    "adv_unobserved_rename_of_a_cancelled_start_unsettles_the_next" to {
        val gate = AdvertStartGate()
        val launched = mutableListOf<String>()
        gate.begin("Moto", "A", false) { launched.add("first") }
        gate.cancel()
        // getName() already reads A but the broadcast hasn't arrived: the
        // stack may still be mid-change, so don't start on the read.
        gate.begin("A", "A", false) { launched.add("second") }
        expect(emptyList<String>(), launched, "waits for the pending rename")
        gate.observe("A")
        expect(listOf("second"), launched, "released by the broadcast")
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
