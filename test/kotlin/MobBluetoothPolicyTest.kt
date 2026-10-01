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
