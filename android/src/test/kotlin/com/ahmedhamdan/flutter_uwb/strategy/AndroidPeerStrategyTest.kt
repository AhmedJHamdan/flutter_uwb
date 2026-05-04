package com.ahmedhamdan.flutter_uwb.strategy

import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbDevice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the androidx.core.uwb 1.0.0-rc01 [RangingResult] subtype surface
 * the [AndroidPeerStrategy] depends on. If a future bump of the library
 * removes [RangingResult.RangingResultInitialized] /
 * [RangingResult.RangingResultFailure] or changes their constructor
 * shape, this test fails first — before the production code stops
 * compiling against an emulator and silently drops the new branches.
 */
class AndroidPeerStrategyTest {

    @Test
    fun rangingResultFailureExposesReasonAndDevice() {
        val device = UwbDevice(UwbAddress(byteArrayOf(0x01, 0x02)))
        val failure = RangingResult.RangingResultFailure(device, /* reason */ 42)
        assertEquals(42, failure.reason)
        assertEquals(device, failure.device)
    }

    @Test
    fun rangingResultInitializedCarriesDevice() {
        val device = UwbDevice(UwbAddress(byteArrayOf(0x03, 0x04)))
        val initialized = RangingResult.RangingResultInitialized(device)
        assertEquals(device, initialized.device)
    }

    @Test
    fun rangingResultSubtypesAreExhaustivelyCovered() {
        // If a future Jetpack UWB rc/stable adds a new RangingResult
        // subclass, this list stops being exhaustive and the test starts
        // returning a value the production strategy doesn't yet handle.
        val device = UwbDevice(UwbAddress(byteArrayOf(0, 0)))
        val all: List<RangingResult> = listOf(
            RangingResult.RangingResultPeerDisconnected(device, 0),
            RangingResult.RangingResultInitialized(device),
            RangingResult.RangingResultFailure(device, 0),
        )
        for (r in all) {
            val handled: Boolean = when (r) {
                is RangingResult.RangingResultPosition -> true
                is RangingResult.RangingResultPeerDisconnected -> true
                is RangingResult.RangingResultInitialized -> true
                is RangingResult.RangingResultFailure -> true
            }
            assertTrue(handled)
        }
    }
}
