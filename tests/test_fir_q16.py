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


class DotProductTests(unittest.TestCase):
    def test_unity_gain(self):
        self.assertEqual(fir_dot_q16_16([int(1.25 * Q)], [Q]), int(1.25 * Q))

    def test_negative_shift_floors_toward_negative_infinity(self):
        # Raw product is -32768; arithmetic >> 16 must produce -1, not 0.
        self.assertEqual(fir_dot_q16_16([-1], [Q // 2]), -1)

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

    def test_rejects_too_many_coefficients(self):
        with self.assertRaises(ValueError):
            fir_block_q16_16([Q], [Q] * 33)


if __name__ == "__main__":
    unittest.main(verbosity=2)
