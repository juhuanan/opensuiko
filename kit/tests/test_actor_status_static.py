"""Raw actor status-handler and Mosquito script checks; no original execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
from export_unite_programs import compile_operations


class ActorStatus(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw, cls.origin = source('MAIN.EXE')
        cls.base, size = struct.unpack_from('<II', raw, 0x18)
        cls.main = raw[2048:2048+size]
        cls.area, cls.area_origin = source('/A_DATA.BIN')

    def word(self, address):
        return struct.unpack_from('<I', self.main, address-self.base)[0]

    def test_handler_checks_side_turtle_and_opposite_probability_branches(self):
        first, last = 0x800e6ab8, 0x800e6d38
        self.assertEqual(self.word(0x8016babc+40*4), first)
        self.assertEqual(hashlib.sha256(self.main[first-self.base:last-self.base]).hexdigest(),
                         '4c431d4adb9b245748d2810d83f7f9e6eccf1613b4ba87e39512502ca3f5957f')
        pins = {0x800e6afc:0x8c82001c, 0x800e6b08:0x0050102a,
                0x800e6b14:0x0c051f8e, 0x800e6b30:0x34027fff,
                0x800e6b60:0x34020064, 0x800e6b94:0x0052102a,
                0x800e6bc8:0x9043004c, 0x800e6bcc:0x34020019,
                0x800e6bd8:0x0c051f8e, 0x800e6bf4:0x34027fff,
                0x800e6c24:0x34020064, 0x800e6c58:0x0052102a,
                0x800e6cec:0x0c038137, 0x800e6d14:0x24840006}
        for address, word in pins.items():
            self.assertEqual(self.word(address), word, hex(address))
        for address, opcode, destination in ((0x800e6b98,5,0x800e6cf8),
                                              (0x800e6bd0,4,0x800e6cf8),
                                              (0x800e6c5c,4,0x800e6cf4)):
            word = self.word(address)
            self.assertEqual(word >> 26, opcode)
            displacement = struct.unpack('<h',struct.pack('<H',word & 65535))[0]
            self.assertEqual(address+4+4*displacement, destination)

    def test_balloon_selection_hat_guard_and_sleep_setter_are_source_ordered(self):
        block=self.main[0x800e04dc-self.base:0x800e0778-self.base]
        self.assertEqual(hashlib.sha256(block).hexdigest(),
                         '1a9254e29d9a9adce8f9d562361d9724d59425fb508ed1d6dd421682c45f52d7')
        pins={0x800e6c64:0x16220017,0x800e6c7c:0x8c6230b0,
              0x800e6c94:0x8c6230c0,0x800e6cac:0x8c6230d0,
              0x800e6cbc:0x34110003,0x800e6cdc:0x00000000,
              0x800e0690:0x8c420f84,0x800e0698:0x8c43001c,
              0x800e06a0:0x9062001f,0x800e06b0:0x34090003,
              0x800e06b8:0x94620020,0x800e06c8:0x80620022,
              0x800c11c8:0x800e0580,0x800e0598:0x34030001,
              0x800e059c:0xa0430046,0x800e05a4:0x3407000f,
              0x800e0618:0x00852025,0x800e0620:0xa464004a}
        for address,word in pins.items():self.assertEqual(self.word(address),word,hex(address))
        for address,target in ((0x800e6ce0,0x800e6cf8),(0x800e06d0,0x800e0768)):
            word=self.word(address);self.assertEqual(word>>26,5)
            offset=struct.unpack('<h',struct.pack('<H',word&65535))[0]
            self.assertEqual(address+4+4*offset,target)

    def test_enemy_status_operands_compile_from_raw_streams(self):
        from actor_script import OP_LEN_HW
        from export_unite_programs import program_schema
        cases=(('B',0x20f98,2,0x210e0,198,'7df3b9a5082e2fca58dfbfe3827fcdbf40c04c9a014be6ef41c3183465831267','accuracy_reduced',20),
               ('D',0x207e0,2,0x20864,212,'9e65a649b6c417f54a1e91c41e0cb47cd72dc6f7c089f0dc819bbf681a0cb1c1','balloon',30),
               ('G',0x20e40,2,0x21204,204,'aa0f33e0ba7d6319abb52894fe9524fbd66459ab08fbcbd325338dba8deaa038','sleep',10),
               ('H',0x1f6d4,1,0x1f734,120,'d7ad542d481e76fe21be275502d94a0fe1dab1fbc6dcfa57891d9a82915a5f58','sleep',30))
        for region,record,slot,start,size,digest,kind,threshold in cases:
            raw,_=source('/'+region+'_DATA.BIN')
            table=struct.unpack_from('<I',raw,record+40)[0]-0x80080000
            self.assertEqual(struct.unpack_from('<I',raw,table+4*slot)[0]-0x80080000,start)
            self.assertEqual(hashlib.sha256(raw[start:start+size]).hexdigest(),digest)
            cursor=start;operations=[]
            while cursor<start+size:
                opcode=struct.unpack_from('<H',raw,cursor)[0]
                length=1 if opcode in (0,1,2) else OP_LEN_HW[opcode]
                self.assertIsNotNone(length)
                operands=list(struct.unpack_from('<'+'h'*(length-1),raw,cursor+2))
                operations.append(dict(op=opcode,args=operands));cursor+=2*length
            self.assertEqual(cursor,start+size)
            code,blocked,_=compile_operations(operations,'status/'+region.lower())
            self.assertFalse(blocked)
            status=[row['command']['status'] for row in code if 'status' in row.get('command',{})]
            self.assertEqual(status,[dict(kind=kind,threshold_percent=threshold)])
            self.assertEqual(program_schema([dict(instructions=code)]),'suikoden-actor-programs/'+('10' if kind=='accuracy_reduced' else '11'))

    def test_mosquito_recipient_attempt_precedes_first_wait_and_names_its_actual_actor(self):
        raw = self.area
        record = 0x20e34
        self.assertEqual(struct.unpack_from('<I',raw,record+48)[0],0x80080004)
        table = struct.unpack_from('<I',raw,record+40)[0]-0x80080000
        start = struct.unpack_from('<I',raw,table+8)[0]-0x80080000
        self.assertEqual(start,0x20f4c)
        self.assertEqual(hashlib.sha256(raw[start:start+200]).hexdigest(),
                         '456945c099a86ffcfeadbbecc0baf967c019d679b7fa1844ae151333c28df705')
        # Independently walk the first four fixed-size records, excluding producer parsers.
        cursor = start
        operations = []
        for opcode, length in ((34,2),(4,2),(24,7),(40,3)):
            words = struct.unpack_from('<'+'h'*length,raw,cursor)
            self.assertEqual(words[0],opcode)
            operations.append(dict(op=opcode,args=list(words[1:])))
            cursor += 2*length
        self.assertEqual(operations[-1],dict(op=40,args=[0,20]))
        code, blocked, _ = compile_operations(operations+[dict(op=0,args=[])],'melee/mosquito')
        self.assertFalse(blocked)
        self.assertEqual(code[3],dict(command=dict(status=dict(kind='poison',threshold_percent=20))))
        self.assertFalse(any('delay' in row or 'wait' in row for row in code))


if __name__ == '__main__':
    unittest.main()
