"""Bit-exact reference model for the NEXUS-32 direct-form FIR contract.

All input samples and coefficients are raw signed int32 values representing
Q16.16 fixed-point numbers. Python integers are used for exact arithmetic;
explicit checks enforce the RTL's signed 72-bit accumulator range.
"""

from __future__ import annotations

from collections.abc import Sequence

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1
ACC72_MIN = -(1 << 71)
ACC72_MAX = (1 << 71) - 1
FRACTION_BITS = 16
MAX_REFERENCE_TAPS = 32


def _require_int32(value: int, name: str) -> int:
    """Return *value* if it is an integer representable as signed int32."""
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an int, got {type(value).__name__}")
    if value < INT32_MIN or value > INT32_MAX:
        raise ValueError(f"{name}={value} is outside signed int32 range")
    return value


def saturate_int32(value: int) -> int:
    """Saturate an integer to the signed 32-bit range."""
    if value > INT32_MAX:
        return INT32_MAX
    if value < INT32_MIN:
        return INT32_MIN
    return value


def fir_dot_q16_16(window: Sequence[int], coefficients: Sequence[int]) -> int:
    """Compute one FIR output from newest-to-oldest samples.

    ``window[0]`` is the newest/current sample and ``coefficients[0]`` is
    the coefficient applied to it. Inputs are raw signed Q16.16 integers.
    Products are not individually rounded or saturated. Each product is
    accumulated exactly in a signed 72-bit accumulator, then the final sum is
    arithmetic-shifted right by 16 and saturated to int32.
    """
    if len(window) != len(coefficients):
        raise ValueError("window and coefficients must have equal lengths")
    tap_count = len(coefficients)
    if not 1 <= tap_count <= MAX_REFERENCE_TAPS:
        raise ValueError(f"tap count must be between 1 and {MAX_REFERENCE_TAPS}")

    accumulator = 0
    for index, (sample, coefficient) in enumerate(zip(window, coefficients)):
        sample = _require_int32(sample, f"window[{index}]")
        coefficient = _require_int32(coefficient, f"coefficients[{index}]")
        product = sample * coefficient  # Exact signed 32x32 -> 64-bit value.
        # RTL sign-extends each signed product to 72 bits before adding.
        accumulator += product
        if accumulator < ACC72_MIN or accumulator > ACC72_MAX:
            raise OverflowError("signed 72-bit accumulator overflow")

    # Python's right shift of a negative integer rounds toward -infinity,
    # matching a two's-complement arithmetic right shift (>>> 16).
    scaled = accumulator >> FRACTION_BITS
    return saturate_int32(scaled)


def fir_block_q16_16(
    samples: Sequence[int], coefficients: Sequence[int]
) -> list[int]:
    """Process a block with zero history at the block boundary.

    For output index n, the tap window is ``samples[n], samples[n-1], ...``.
    Samples before the start of the block are zero. The coefficient order is
    newest-to-oldest and the same coefficient array is used for all outputs.
    """
    tap_count = len(coefficients)
    if not 1 <= tap_count <= MAX_REFERENCE_TAPS:
        raise ValueError(f"tap count must be between 1 and {MAX_REFERENCE_TAPS}")

    validated_samples = [
        _require_int32(sample, f"samples[{index}]")
        for index, sample in enumerate(samples)
    ]
    validated_coefficients = [
        _require_int32(coefficient, f"coefficients[{index}]")
        for index, coefficient in enumerate(coefficients)
    ]

    outputs: list[int] = []
    for n in range(len(validated_samples)):
        window = [
            validated_samples[n - k] if n - k >= 0 else 0
            for k in range(tap_count)
        ]
        outputs.append(fir_dot_q16_16(window, validated_coefficients))
    return outputs
