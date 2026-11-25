"""Static checks of the boot writer and the opening's field and party consumers."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import canonical_start
import area_scene
import item_tables
import character_table
import maindec as M
from export_first_room import source
from mipsdec import sx16
from test_character_record_lookups import main_lookup_layout

SLUS_BASE = 0x80010000


def assert_words(image, base, slices):
    for address, words in slices.items():
        assert struct.unpack_from(f'<{len(words)}I', image, address - base) == words, hex(address)


def assert_main_words(slices):
    assert_words(M.body(), M.MBASE, slices)


def boot_seed():
    image = character_table.image()
    assert hashlib.sha256(image[0x7544:0x76C4]).hexdigest() == (
        'd48b86f4ef129c2b958342842f4b831d0ff3faef580f9404d49ae8d5dcf12fc7')
    assert_words(image, SLUS_BASE, {
        # Aligned template pointer takes the four-word copy. The destination and
        # source each advance 16 bytes, including in the branch delay slot.
        0x8001754C: (0x3C07801B, 0x3C068004, 0x24C62FE0, 0x30C20003, 0x10400017, 0x34E78000),
        0x800175BC: (0x24C81D60, 0x8CC20000, 0x8CC30004, 0x8CC40008, 0x8CC5000C, 0xACE20000,
                     0xACE30004, 0xACE40008, 0xACE5000C, 0x24C60010, 0x14C8FFF6, 0x24E70010),
        0x800175EC: (0x3C028004, 0x8C4220C0, 0, 0xA0400002, 0x3C038004, 0x8C6320C0,
                     0x34020009, 0xA0620000, 0x3C038004, 0x8C6320C0, 0x00002021, 0x34020002,
                     0xA0620001, 0x3C038004, 0x8C6320C0, 0x340500FF, 0x34020040, 0xA4620004,
                     0x34020049, 0xA4620006),
        0x8001763C: (0x3C028004, 0x8C4220C0, 0, 0x00441021, 0xA0450028, 0x24840001,
                     0x28820006, 0x1440FFF8),
    })
    assert struct.unpack_from('<I', image, 0x320C0)[0] == 0x801B8000
    template = 0x80042FE0 - SLUS_BASE
    assert template % 16 == 0 and 0x1D60 % 16 == 0
    seed = bytearray(image[template:template + 0x1D60])
    assert len(seed) == 0x1D60
    # A fixed set of writes follows the copy. Party count and order stay in the template.
    seed[:3] = bytes([9, 2, 0])
    struct.pack_into('<HH', seed, 4, 64, 73)
    seed[0x28:0x2E] = b'\xff' * 6
    return seed


class CanonicalStart(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.seed = boot_seed()
        cls.evidence = canonical_start.export()

    def test_initial_party_slot_binds_to_hero_record_and_sprite_resource(self):
        self.assertEqual(list(self.seed[8:14]), [8, 255, 255, 255, 255, 255])
        member, = self.evidence['initial_party']
        slot = self.seed[14]
        native_id = self.seed[8 + slot]
        self.assertEqual((slot, native_id, member['id'], member['name']), (0, 8, 'hero', 'Hero'))
        self.assertEqual(member['native_character_id'], native_id)
        first, end, stride, mask = main_lookup_layout()
        matching = [offset for offset in range(first, end, stride)
                    if struct.unpack_from('<I', self.seed, offset)[0] == (native_id & mask)]
        self.assertEqual(matching, [0x294])
        record = matching[0]
        maximum, current = struct.unpack_from('<HH', self.seed, record + 4)
        self.assertEqual((maximum, current, self.seed[record + 13]), (17, 17, 1))
        self.assertEqual((member['max_hp'], member['hp'], member['level']), (17, 17, 1))
        self.assertEqual(list(member['base_stats'].values()), list(self.seed[record + 16:record + 22]))
        self.assertEqual(member['record_row'], 0)
        assert_main_words({
            # Slot indexes the context table, then GS+8 supplies the record ID.
            0x800C49CC: (0x3C05801B, 0x34A58000, 0x00041080, 0x00451021, 0x3C12801C,
                         0x92528003, 0x8C501B9C),
            0x800C49FC: (0x00852021, 0x80860008, 0x3C03801B, 0x34638294, 0x34040294,
                         0x02008821, 0xAE03001C, 0x00A41821, 0x8C620000, 0,
                         0x14C20003, 0, 0x08031291, 0xAE03001C, 0x24840050,
                         0x28821AF4, 0x1440FFF7, 0x00A41821),
            # Walk character-ID/descriptor pairs until a null descriptor.
            0x800C4B94: (0x3C028017, 0x8C42AB8C, 0, 0x10400014, 0x00001021, 0x3C038017,
                         0x2463AB8C, 0x00002821, 0x3C018017, 0x2421AB88, 0x00250821,
                         0x8C220000, 0, 0x14820004, 0, 0x8C620000, 0x080312FD, 0,
                         0x24630008, 0x8C620000, 0, 0x1440FFF2, 0x24A50008,
                         0x00001021, 0x03E00008, 0),
        })
        pairs = []
        for address in range(0x8016AB88, 0x8016AB88 + 8 * 128, 8):
            ident, descriptor = M.mword(address), M.mword(address + 4)
            if descriptor == 0:
                break
            if ident == native_id:
                pairs.append(descriptor)
        else:
            self.fail('missing character resource terminator')
        descriptor, = pairs
        _, sprite = source('/SHU.BIN')
        self.assertEqual((M.mword(descriptor), M.mword(descriptor + 4)),
                         (sprite['size'], sprite['lba']))
        self.assertEqual(member['sprite_source'], sprite)

    def test_boot_field_descriptor_and_camera_consumers(self):
        image = M.body()
        for start, end, digest in [
                (0x801313E8, 0x80131454, '8c897340c3920f5aaea9b7d08843117a813969bbed040116b0946b3fbd30e0c2'),
                (0x8013175C, 0x8013179C, 'd326cd3eabdb0ec50ac8485c2c7dd429b0a4ef4a4f45251e989c9047c68df43a'),
                (0x801317AC, 0x80131884, '966183508c4db6f35c38bfdd30e8cb92d33d3a09efc21a15e643c0e602ec6f5b'),
        ]:
            self.assertEqual(hashlib.sha256(image[start-M.MBASE:end-M.MBASE]).hexdigest(), digest)
        assert_main_words({
            0x801313FC: (0x94820004, 0, 0xAC620028, 0x3C028001, 0x8C420000, 0x94850006),
            0x80131450: (0xAC65002C,),
            0x80131768: (0x90620028, 0x3C108018, 0x2610BD74, 0xA2020000, 0x9062002C,
                         0x3C018018, 0xA020BD76, 0x3C018018, 0xA020BD77),
            0x80131798: (0xA022BD75,),
            0x801317D8: (0x000528C0, 0x2442FF68, 0x00A22821, 0x3C018018, 0xAC25C008,
                         0x000420C0, 0x2463FF90, 0x00832021, 0x3C018018, 0xAC24C010),
            0x80131800: (0x04A10003, 0, 0x3C018018, 0xAC20C008),
            0x80131828: (0x00021100, 0x2442FEC0, 0x0043182A, 0x10600003, 0, 0x3C018018,
                         0xAC22C008, 0x04810003, 0, 0x3C018018, 0xAC20C010),
            0x80131860: (0x00021100, 0x2442FF10, 0x0043182A, 0x10600003, 0, 0x3C018018,
                         0xAC22C010),
        })
        data, _ = source('/VAA.BIN')
        room = area_scene.room_record(data, self.seed[1])
        section = area_scene.section_off(data, room['section'])
        map_width, map_height = struct.unpack_from('<hh', data, section)
        width = map_width * 16 + sx16(M.mword(0x8013182C))
        height = map_height * 16 + sx16(M.mword(0x80131864))
        self.assertEqual((width, height), (320, 656))
        x_bias, y_bias = (-sx16(M.mword(pc)) for pc in (0x801317DC, 0x801317F0))
        x_edges = (0, 1, 18, 19, 39, 40, 78, 79, 255)
        y_edges = (0, 1, 13, 14, 81, 82, 110, 111, 255)
        starts = [struct.unpack_from('<HH', self.seed, 4)] + [(x, y) for x in x_edges for y in y_edges]
        vectors = []
        for x, y in starts:
            px, py = (x & 255) * 8, (y & 255) * 8
            camera = dict(x=min(max(px - x_bias, 0), width), y=min(max(py - y_bias, 0), height))
            vectors.append(dict(position=dict(x=px, y=py), camera=camera))
        self.assertEqual(vectors[0]['position'], self.evidence['field_entry']['position'])
        self.assertEqual(vectors[0]['camera'], self.evidence['field_entry']['camera'])
        retained = canonical_start.ROOT / 'game/tests/fixtures/opening_camera.json'
        self.assertEqual(len(vectors), 82)
        self.assertEqual(vectors, json.loads(retained.read_text()))

    def test_semantic_startup_inventory_and_room_boundary(self):
        value = canonical_start.runtime()
        self.assertEqual(value, json.loads((canonical_start.ROOT / 'game/assets/opening.json').read_text()))
        record = self.seed[0x294:0x294 + 80]
        hero = value['hero']
        member = hero['member']
        inventory = [slot for slot in member['inventory']['slots'] if slot]
        goods = {row['id']: row for row in item_tables.items()}
        self.assertEqual(len(inventory), record[31])
        equipment = {}
        for i, item in enumerate(inventory):
            ident, flags, uses = struct.unpack_from('<HBB', record, 32 + 4 * i)
            self.assertEqual(item, dict(id=canonical_start.stable_id(goods[ident]['name']), uses=uses))
            if flags:
                equipment[{1:'head', 2:'body', 3:'shield', 4:'accessory_one', 5:'accessory_two'}[flags]] = item['id']
        self.assertEqual(hero['equipped'], equipment)
        self.assertEqual(hero['weapon_level'], record[0x45])
        self.assertEqual(record[0x4C], 0)
        self.assertEqual(member['rune_charges'], list(record[9:13]))
        self.assertEqual(value['rooms'][0]['walkable'][73 * 80 + 64], '1')
        exit, = value['rooms'][0]['exits']
        self.assertEqual(exit, dict(x=448, y=208, w=56, h=8, room='vaa_room_1', spawn_x=40, spawn_y=128))
        self.assertEqual(value['rooms'][1]['walkable'][16 * 80 + 5], '1')
        self.assertEqual([room['draws'] for room in value['rooms']], [[], []])

    def test_complete_boot_writer_and_area_descriptor(self):
        self.assertEqual(list(self.seed[:4]), [9, 2, 0, 1])
        self.assertEqual(struct.unpack_from('<HH', self.seed, 4), (64, 73))
        self.assertEqual(struct.unpack_from('<I', self.seed, 0x1C)[0], self.evidence['money'])
        self.assertEqual(self.evidence['money'], 1500)
        self.assertEqual(self.evidence['party_count'], self.seed[3])
        self.assertEqual(self.evidence['party_slot_order'], [self.seed[14]])
        assert_main_words({
            # The uncached mode-2 path reads region and area, then supplies the
            # selected descriptor and destination 80010000 in the delay slot.
            0x80130F34: (0x10830012, 0, 0x3C028018, 0x8C42DB24, 0xA4A4001C, 0x90430002,
                         0x90420000, 0x00031880, 0x3C018017, 0x2421F67C, 0x00230821, 0x8C230000,
                         0x00021080, 0x00431021, 0x8C440000, 0x0C030BBE, 0x3C058001),
        })
        table = M.mword(0x8016F67C + 4 * self.seed[2])
        descriptor = M.mword(table + 4 * self.seed[0])
        _, origin = source('/VAA.BIN')
        self.assertEqual((M.mword(descriptor), M.mword(descriptor + 4)), (origin['size'], origin['lba']))
        self.assertEqual(self.evidence['provenance']['area'], origin)
        self.assertEqual(self.evidence, json.loads(canonical_start.DEFAULT.read_text()))

    def test_initial_room_entry_array_matches_scanner_layout(self):
        data, _ = source('/VAA.BIN')
        image = M.body()
        self.assertEqual(hashlib.sha256(image[0x8013F1BC-M.MBASE:0x8013F2A4-M.MBASE]).hexdigest(),
                         '4db7aede2434499dc42779af0e3646a822c5b88a69da97f48bfdd93e5e8cb007')
        assert_main_words({
            # lbu room, shift by four, load base/count, then stride 24 on rejection.
            0x8013F1DC: (0x8C430008,),
            0x8013F1F0: (0x90420001, 0, 0x00021100, 0x00431021, 0x8C430000),
            0x8013F214: (0xAC23A120, 0x90420004),
            0x8013F238: (0x0C04F6DB, 0x02602021, 0x304200FF, 0x10400005, 0x26100001),
            0x8013F268: (0x24420018, 0x3C018018, 0xAC22A120, 0x320200FF, 0x0052102B, 0x1440FFEE),
        })
        root = struct.unpack_from('<I', data)[0] - SLUS_BASE
        rooms = struct.unpack_from('<I', data, root + 8)[0] - SLUS_BASE
        offset = rooms + 16 * self.seed[1]
        self.assertEqual(offset, self.evidence['provenance']['room_record'])
        entries = struct.unpack_from('<I', data, offset)[0] - SLUS_BASE
        count = data[offset + 4]
        self.assertEqual(count, 26)
        self.assertEqual(self.evidence['room_entity_count'], count)
        room = area_scene.room_record(data, self.seed[1])
        entities = area_scene.entities(data, room)
        self.assertEqual([entity['offset'] for entity in entities], list(range(entries, entries + count * 24, 24)))
        initializers = []
        for index in range(count):
            entry = entries + index * 24
            if struct.unpack_from('<H', data, entry + 4)[0] & 0x10:
                predicate, stream = struct.unpack_from('<II', data, entry + 16)
                initializers.append(dict(entry=index, event_predicate=predicate - SLUS_BASE,
                                         stream=stream - SLUS_BASE))
        self.assertEqual([row['entry'] for row in initializers], [23, 24])
        self.assertEqual(initializers, self.evidence['initialization_entries'])


if __name__ == '__main__':
    unittest.main()
