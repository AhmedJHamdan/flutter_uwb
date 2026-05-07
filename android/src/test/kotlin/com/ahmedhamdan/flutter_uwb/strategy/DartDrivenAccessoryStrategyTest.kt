package com.ahmedhamdan.flutter_uwb.strategy

import com.ahmedhamdan.flutter_uwb.FiraSessionParams
import kotlin.test.Test
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins the FiRa-params validation contract used by
 * [DartDrivenAccessoryStrategy.completeAccessoryHandshake].
 *
 * The end-to-end "BLE connects → adapter completes → ranging session
 * opens" path is covered by the Phase 5 hardware verification (Galaxy
 * ↔ Qorvo CLI). The android test classpath here intentionally avoids
 * the Flutter framework + Jetpack `UwbManager` runtime, which can't
 * be mocked without a Robolectric/Mockito harness.
 */
class DartDrivenAccessoryStrategyTest {

    private fun validParams(
        slotDurationMs: Long = 2L,
        roleIsController: Boolean = true,
        peerShortAddress: ByteArray = byteArrayOf(0x00, 0x01),
    ) = FiraSessionParams(
        sessionId = 0x1234L,
        channel = 9L,
        preambleIndex = 11L,
        slotDurationMs = slotDurationMs,
        slotsPerRangingRound = 6L,
        rangingIntervalMs = 240L,
        sessionKeyInfo = byteArrayOf(
            0x08, 0x07, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        ),
        peerShortAddress = peerShortAddress,
        roleIsController = roleIsController,
    )

    @Test
    fun validateParams_acceptsCanonicalControllerParams() {
        assertNull(DartDrivenAccessoryStrategy.validateParams(validParams()))
    }

    @Test
    fun validateParams_acceptsSlotDurationOneOrTwoMs() {
        assertNull(DartDrivenAccessoryStrategy.validateParams(validParams(slotDurationMs = 1L)))
        assertNull(DartDrivenAccessoryStrategy.validateParams(validParams(slotDurationMs = 2L)))
    }

    @Test
    fun validateParams_rejectsSlotDurationThreeMsWithDocumentedMessage() {
        // Apple-NI uses 3 ms — Jetpack rejects it; android.ranging support
        // is a follow-up. The error message is part of the public contract
        // (surfaced via `failAccessoryHandshake` to the Dart adapter).
        val msg = DartDrivenAccessoryStrategy.validateParams(
            validParams(slotDurationMs = 3L),
        )
        assertTrue(msg != null && msg.contains("slot duration 3 ms"))
        assertTrue(msg.contains("unsupported"))
    }

    @Test
    fun validateParams_rejectsZeroAndNegativeSlotDuration() {
        val zero = DartDrivenAccessoryStrategy.validateParams(
            validParams(slotDurationMs = 0L),
        )
        val negative = DartDrivenAccessoryStrategy.validateParams(
            validParams(slotDurationMs = -1L),
        )
        assertTrue(zero != null && zero.contains("slot duration"))
        assertTrue(negative != null && negative.contains("slot duration"))
    }

    @Test
    fun validateParams_rejectsControleeRoleInV1() {
        val msg = DartDrivenAccessoryStrategy.validateParams(
            validParams(roleIsController = false),
        )
        assertTrue(msg != null && msg.contains("controlee role"))
    }

    @Test
    fun validateParams_rejectsShortAddressUnderTwoBytes() {
        val empty = DartDrivenAccessoryStrategy.validateParams(
            validParams(peerShortAddress = byteArrayOf()),
        )
        val one = DartDrivenAccessoryStrategy.validateParams(
            validParams(peerShortAddress = byteArrayOf(0x42)),
        )
        assertTrue(empty != null && empty.contains("peerShortAddress"))
        assertTrue(one != null && one.contains("peerShortAddress"))
    }

}
