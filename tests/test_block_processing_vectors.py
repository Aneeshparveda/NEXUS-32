"""Keep the Batch 3B-3A RTL fixtures tied to the independent Python model."""

import unittest
from pathlib import Path

from golden_model.fir_q16 import fir_block_q16_16


def signed32(word):
    return word - (1 << 32) if word & (1 << 31) else word


class BlockProcessingVectorTests(unittest.TestCase):
    def test_rtl_fixture_matches_golden_model(self):
        fixture = Path(__file__).parent / "rtl" / "block_processing_vectors.mem"
        tokens = " ".join(
            line.split("//", 1)[0] for line in fixture.read_text().splitlines()
        ).split()
        self.assertEqual(len(tokens), 3 * 16)
        self.assertTrue(all(len(token) == 8 for token in tokens))
        words = [signed32(int(token, 16)) for token in tokens]
        for dataset in range(3):
            record = words[dataset * 16 : (dataset + 1) * 16]
            samples, coefficients = record[:4], record[4:8]
            for taps, offset in ((1, 8), (3, 12)):
                # Every M prefix used by the bench has its own zero-history run.
                for count in (1, 2, 4):
                    with self.subTest(dataset=dataset, taps=taps, count=count):
                        self.assertEqual(
                            record[offset : offset + count],
                            fir_block_q16_16(samples[:count], coefficients[:taps]),
                        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
