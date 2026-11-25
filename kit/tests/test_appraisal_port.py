"""Static appraisal eligibility, payment and reveal checks."""
import hashlib
import itertools
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import export_shop
import maindec as main
from mipsdec import sx16
from test_canonical_start import assert_main_words


class Appraisal(unittest.TestCase):
    def test_eligibility_funds_payment_and_reveal(self):
        image = main.body()
        for start, end, digest in [
            (0x800DBBB0, 0x800DBC64, 'bcf1d9cb0dd3c98660daea20a3eaa17d9bb42843589114bdf168b0f15d34eb52'),
            (0x800DBF08, 0x800DBF38, '206fbff5ab820be2196c8987af5f482ce597cee4f18b4ce61bd3e776140232e0'),
        ]:
            self.assertEqual(hashlib.sha256(image[start - main.MBASE:end - main.MBASE]).hexdigest(), digest)
        assert_main_words({
            # The indexed descriptor and instance status are checked before
            # the signed funds boundary. An accepted slot index is saved at +44.
            0x800DBBB0: (0x00021080, 0x3C018016, 0x24217658, 0x00220821, 0x8C220000, 0,
                         0x9442001C, 0, 0x30427000, 0x10400037, 0, 0x80620002, 0, 0x14400033),
            0x800DBBEC: (0x8C82004C, 0, 0x284201F4, 0x1040000F, 0),
            0x800DBC38: (0xAC850044,),
            0x800DBC50: (0x8C62004C, 0xAC600084, 0x2442FE0C, 0xAC62004C),
            # The selected record changes only its byte +2. The store occurs in
            # the sound call's delay slot, before the external routine.
            0x800DBF08: (0x8CA20044, 0x8E43001C, 0x00021080, 0x24420020, 0x00431021,
                         0x2403FFFF, 0x0C030C41, 0xA0430002),
        })
        threshold = sx16(main.mword(0x800DBBF4))
        fee = -sx16(main.mword(0x800DBC58))
        self.assertEqual((threshold, fee, sx16(main.mword(0x800DBF1C)) & 0xFF), (500, 500, 255))
        mask = main.mword(0x800DBBD0) & 0xFFFF
        expected_appraisable = (114, 115, 120, 170)
        for item, status, money in itertools.product(
            (25, *expected_appraisable), (0, 1, 255), (-1, 0, 499, 500, 501, 999999),
        ):
            pointer = main.mword(0x80167658 + item * 4)
            flags, = struct.unpack_from('<H', image, pointer + 0x1C - main.MBASE)
            admitted = bool(flags & mask) and status == 0 and money >= threshold
            self.assertEqual(admitted, item in expected_appraisable and status == 0 and money >= 500)
            if admitted:
                self.assertEqual(money - fee, {500: 0, 501: 1, 999999: 999499}[money])

    def test_exported_identities_prices_and_fee(self):
        catalog, proof = export_shop.appraisals()
        native_ids = list(range(114, 135)) + [170]
        self.assertEqual([row['native_id'] for row in proof], native_ids)
        self.assertEqual(len(catalog), len(native_ids))
        expected_examples = {114: ('failure_urn', 20), 115: ('octopus_urn', 1000),
                             120: ('celadon_urn', 20000), 170: ('junk', 10)}
        for item, record, witness in zip(native_ids, catalog, proof, strict=True):
            self.assertEqual(record['id'], witness['id'])
            self.assertEqual(record['fee'], 500)
            if item in expected_examples:
                self.assertEqual((record['id'], record['price']), expected_examples[item])


if __name__ == '__main__':
    unittest.main()
