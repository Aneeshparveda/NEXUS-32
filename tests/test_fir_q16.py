"""Unit tests for the NEXUS-32 Q16.16 reference model."""

import unittest

from golden_model.fir_q16 import (
    ACC72_MAX,
    INT32_MAX,
    INT32_MIN,
    fir_block_q16_16,
    fir_dot_q16_16,
    saturate_int32,
)

Q = 1 << 16


class SaturationTests(unittest.TestCase):
    def test_saturate_boundaries(self):
        self.assertEqual(saturate_int32(INT32_MAX), INT32_MAX)
        self.assertEqual(saturate_int32(INT32_MIN), INT32_MIN)
        self.assertEqual(saturate_int32(INT32_MAX + 1), INT32_MAX)
        self.assertEqual(saturate_int32(INT32_MIN - 1), INT32_MIN)
        self.assertEqual(saturate_int32(0), 0)


    def test_saturation_exact_boundaries_pass_through(self):
        # T3-18 G1: scaled == INT32_MAX / INT32_MIN exactly must NOT clamp.
        # Guards the Python model only; does not prove RTL behaviour.
        # Note: > vs >= (and < vs <=) in saturate_int32 are extensionally
        # identical — clamping M to M is M — so no output-only test can
        # discriminate that mutant. This guard pins boundary pass-through
        # against boundary-excluding, wrapping, or off-by-one saturations.
        self.assertEqual(fir_dot_q16_16([INT32_MAX], [Q]), INT32_MAX)
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [Q]), INT32_MIN)
        self.assertEqual(fir_dot_q16_16([INT32_MAX - 1], [Q]), INT32_MAX - 1)
        self.assertEqual(fir_dot_q16_16([INT32_MIN + 1], [Q]), INT32_MIN + 1)

    def test_clamp_threshold_accumulator_asymmetry(self):
        # T3-18 G2: saturation is decided after >> 16 with floor semantics,
        # so the accumulator threshold is asymmetric by sign.
        # Guards the Python model only; does not prove RTL behaviour.
        # Positive: acc one below (M+1)<<16 still scales to M, no clamp.
        self.assertEqual(fir_dot_q16_16([INT32_MAX, Q - 1], [Q, 1]), INT32_MAX)
        # Negative: acc one below m<<16 floors to m-1, so it DOES clamp.
        self.assertEqual(fir_dot_q16_16([INT32_MIN, -1], [Q, 1]), INT32_MIN)
        # Control: acc inside the last scaled step above m<<16 stays at m.
        self.assertEqual(fir_dot_q16_16([INT32_MIN, 65535], [Q, 1]), INT32_MIN)


    def test_signed_extreme_sign_combinations(self):
        # T3-18 G3: sign quadrants not covered by existing saturation tests.
        # Guards the Python model only.
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [INT32_MIN]), INT32_MAX)
        self.assertEqual(fir_dot_q16_16([INT32_MAX], [INT32_MIN]), INT32_MIN)
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [-1]), 32768)
        self.assertEqual(fir_dot_q16_16([INT32_MAX], [-1]), -32768)
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [1]), -32768)
        self.assertEqual(fir_dot_q16_16([INT32_MAX], [1]), 32767)
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [Q // 2]), INT32_MIN // 2)


class DotProductTests(unittest.TestCase):
    def test_unity_gain(self):
        self.assertEqual(fir_dot_q16_16([int(1.25 * Q)], [Q]), int(1.25 * Q))

    def test_negative_shift_floors_toward_negative_infinity(self):
        # Raw product is -32768; arithmetic >> 16 must produce -1, not 0.
        self.assertEqual(fir_dot_q16_16([-1], [Q // 2]), -1)

    def test_negative_shift_floors_at_non_multiple(self):
        # Accumulator -65537 >> 16 must floor to -2, not truncate to -1.
        # The exact-multiple case above cannot distinguish floor from truncation.
        self.assertEqual(fir_dot_q16_16([-65537], [1]), -2)

    def test_negative_floor_ladder_and_positive_sub_lsb(self):
        # T3-18 G4: negative-floor ladder, smallest negative accumulator
        # first. Guards the Python model only; does not prove RTL behaviour.
        # -1 is the sharpest case: floor gives -1, truncation gives 0.
        self.assertEqual(fir_dot_q16_16([-1], [1]), -1)
        self.assertEqual(fir_dot_q16_16([-65535], [1]), -1)
        self.assertEqual(fir_dot_q16_16([-65536], [1]), -1)
        self.assertEqual(fir_dot_q16_16([-131072], [1]), -2)
        self.assertEqual(fir_dot_q16_16([65535], [1]), 0)
        self.assertEqual(fir_dot_q16_16([65536], [1]), 1)

    def test_multi_tap_cancellation_floor(self):
        # T3-18 G5: floor applies to the SUMMED accumulator after
        # cancellation between taps, not per product. Guards the Python
        # model only; does not prove RTL behaviour.
        self.assertEqual(fir_dot_q16_16([1, 2], [1, -1]), -1)
        self.assertEqual(fir_dot_q16_16([1, 65538], [1, -1]), -2)
        self.assertEqual(fir_dot_q16_16([1, 65537], [1, -1]), -1)

    def test_all_zero_window_and_coefficients(self):
        # T3-18 G6: zero gain is a distinct contract point — any sum of
        # 0*c or x*0 terms gives acc = 0 -> 0. Guards the Python model
        # only; does not prove RTL behaviour.
        self.assertEqual(fir_dot_q16_16([0, 0, 0], [Q, Q // 2, Q // 4]), 0)
        self.assertEqual(fir_dot_q16_16([Q, 2 * Q, 3 * Q], [0, 0, 0]), 0)
        self.assertEqual(fir_dot_q16_16([0], [0]), 0)

    def test_alternating_sign_dot(self):
        # T3-18 G7: alternating signs — exact cancellation, nonzero
        # result, and extreme alternating values. Guards the Python
        # model only; does not prove RTL behaviour.
        self.assertEqual(fir_dot_q16_16([Q, -Q, Q, -Q], [Q, Q, Q, Q]), 0)
        self.assertEqual(fir_dot_q16_16([Q, -Q, Q], [Q, Q // 2, Q // 4]), 3 * Q // 4)
        self.assertEqual(
            fir_dot_q16_16([INT32_MAX, INT32_MIN, INT32_MAX, INT32_MIN],
                           [Q, Q, Q, Q]), -2)

    def test_tap_count_boundaries_dot(self):
        # T3-18 G8: TAP = 1 (named boundary, empty history) and TAP = 31
        # (one below max). Guards the Python model only; does not prove
        # RTL behaviour.
        self.assertEqual(fir_dot_q16_16([Q], [Q]), Q)
        self.assertEqual(fir_dot_q16_16([Q] * 31, [Q] * 31), 31 * Q)

    def test_rejects_tap_count_63_dot(self):
        # T3-18 G9: tap count 63 is rejected by the dot API (the
        # existing invalid-count test covers 0 and 33 only). Guards
        # the Python model only; does not prove RTL behaviour.
        with self.assertRaises(ValueError):
            fir_dot_q16_16([Q] * 63, [Q] * 63)

    def test_rejects_out_of_range_and_non_integer_inputs(self):
        # T3-18 G10: _require_int32 branches were entirely untested —
        # every prior test passed in-range integers. Guards the Python
        # model only; does not prove RTL behaviour.
        with self.assertRaises(ValueError):
            fir_dot_q16_16([INT32_MAX + 1], [Q])
        with self.assertRaises(ValueError):
            fir_dot_q16_16([Q], [INT32_MIN - 1])
        with self.assertRaises(TypeError):
            fir_dot_q16_16([1.5], [Q])

    def test_positive_saturation_just_above_maximum(self):
        # Scaled result INT32_MAX + 1 must clamp, not wrap or pass through.
        self.assertEqual(fir_dot_q16_16([INT32_MAX, 1], [Q, Q]), INT32_MAX)

    def test_negative_saturation_just_below_minimum(self):
        # Scaled result below INT32_MIN must clamp to INT32_MIN.
        self.assertEqual(fir_dot_q16_16([INT32_MIN, -Q], [Q, Q]), INT32_MIN)

    def test_positive_saturation(self):
        self.assertEqual(fir_dot_q16_16([INT32_MAX], [INT32_MAX]), INT32_MAX)

    def test_negative_saturation(self):
        self.assertEqual(fir_dot_q16_16([INT32_MIN], [INT32_MAX]), INT32_MIN)

    def test_multi_tap_sum_has_one_final_shift(self):
        # 1.0*0.5 + 1.0*0.5 = 1.0 exactly after the one final shift.
        self.assertEqual(fir_dot_q16_16([Q, Q], [Q // 2, Q // 2]), Q)

    def test_maximum_tap_sum_fits_accumulator_contract(self):
        # Exercise the range guard with a large but valid full-width sum.
        result = fir_dot_q16_16([INT32_MAX] * 32, [INT32_MAX] * 32)
        self.assertEqual(result, INT32_MAX)
        self.assertGreater(ACC72_MAX, 32 * INT32_MAX * INT32_MAX)

    def test_rejects_mismatched_window(self):
        with self.assertRaises(ValueError):
            fir_dot_q16_16([Q], [Q, Q])

    def test_rejects_invalid_tap_count(self):
        with self.assertRaises(ValueError):
            fir_dot_q16_16([], [])
        with self.assertRaises(ValueError):
            fir_dot_q16_16([Q] * 33, [Q] * 33)


class BlockTests(unittest.TestCase):
    def test_zero_history_and_impulse_response(self):
        # A unit impulse through [1.0, 0.5, 0.25] gives those coefficients.
        samples = [Q, 0, 0, 0]
        coefficients = [Q, Q // 2, Q // 4]
        self.assertEqual(fir_block_q16_16(samples, coefficients), coefficients + [0])

    def test_simple_two_tap_filter(self):
        # y[n] = x[n] + 0.5*x[n-1], all values exactly representable.
        samples = [Q, 2 * Q, 3 * Q]
        coefficients = [Q, Q // 2]
        self.assertEqual(fir_block_q16_16(samples, coefficients), [Q, 5 * Q // 2, 4 * Q])

    def test_empty_sample_block(self):
        self.assertEqual(fir_block_q16_16([], [Q]), [])

    def test_all_zero_block(self):
        # T3-18 G6: all-zero samples or all-zero coefficients give an
        # all-zero block. Guards the Python model only; does not prove
        # RTL behaviour.
        self.assertEqual(fir_block_q16_16([0] * 5, [Q, Q // 2]), [0] * 5)
        self.assertEqual(fir_block_q16_16([Q, 2 * Q], [0, 0]), [0, 0])

    def test_alternating_sign_block(self):
        # T3-18 G7: alternating-sign block — first output full gain,
        # later outputs alternate in sign. Guards the Python model
        # only; does not prove RTL behaviour.
        outputs = fir_block_q16_16([Q, -Q, Q, -Q, Q, -Q], [Q, Q // 2])
        self.assertEqual(outputs, [Q, -Q // 2, Q // 2, -Q // 2, Q // 2, -Q // 2])

    def test_tap_count_boundaries_block(self):
        # T3-18 G8: TAP = 1 block, TAP = 31 block ramp (first full
        # window at index 30), and blocks shorter than the tap count
        # (zero-history partial window as the whole block, including
        # TAP = 32 with a single sample). Guards the Python model
        # only; does not prove RTL behaviour.
        self.assertEqual(fir_block_q16_16([INT32_MAX, INT32_MIN], [Q]),
                         [INT32_MAX, INT32_MIN])
        outputs = fir_block_q16_16([Q] * 40, [Q] * 31)
        self.assertEqual(len(outputs), 40)
        self.assertEqual(outputs[30], 31 * Q)
        self.assertEqual(fir_block_q16_16([Q], [Q, Q, Q]), [Q])
        self.assertEqual(fir_block_q16_16([Q], [Q] * 32), [Q])

    def test_rejects_tap_count_63_and_zero_block(self):
        # T3-18 G9: tap count 63 and tap count 0 are rejected by the
        # block API (the existing test covers 33 only). Guards the
        # Python model only; does not prove RTL behaviour.
        with self.assertRaises(ValueError):
            fir_block_q16_16([Q], [Q] * 63)
        with self.assertRaises(ValueError):
            fir_block_q16_16([Q], [])

    def test_block_rejects_out_of_range_input(self):
        # T3-18 G10 (block side): out-of-range block samples are
        # rejected, not silently wrapped. Guards the Python model
        # only; does not prove RTL behaviour.
        with self.assertRaises(ValueError):
            fir_block_q16_16([INT32_MAX + 1], [Q])

    def test_rejects_too_many_coefficients(self):
        with self.assertRaises(ValueError):
            fir_block_q16_16([Q], [Q] * 33)

    def test_block_1024_firmware_case_full_vector(self):
        # Mirrors firmware/nexus32_block_1024.S: 1024 samples of +1.0,
        # coefficients [0.5, 0.25, 0.25], zero history at the block boundary.
        # Hand-computed: output[0]=0.5, output[1]=0.75, then steady state
        # 0.5+0.25+0.25=1.0 for every remaining output. Asserting the full
        # vector (not just the 4 values the firmware/bench check) guards
        # against a middle-of-block defect in the Python model; it does
        # not prove RTL/bench behaviour (see S2-1 bench spec, still
        # unvalidated on a sim-capable machine).
        outputs = fir_block_q16_16([Q] * 1024, [Q // 2, Q // 4, Q // 4])
        self.assertEqual(outputs, [Q // 2, 3 * Q // 4] + [Q] * 1022)

    def test_block_1024_tap32_ramp(self):
        # TAP_COUNT=LANES=32 boundary: output[n] = min(n+1, 32) * 1.0 with
        # zero history, ramping for 32 outputs then holding at 32.0.
        outputs = fir_block_q16_16([Q] * 1024, [Q] * 32)
        self.assertEqual(len(outputs), 1024)
        self.assertEqual(outputs[0], Q)
        self.assertEqual(outputs[15], 16 * Q)
        self.assertEqual(outputs[31], 32 * Q)
        self.assertEqual(outputs[512], 32 * Q)
        self.assertEqual(outputs[1023], 32 * Q)


if __name__ == "__main__":
    unittest.main(verbosity=2)
