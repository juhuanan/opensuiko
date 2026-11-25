"""Curated event-VM evidence records."""

EVIDENCE = [
    dict(op=0x06, claim=(
        'opcode 0x06 fills an 8-entry sprite/text upload block: '
        'sprite_upload_type @0x8017A148, sprite_upload_param @0x8017A150 and '
        'sprite_upload_enable @0x8017A158, then sets the 4-frame upload countdown '
        '0x801716B8; consumed by sprite_struct_batch_update @0x8013E450, which draws '
        'each entry and marks the 24-byte descriptor +5 = 2 / 0x8017BD79 = 2 on the '
        'countdown==4 pass.'),
        consumers=[0x8013E450], checks=[
            ('scan_writes', 0x06, 0x80171C29),
            ('scan_twrites', 0x06, 0x8017A148),
            ('scan_twrites', 0x06, 0x8017A150),
            ('scan_twrites', 0x06, 0x8017A158),
            ('scan_writes', 0x06, 0x801716B8),
            ('insn', 0x8013C300, 'sb $v0,0x0($at)'),
            ('insn', 0x8013E4AC, 'lbu $v1,0x0($s2)'),
            ('insn', 0x8013E4BC, 'lbu $v0,0x0($s0)'),
            ('insn', 0x8013E51C, 'lbu $v0,0x16b8($v0)'),
            ('insn', 0x8013E540, 'sb $s4,0x5($a0)'),
            ('insn', 0x8013E560, 'jal 0x8012da8c'),
            ('materializes', 0x8013E480, 0x8017A148),
            ('materializes', 0x8013E488, 0x8017A158),
            ('materializes', 0x8013E490, 0x8017A150),
        ]),
    dict(op=0x07, claim=(
        'opcode 0x07 decodes all 7 arms of the jump table at 0x800C1978: 0 -> the '
        'descriptor state byte +5; 1/+2 -> descriptor +0/+1 then event_record_field_copy '
        '0x8013C750; 3 -> descriptor +0x16; 4 -> a 2-bit value in descriptor +4 selected '
        'by the operand, then +0/+1 and byte_value_dispatch 0x8013C7A4; 5 / 6 -> set / '
        'toggle bit 0x40 of the descriptor object byte +1 (the drawn/enabled bit).'),
        consumers=[0x8012F828, 0x8013C750, 0x8013C7A4], checks=[
            ('scan_calls', 0x07, 0x8012F828),
            ('table', 0x800C1978, [0x8013C9BC, 0x8013C9E0, 0x8013CA10, 0x8013CA40,
                                   0x8013CA64, 0x8013CB44, 0x8013CB50, 0]),
            ('insn', 0x8013C990, 'ori $v0,$zero,0x6'),
            ('insn', 0x8013C9DC, 'sb $v0,0x5($s0)'),
            ('insn', 0x8013CA04, 'sb $v0,0x0($a0)'),
            ('insn', 0x8013CA34, 'sb $v0,0x1($a0)'),
            ('insn', 0x8013CA60, 'sb $v0,0x16($s0)'),
            ('insn', 0x8013CDC4, 'ori $v0,$v0,0x1'),
            ('insn', 0x8013CDD0, 'andi $v0,$v0,0x2'),
            ('insn', 0x8013CDDC, 'andi $v0,$v0,0x1'),
            ('insn', 0x8013CDE8, 'ori $v0,$v0,0x2'),
            ('insn', 0x8013CB2C, 'sb $v0,0x1($s0)'),
            ('insn', 0x8013CB34, 'jal 0x8013c7a4'),
            ('insn', 0x8013CB4C, 'ori $v0,$v0,0x40'),
            ('insn', 0x8013CB58, 'xori $v0,$v0,0x40'),
        ]),
    dict(op=0x08, claim=(
        'opcode 0x08 starts a horizontal camera pan: 0x8017A140 = a tile index into the '
        'per-tile delta tables 0x80171860 (dx) / 0x80171870 (dy) and 0x8017A130 = pos*8 = '
        'a countdown decremented by 2 each frame by scroll_offset_accumulator @0x8013ED6C, '
        'which adds the deltas to camera_scroll_x/y (0x8017C008/0x8017C010) and XORs '
        'event_state_flags bit 0x0004 off when it expires.'),
        consumers=[0x8013ED6C], checks=[
            ('scan_writes', 0x08, 0x8017A130),
            ('scan_writes', 0x08, 0x8017A140),
            ('scan_writes', 0x08, 0x8017C028),
            ('materializes', 0x8013ED6C, 0x8017A130),
            ('materializes', 0x8013ED80, 0x8017A140),
            ('materializes', 0x8013ED88, 0x8017C008),
            ('materializes', 0x8013EDB4, 0x8017C010),
            ('materializes', 0x8013ED94, 0x80171860),
            ('materializes', 0x8013EDA4, 0x80171870),
            ('insn', 0x8013EDC4, 'sh $v0,-0x5ed0($at)'),
            ('insn', 0x8013EDCC, 'addu $v1,$v1,$a1'),
            ('insn', 0x8013EDD8, 'addu $a0,$a0,$a2'),
            ('insn', 0x8013EDF8, 'xori $v0,$v0,0x4'),
        ]),
    dict(op=0x0A, claim=(
        'opcode 0x0A arms a camera timer: 0x8017A138 = v*5, a countdown '
        'decremented by 1 each frame by scroll_offset_accumulator @0x8013ED6C, which XORs '
        'event_state_flags bit 0x0020 off when it reaches zero. Its consumer arm only updates '
        'the countdown and flag.'),
        consumers=[0x8013ED6C], checks=[
            ('scan_writes', 0x0A, 0x8017A138),
            ('scan_writes', 0x0A, 0x8017C028),
            ('materializes', 0x8013EE04, 0x8017A138),
            ('insn', 0x8013EE18, 'addiu $v0,$v1,-0x1'),
            ('insn', 0x8013EE3C, 'xori $v0,$v0,0x20'),
        ]),
    dict(op=0x10, claim=(
        'opcode 0x10 requests scripted Hero alignment. It compares the operand tile with '
        'player_cell_x/y and encodes the horizontal direction (1 = target is to the '
        'right, 3 = to the left) with |dx|, and the vertical direction (0 = up, 2 = down) in '
        '0x8017A168 with |dy| in 0x8017A170; 0x8017A160 is set to 1 as the vertical-pan stage '
        'counter and entity_flag_byte_80171c29 = 1. It then calls the shared upload-block '
        'setter 0x8013D038(direction, distance), which loads sprite upload slot 0 with type '
        '0x80 (special path) and sets the 4-frame countdown 0x801716B8 = 4. Next frame '
        'sprite_struct_batch_update @0x8013E450 runs the special path at 0x8013E4CC: it maps '
        'the direction through the code table 0x80171B88 (0x1000/0x2000/0x4000/0x8000), '
        'stores that code in 0x8017BDCC and calls the direction dispatcher 0x8012C860 '
        '(which switches on code & 0xf000). The staged vertical half is applied from '
        '0x8013E628, which re-enters the same setter with 0x8017A168/0x8017A170.'),
        consumers=[0x8013D038, 0x8013E450, 0x8012C860], checks=[
            ('scan_writes', 0x10, 0x8017A160),
            ('scan_writes', 0x10, 0x8017A168),
            ('scan_writes', 0x10, 0x8017A170),
            ('scan_writes', 0x10, 0x80171C29),
            ('scan_calls', 0x10, 0x8013D038),
            ('insn', 0x8013D0FC, 'sb $v1,-0x5ea0($at)'),
            ('insn', 0x8013D110, 'ori $a3,$zero,0x3'),
            ('insn', 0x8013D124, 'ori $a3,$zero,0x1'),
            ('insn', 0x8013D154, 'sb $zero,-0x5e98($at)'),
            ('insn', 0x8013D16C, 'sb $v1,-0x5e98($at)'),
            ('insn', 0x8013D178, 'sb $v0,-0x5e90($at)'),
            ('insn', 0x8013D180, 'jal 0x8013d038'),
            ('insn', 0x8013D054, 'sb $a3,-0x5eb8($at)'),
            ('insn', 0x8013D05C, 'sb $a0,-0x5eb0($at)'),
            ('insn', 0x8013D064, 'sb $a1,-0x5ea8($at)'),
            ('insn', 0x8013D0AC, 'sb $v0,0x16b8($at)'),
            ('materializes', 0x8013E49C, 0x80171B88),
            ('insn', 0x8013E4F4, 'sw $v0,-0x4234($at)'),
            ('insn', 0x8013E508, 'jal 0x8012c860'),
            ('insn', 0x8013E62C, 'lbu $v1,-0x5ea0($v1)'),
            ('insn', 0x8013E648, 'lbu $a0,-0x5e98($a0)'),
            ('insn', 0x8013E654, 'jal 0x8013d038'),
            ('insn', 0x8012C86C, 'andi $v1,$v0,0xf000'),
        ]),
    dict(op=0x11, claim=(
        'opcode 0x11 is a *parameter* selection, not a callback table: the second operand '
        'indexes the 4-word table at 0x80171B98 (1,3,0,2) and the word is passed to the '
        'fixed routine h2da_flag80_gate_dispatch @0x8013CCF0, which resolves the descriptor '
        'selected by the first operand and applies that 2-bit transition to descriptor +4 '
        '(0: &=2, 1: |=1, 2: &=1, 3: |=2) then rebuilds through byte_value_dispatch '
        '0x8013C7A4. The same routine is used by the text-record renderer @0x8013E9BC.'),
        consumers=[0x8013CCF0, 0x8013C7A4], checks=[
            ('scan_treads', 0x11, 0x80171B98),
            ('scan_calls', 0x11, 0x8013CCF0),
            ('table', 0x80171B98, [1, 3, 0, 2, 0, 2, 1, 3]),
            ('insn', 0x8013CE3C, 'sll $v0,$v0,2'),
            ('insn', 0x8013CE44, 'addiu $at,$at,0x1b98'),
            ('insn', 0x8013CE4C, 'lw $a1,0x0($at)'),
            ('insn', 0x8013CE50, 'jal 0x8013ccf0'),
            ('insn', 0x8013CDC4, 'ori $v0,$v0,0x1'),
            ('insn', 0x8013CDE8, 'ori $v0,$v0,0x2'),
            ('insn', 0x8013CDF0, 'jal 0x8013c7a4'),
            ('insn', 0x8013E9BC, 'jal 0x8013ccf0'),
        ]),
    dict(op=0x21, claim=(
        'opcode 0x21 is a scripted camera push, NOT a flag-record application: operand 1 '
        'indexes five-byte camera-offset records at 0x801718D4 and operand 2 is a '
        'repeat count. The wrapper 0x8013D24C -> flag800_apply_a @0x80140018 stores '
        '(record, repeats) in 0x801718D0/0x801718CD, sets event_state_flags bit 0x1000 and '
        'calls 0x8013FF5C, which adds record[0]/record[1] to player_cell_x/y, loads '
        'the frame count 0x801718CE = record[4] and sets camera_offset_x/y = record[2|3] * '
        'record[4]. The per-frame processor 0x80140068 (called from frame_orchestrator '
        '@0x80141E10) counts down, re-applies while repeats remain and clears bit 0x1000.'),
        consumers=[0x80140018, 0x8013FF5C, 0x80140068, 0x80141E08], checks=[
            ('scan_calls', 0x21, 0x80140018),
            ('insn', 0x80140038, 'sb $a0,0x18cc($at)'),
            ('insn', 0x80140040, 'sb $a1,0x18cd($at)'),
            ('insn', 0x80140044, 'ori $v1,$v1,0x1000'),
            ('insn', 0x8014004C, 'sh $v1,-0x3fd8($at)'),
            ('insn', 0x8013FF6C, 'sll $a0,$v0,2'),
            ('insn', 0x8013FF70, 'addu $a0,$a0,$v0'),
            ('insn', 0x8013FF78, 'addiu $v0,$v0,0x18d4'),
            ('insn', 0x8013FF84, 'sw $a0,0x18d0($at)'),
            ('insn', 0x8013FF98, 'sb $v0,0x0($a1)'),
            ('insn', 0x8013FFB4, 'sb $v0,-0x428b($at)'),
            ('insn', 0x8013FFC4, 'sb $v0,0x18ce($at)'),
            ('insn', 0x8013FFE8, 'sb $v0,-0x428a($at)'),
            ('insn', 0x80140050, 'jal 0x8013ff5c'),
            ('insn', 0x801400A8, 'jal 0x8012ca44'),
            ('insn', 0x80140114, 'addiu $v0,$v0,-0x1'),
            ('insn', 0x80140140, 'xori $v0,$v0,0x1000'),
            ('call', 0x80140068, 0x80141E10),
            ('word', 0x8013F0F8, 0x3042FFFC),
        ]),
    dict(op=0x22, claim=(
        'opcode 0x22 selects one of four arms of the fade-scan control block at '
        'area_state+0x441..+0x44E: 0 -> flag800_clear_all 0x801404B8 (reset, +0x442 = 0x12, '
        'event_state_flags |= 0x800), 1 -> flag800_set_444_1 0x80140860 (+0x444 = 1), '
        '2 -> flag800_set_441_444 0x80140888 with the operand doubled (+0x441 = 1, +0x443 = 0, '
        '+0x444 = 2, +0x44C = 2*v), 3 -> flag800_apply_b 0x8014095C (allocates the 4-byte '
        'step vector at 0x801718FC from +0x448 vs 0xB4). The +0x441 flag is consumed by '
        'text_color_pair_driver @0x80134158 and entity_table_sweep_true @0x80130A48.'),
        consumers=[0x801404B8, 0x80140860, 0x80140888, 0x8014095C, 0x80134158], checks=[
            ('scan_calls', 0x22, 0x801404B8),
            ('scan_calls', 0x22, 0x80140860),
            ('scan_calls', 0x22, 0x80140888),
            ('scan_calls', 0x22, 0x8014095C),
            ('insn', 0x8013D304, 'sll $a0,$a0,1'),
            ('insn', 0x801404DC, 'sb $zero,0x444($v1)'),
            ('insn', 0x801404F0, 'sh $v0,0x44e($v1)'),
            ('insn', 0x801404F4, 'sb $zero,0x443($a0)'),
            ('insn', 0x80140504, 'sb $v0,0x441($v1)'),
            ('insn', 0x80140520, 'sb $v0,0x442($a0)'),
            ('insn', 0x80140884, 'sb $v0,0x444($v1)'),
            ('insn', 0x801408A8, 'sb $v0,0x441($v1)'),
            ('insn', 0x801408E4, 'sh $a0,0x44c($v0)'),
            ('insn', 0x80140984, 'sw $a0,0x18fc($at)'),
            ('insn', 0x80140988, 'sltiu $v1,$v1,0xb4'),
            ('struct_read', 0x8017BE20, 0x441, 0x80134158),
            ('struct_read', 0x8017BE20, 0x441, 0x80130A48),
        ]),
    dict(op=0x24, claim=(
        'opcode 0x24 starts a fade-to-black overlay: area_state+0x4D8 = 1 (enable), '
        '+0x4DC = 0 (level), +0x4DD = 2 (blend), +0x4DE = 0x0A (slot), event_state_flags |= '
        '0x10. field_update_driver @0x80131C08 draws the 320x240 quad with +0x4DC as the '
        'RGB level, +0x4DD as the blend mode and +0x4DE as the draw slot; '
        'scroll_offset_accumulator @0x8013ED6C advances +0x4DC by 2*area_state+0x39 and '
        'clears bit 0x10 when it passes 0xFF - 2*step, setting 0x80171594 = 0.'),
        consumers=[0x80131C08, 0x8013ED6C], checks=[
            ('swrite', 0x24, 0x8017BE20, 0x4D8),
            ('swrite', 0x24, 0x8017BE20, 0x4DC),
            ('swrite', 0x24, 0x8017BE20, 0x4DD),
            ('swrite', 0x24, 0x8017BE20, 0x4DE),
            ('scan_writes', 0x24, 0x8017C028),
            ('insn', 0x80139BFC, 'ori $v0,$v0,0x10'),
            ('insn', 0x80139C08, 'sb $zero,0x4dc($v1)'),
            ('insn', 0x80139C18, 'sb $v0,0x4dd($v1)'),
            ('insn', 0x80139C34, 'sh $v0,0x4de($a0)'),
            ('struct_read', 0x8017BE20, 0x4D8, 0x80131C20),
            ('struct_read', 0x8017BE20, 0x4DC, 0x80131C7C),
            ('insn', 0x80131C84, 'sb $v0,0x6($s0)'),
            ('insn', 0x80131CBC, 'lbu $a1,0x4dd($v1)'),
            ('insn', 0x80131CF0, 'lh $a0,0x4de($v0)'),
            ('struct_write', 0x8017BE20, 0x4DC, 0x8013EE7C),
            ('insn', 0x8013EEB8, 'xori $v0,$v0,0x10'),
        ]),
    dict(op=0x25, claim=(
        'opcode 0x25 is the reverse fade (bright -> dark) with the text-colour driver: '
        'area_state+0x4D8 = 1, +0x4DC = 0xFF, +0x4DD = 2, +0x4DE = 0x0A (delay slot), '
        '0x80171594 = 0x80, text_color_pair_driver(0x80133F50), event_state_flags |= 0x40. '
        'The +0x40 arm of scroll_offset_accumulator @0x8013EEDC decrements +0x4DC by '
        '2*area_state+0x39, and on completion sets +0x4DC = 0, 0x80171594 = 0x80 and clears '
        'area_state+0x4D8.'),
        consumers=[0x80131C08, 0x80133F50, 0x8013ED6C], checks=[
            ('swrite', 0x25, 0x8017BE20, 0x4D8),
            ('swrite', 0x25, 0x8017BE20, 0x4DC),
            ('swrite', 0x25, 0x8017BE20, 0x4DD),
            ('swrite', 0x25, 0x8017BE20, 0x4DE),
            ('scan_writes', 0x25, 0x80171594),
            ('scan_calls', 0x25, 0x80133F50),
            ('insn', 0x80139C50, 'ori $v0,$v0,0x40'),
            ('insn', 0x80139C60, 'sb $v0,0x4dc($v1)'),
            ('insn', 0x80139C70, 'sb $v0,0x4dd($v1)'),
            ('insn', 0x80139C8C, 'sw $v0,0x1594($at)'),
            ('insn', 0x80139C94, 'jal 0x80133f50'),
            ('insn', 0x80139C98, 'sh $v0,0x4de($a0)'),
            ('insn', 0x8013EEFC, 'subu $v1,$v1,$v0'),
            ('insn', 0x8013EF34, 'xori $v0,$v0,0x40'),
            ('insn', 0x8013EF5C, 'sw $zero,0x4d8($v1)'),
        ]),
    dict(op=0x2A, claim=(
        'opcode 0x2A starts a fade-to-black overlay with blend mode 1: area_state+0x4D8 = 1, '
        '+0x4DC = 0, +0x4DD = 1, +0x4DE = 0x0A, event_state_flags |= 0x80; the +0x80 arm of '
        'scroll_offset_accumulator @0x8013EF60 drives +0x4DC up by 2*area_state+0x39 and on '
        'completion sets +0x4DC = 0xFF and 0x80171594 = 0xFF.'),
        consumers=[0x80131C08, 0x8013ED6C], checks=[
            ('swrite', 0x2A, 0x8017BE20, 0x4D8),
            ('swrite', 0x2A, 0x8017BE20, 0x4DC),
            ('swrite', 0x2A, 0x8017BE20, 0x4DD),
            ('swrite', 0x2A, 0x8017BE20, 0x4DE),
            ('scan_writes', 0x2A, 0x8017C028),
            ('insn', 0x80139B60, 'ori $v0,$v0,0x80'),
            ('insn', 0x80139B6C, 'sb $zero,0x4dc($v1)'),
            ('insn', 0x80139B7C, 'sb $v0,0x4dd($v1)'),
            ('insn', 0x80139B98, 'sh $v0,0x4de($a0)'),
            ('insn', 0x8013EFBC, 'xori $v0,$v0,0x80'),
        ]),
    dict(op=0x2B, claim=(
        'opcode 0x2B starts the reverse fade with blend mode 1: area_state+0x4D8 = 1, '
        '+0x4DC = 0xFF, +0x4DD = 1, +0x4DE = 0x0A, event_state_flags |= 0x100; the +0x100 arm '
        'of scroll_offset_accumulator @0x8013EFE0 drives +0x4DC down and clears the overlay '
        'when it reaches zero.'),
        consumers=[0x80131C08, 0x8013ED6C], checks=[
            ('swrite', 0x2B, 0x8017BE20, 0x4D8),
            ('swrite', 0x2B, 0x8017BE20, 0x4DC),
            ('swrite', 0x2B, 0x8017BE20, 0x4DD),
            ('swrite', 0x2B, 0x8017BE20, 0x4DE),
            ('scan_writes', 0x2B, 0x8017C028),
            ('insn', 0x80139BAC, 'ori $v0,$v0,0x100'),
            ('insn', 0x80139BBC, 'sb $v0,0x4dc($v1)'),
            ('insn', 0x80139BCC, 'sb $v0,0x4dd($v1)'),
            ('insn', 0x80139BE8, 'sh $v0,0x4de($a0)'),
            ('insn', 0x8013EFE0, 'andi $v0,$v1,0x100'),
        ]),
    dict(op=0x32, claim=(
        'opcode 0x32 allocates a 12-byte draw record (malloc 0xC) and stores its *pointer* '
        'into the array of pointers at 0x8017DAA8[event_text_queue_count] (stride 4, not a '
        '12-byte array), then fast-forwards the stream cursor to the next 0x05 text-pause '
        'byte. Record layout: +0 selector byte, +4 source cursor, +8 countdown, +0xA height '
        '(descriptor +5), +0xB flags. The per-frame consumer is sprite_slot_array_update '
        '@0x8013E7E0 (called from frame_update_driver @0x8013F110).'),
        consumers=[0x8013E7E0, 0x8013F110], checks=[
            ('scan_twrites', 0x32, 0x8017DAA8),
            ('scan_calls', 0x32, 0x800C2D30),
            ('insn', 0x8013C3FC, 'ori $a0,$zero,0xc'),
            ('insn', 0x8013C40C, 'sll $v1,$v1,2'),
            ('insn', 0x8013C414, 'addiu $at,$at,-0x2558'),
            ('insn', 0x8013C41C, 'sw $v0,0x0($at)'),
            ('insn', 0x8013C420, 'sb $s0,0x0($a2)'),
            ('insn', 0x8013C430, 'sw $v0,0x4($a2)'),
            ('insn', 0x8013C494, 'sb $zero,0x8($a2)'),
            ('insn', 0x8013C4A4, 'sb $v0,0xa($a2)'),
            ('insn', 0x8013C4B0, 'sb $zero,0xb($a2)'),
            ('insn', 0x8013C4C0, 'addiu $v0,$v0,0x1'),
            ('insn', 0x8013C4C8, 'sb $v0,0x16b9($at)'),
            ('materializes', 0x8013E820, 0x8017DAA8),
            ('insn', 0x8013E81C, 'sll $v0,$s3,2'),
            ('insn', 0x8013E82C, 'lw $s0,0x0($at)'),
            ('call', 0x8013E7E0, 0x8013F158),
        ]),
    dict(op=0x36, claim=(
        'opcode 0x36 queues one 12-byte draw record per glyph of obj_array_count, each with '
        'selector 0x40|i (sysfont_desc_table[i]), +4 pointing at the glyph code word from the '
        'per-page table 0x80171A78 selected by *(0x8017BD7C) (20-byte page stride), +0xA = the '
        'descriptor height byte +5 and +0xB = 0; consumed by sprite_slot_array_update '
        '@0x8013E7E0.'),
        consumers=[0x8013E7E0], checks=[
            ('scan_calls', 0x36, 0x8013A808),
            ('scan_treads', 0x36, 0x80171A78),
            ('scan_twrites', 0x36, 0x8017DAA8),
            ('insn', 0x8013C50C, 'lbu $v1,0x0($v0)'),
            ('insn', 0x8013C540, 'addiu $v1,$v1,0x1a78'),
            ('insn', 0x8013C56C, 'ori $v1,$s0,0x40'),
            ('insn', 0x8013C594, 'sw $v0,0x4($v1)'),
            ('insn', 0x8013C59C, 'lbu $v0,0x5($s2)'),
            ('insn', 0x8013C5AC, 'sb $v0,0xa($v1)'),
        ]),
    dict(op=0x37, claim=(
        'opcode 0x37 is the initialising twin of 0x36: the glyph codes come from the second '
        'per-page table 0x80171B38, each record gets +0xA = descriptor +5, +0xB = 0, and the '
        'source descriptor +2/+3 are cleared and +5 set to 2 before the record is queued.'),
        consumers=[0x8013E7E0], checks=[
            ('scan_treads', 0x37, 0x80171B38),
            ('scan_twrites', 0x37, 0x8017DAA8),
            ('insn', 0x8013C64C, 'addiu $v1,$v1,0x1b38'),
            ('insn', 0x8013C688, 'sw $v1,0x4($v0)'),
            ('insn', 0x8013C698, 'sb $zero,-0x3($s0)'),
            ('insn', 0x8013C6A8, 'sb $v1,0x0($s0)'),
        ]),
    dict(op=0x40, claim=(
        'opcode 0x40 maintains area_state+0x450, the 8-byte "current tile-entry object" '
        'record {+0, +1 flags, +4 -> tile_entry_table[sel*12]}: 0xFF frees it and clears the '
        'pointer, 0xFE writes two stream bytes into tile_entry_table[idx]+0/+1, 0xFD frees and '
        're-creates the sprite object at entry+8 via obj_alloc_init(area_header+0x20 table), '
        'and any other selector mallocs a record pointing at tile_entry_table[sel]. The '
        'pointer is consumed by sprite_slot_array_update @0x8013EC20 and the entity movement '
        'routines (entity_move_collision_resolve @0x8012DD98, tile_type_update_scan '
        '@0x8012F4D0, entity_coord_stepper @0x8012F988, entity_sprite_position_calc '
        '@0x80130080).'),
        consumers=[0x8013EC20, 0x8012DD98, 0x8012F4D0, 0x80130080], checks=[
            ('swrite', 0x40, 0x8017BE20, 0x450),
            ('sread', 0x40, 0x8017BE20, 0x450),
            ('scan_calls', 0x40, 0x800C2DC0),
            ('scan_calls', 0x40, 0x800C3D8C),
            ('scan_calls', 0x40, 0x800C3D38),
            ('scan_calls', 0x40, 0x800C2D30),
            ('insn', 0x80139420, 'sw $v0,0x450($a1)'),
            ('insn', 0x80139428, 'sw $v1,0x4($v0)'),
            ('struct_read', 0x8017BE20, 0x450, 0x8013EC20),
            ('struct_read', 0x8017BE20, 0x450, 0x8012DD98),
            ('struct_read', 0x8017BE20, 0x450, 0x8012F4D0),
            ('struct_read', 0x8017BE20, 0x450, 0x80130080),
        ]),
    dict(op=0x43, claim=(
        'opcode 0x43 begins a field/menu transition: area_state+0x4E0 = sel (0xFF stored as '
        '0) is the transition state byte that gates field_update_driver @0x801319E4; the '
        'second operand indexes the area struct +0x10 table, whose entry goes to '
        'area_state+0x498 (a one-shot callback that game_state_driver @0x80132C28 jalr\'s then '
        'clears) when sel is 0xFF/0x80, or whose entry+0xC goes to area_state+0x494 (read by '
        'menu_gold_setup_driver @0x8012D028 and the menu gold/transaction wrappers) '
        'otherwise. It then clears entity_collision_enable_flag, sets 0x80171C29 and '
        'game_driver_word_dc4c = 1.'),
        consumers=[0x801319E4, 0x80132C28, 0x8012D028], checks=[
            ('swrite', 0x43, 0x8017BE20, 0x4E0),
            ('swrite', 0x43, 0x8017BE20, 0x498),
            ('swrite', 0x43, 0x8017BE20, 0x494),
            ('scan_writes', 0x43, 0x80171C28),
            ('scan_writes', 0x43, 0x80171C29),
            ('scan_writes', 0x43, 0x8017DC4C),
            ('insn', 0x801397F4, 'sb $v0,0x4e0($v1)'),
            ('insn', 0x80139814, 'sb $zero,0x4e0($a1)'),
            ('insn', 0x80139838, 'lw $v1,0x10($a0)'),
            ('insn', 0x8013983C, 'sll $v0,$v0,2'),
            ('insn', 0x801398C4, 'lw $v0,0xc($v0)'),
            ('insn', 0x801398D4, 'sb $zero,0x1c28($at)'),
            ('insn', 0x801398EC, 'sw $v0,-0x23b4($at)'),
            ('struct_read', 0x8017BE20, 0x4E0, 0x801319E4),
            ('struct_read', 0x8017BE20, 0x498, 0x80132C28),
            ('struct_read', 0x8017BE20, 0x494, 0x8012D028),
            ('insn', 0x80132C40, 'jalr $v0'),
        ]),
    dict(op=0x4A, claim=(
        'CORRECTION: opcode 0x4A is NOT side-effect free. Mode 0 scans the six-byte char-id '
        'list at game_state+0x28 for the first 0xFF and writes the second operand there (the '
        'store is the `jr`-target delay slot at 0x8013928C); any other mode scans for the '
        'first slot equal to the operand and writes 0xFF (0x80139298). The old "the result is '
        'returned in $v0 which the tick discards" reading came from a scanner that could not '
        'follow a pointer global plus an index -- the write is to *(game_state_ptr)+0x28+idx.'),
        consumers=[0x8017DB24], checks=[
            ('sxwrite', 0x4A, 0x8017DB24, 0x28),
            ('insn', 0x8013926C, 'beq $v0,$a2,0x80139288'),
            ('insn', 0x8013928C, 'sb $a3,0x28($a0)'),
            ('insn', 0x80139298, 'sb $v0,0x28($a0)'),
            ('insn', 0x801392B4, 'beq $v0,$a1,0x80139290'),
        ]),
    dict(op=0x4B, claim=(
        'opcode 0x4B applies an id-table / item-count change. op 3 and 4 dispatch straight to '
        'flag_pair_dispatch 0x80138FB0(op); otherwise it looks up two save-buffer id-table '
        'entries with savebuf_id_table_scan @0x8013875C -- that routine scans the 78 (0x4E) '
        'records at game_state+0x294 with a 0x50 stride for a leading word equal to the id and '
        'returns the entry pointer or 0 -- one for operand 2 and one for the fixed id 8. It '
        'then reads the third stream byte on the op 0 arm (or derives the amount from the '
        'entry field +0xD on op 1/2), runs that many battle_tick_counter_advance 0x800E9CC4 '
        'calls and finishes with byte_threshold_classifier 0x800CA60C.'),
        consumers=[0x8013875C, 0x80138FB0, 0x800E9CC4, 0x800CA60C], checks=[
            ('scan_calls', 0x4B, 0x8013875C),
            ('scan_calls', 0x4B, 0x80138FB0),
            ('scan_calls', 0x4B, 0x800E9CC4),
            ('scan_calls', 0x4B, 0x800CA60C),
            ('materializes', 0x8013875C, 0x8017DB24),
            ('insn', 0x8013876C, 'addiu $v1,$v0,0x294'),
            ('insn', 0x80138778, 'beq $v0,$a0,0x80138794'),
            ('insn', 0x80138784, 'slti $v0,$a1,0x4e'),
            ('insn', 0x8013878C, 'addiu $v1,$v1,0x50'),
            ('insn', 0x80139124, 'jal 0x80138fb0'),
            ('insn', 0x80139134, 'jal 0x8013875c'),
            ('insn', 0x8013913C, 'ori $a0,$zero,0x8'),
        ]),
    dict(op=0x4F, claim=(
        'opcode 0x4F installs the area\'s per-frame state handler: sel != 1 loads the word at '
        '0x801716BC + sel*4 and jalr\'s it with the two remaining operand bytes; each of the '
        'six live callbacks (0/2/3/4/5/6 -> 0x8013584C/0x80135AE8/0x80135CF0/0x80135EA8/'
        '0x80136704/0x801369E8, slot 1 is a hole because sel == 1 is the wait arm) allocates '
        'the 0x1670-byte trigger-scan work buffer via 0x801352E8 (setting event_state_flags '
        'bit 0x8000) and stores its handler address into area_state+0x49C: 0x801355EC, '
        '0x80135958, 0x80135B20, 0x80135D20, 0x801365AC and 0x80136754. That pointer is '
        'called every frame by game_state_driver @0x80132C04.'),
        consumers=[0x80132C04], checks=[
            ('scan_treads', 0x4F, 0x801716BC),
            ('table', 0x801716BC, [0x8013584C, 0, 0x80135AE8, 0x80135CF0, 0x80135EA8,
                                   0x80136704, 0x801369E8, 0x10101820]),
            ('insn', 0x80138A60, 'sll $v0,$a2,2'),
            ('insn', 0x80138A6C, 'addiu $at,$at,0x16bc'),
            ('insn', 0x80138A74, 'lw $v0,0x0($at)'),
            ('insn', 0x80138A7C, 'jalr $v0'),
            ('insn', 0x80135854, 'jal 0x801352e8'),
            ('insn', 0x8013585C, 'jal 0x80135388'),
            ('store_const', 0x80135878, 0x801355EC),
            ('store_const', 0x80135B14, 0x80135958),
            ('store_const', 0x80135D14, 0x80135B20),
            ('store_const', 0x80135ECC, 0x80135D20),
            ('store_const', 0x80136728, 0x801365AC),
            ('store_const', 0x80136A0C, 0x80136754),
            ('struct_write', 0x8017BE20, 0x49C, 0x80135878),
            ('insn', 0x80132C04, 'lw $v0,0x49c($v1)'),
            ('insn', 0x80132C14, 'jalr $v0'),
        ]),
    dict(op=0x50, claim=(
        'opcode 0x50 is the inventory operation: op 0 appends the item id with '
        'item_array_append 0x800CA50C, op 1 removes it with item_array_remove 0x800CA55C, and '
        'op 2 resolves the id in the save-buffer id table with savebuf_id_table_scan '
        '@0x8013875C (78 records at game_state+0x294, stride 0x50), then walks the list with '
        'savebuf_id_table_op @0x80138804 -- which reads the entry halfword +0, indexes the '
        'item table at 0x80167658, tests bits 0x7000 of item+0x1C and returns 0 / -1 from the '
        'sign of entry+2 -- and on success increments game_state[0x90 + id] through '
        'dialogue_data_table_read 0x800CA42C.'),
        consumers=[0x800CA50C, 0x800CA55C, 0x8013875C, 0x80138804, 0x800CA42C], checks=[
            ('scan_calls', 0x50, 0x800CA50C),
            ('scan_calls', 0x50, 0x800CA55C),
            ('scan_calls', 0x50, 0x8013875C),
            ('scan_calls', 0x50, 0x80138804),
            ('scan_calls', 0x50, 0x800CA42C),
            ('insn', 0x80138918, 'jal 0x800ca50c'),
            ('insn', 0x80138940, 'jal 0x800ca55c'),
            ('insn', 0x80138964, 'jal 0x8013875c'),
            ('insn', 0x8013880C, 'sll $v0,$v0,2'),
            ('materializes', 0x80138810, 0x80167658),
            ('insn', 0x80138824, 'lhu $v0,0x1c($v0)'),
            ('insn', 0x8013882C, 'andi $v0,$v0,0x7000'),
            ('insn', 0x80138838, 'lb $v0,0x2($a0)'),
        ]),
    dict(op=0x51, claim=(
        'opcode 0x51 builds a movement/turn command for an area tile descriptor and queues it '
        'as a draw record. The per-direction byte tables are 0x801716DC (dx, signed) and '
        '0x801716E0 (dy, signed), indexed by the second operand; the target is '
        'player_cell_x/y + (dx, dy). The selected 24-byte descriptor '
        '(area_tile_desc_table + tile*24) supplies the current coordinates at +0/+1, and the '
        'routine writes a 4-byte command block into area_state+0xBC terminated by 0x05: '
        '+0xBC = 1 when the descriptor X is left of the target, 3 when right, else 0; '
        '+0xBD = |dx|; +0xBE = 0 when the descriptor Y is above the target, 2 when below; '
        '+0xBF = |dy|; +0xC0 = 0x05. The queued 12-byte record (malloc 0xC into the pointer '
        'array 0x8017DAA8[count++]) has selector +0 = tile and +4 = area_state+0xBC, so the '
        'record renderer sprite_slot_array_update @0x8013E7E0 reads the command from that '
        'buffer. The same area_state+0xBC buffer is the destination of '
        'partystruct_text_copy_dispatch @0x8013B7BC.'),
        consumers=[0x8013E7E0, 0x8013B7A0], checks=[
            ('scan_writes', 0x51, 0x801716B9),
            ('scan_twrites', 0x51, 0x8017DAA8),
            ('scan_calls', 0x51, 0x800C2D30),
            ('bytes', 0x801716DC, [0x00, 0x02, 0x00, 0xFE, 0xFE, 0x00, 0x02, 0x00]),
            ('bytes', 0x801716E0, [0xFE, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ('materializes', 0x8013CEC4, 0x801716DC),
            ('materializes', 0x8013CEDC, 0x801716E0),
            ('insn', 0x8013CEF0, 'addu $s2,$a3,$a1'),
            ('insn', 0x8013CEF4, 'addu $v0,$v0,$a0'),
            ('insn', 0x8013CF24, 'sb $s0,0x0($a3)'),
            ('insn', 0x8013CF4C, 'sb $v0,0xbc($a0)'),
            ('insn', 0x8013CF6C, 'sb $v0,0xbc($a0)'),
            ('insn', 0x8013CF7C, 'sb $v0,0xbd($a0)'),
            ('insn', 0x8013CFD0, 'sb $v0,0x0($v1)'),
            ('insn', 0x8013CFE0, 'addiu $v0,$v0,0xbc'),
            ('insn', 0x8013CFE4, 'sw $v0,0x4($a3)'),
            ('insn', 0x8013B7BC, 'addiu $v1,$v0,0xbc'),
            ('materializes', 0x8013E820, 0x8017DAA8),
        ]),
    # ------------------------------------------------------------------
    # 2026-10-07 second pass: the 11 partial opcodes.
    # 0x05, 0x2C, 0x3A, 0x3F, 0x49, 0x4C, 0x4D closed.
    # ------------------------------------------------------------------
    dict(op=0x05, claim=(
        'opcode 0x05 is the two-arm dialogue-box driver on dialogue_box_state '
        '0x8017C018 and the box sprite handle 0x8017BFDC. The closed arm stores the '
        'style byte back with bit 0x80 set and allocates the quad via '
        'ui_quad_elem_alloc(dialogue_word_dbc4, 0, style, 0x1E); the open arm sets '
        'state = (operand1 & 0x7F) + operand2, branch-gates on pad_pressed_edge & 0x5041 '
        '(0x1000 = triangle steps down, 0x4000 = R2 steps up) and either rebuilds the '
        'quad with sprite_quad_packet_build or clears object byte +1 bit 0 and frees the '
        'sprite. The consumer is sprite_manager_tick @0x8013E28C (same state byte, calls '
        'sprite_render_dispatch @0x80144B60 with 0x8017BFDC) and that renderer bails out '
        'unless object byte +1 has bit 0 - the shared glyph draw flag.'),
        consumers=[0x80144B60], checks=[
            ('scan_reads', 0x05, 0x8017C018),
            ('scan_writes', 0x05, 0x8017C018),
            ('scan_writes', 0x05, 0x8017BFDC),
            ('scan_reads', 0x05, 0x8017BE4C),
            ('scan_calls', 0x05, 0x801441B0),
            ('scan_calls', 0x05, 0x80144620),
            ('scan_calls', 0x05, 0x80144C24),
            ('insn', 0x8013BCF0, 'lbu $v1,-0x3fe8($v1)'),
            ('insn', 0x8013BD2C, 'sb $v1,-0x3fe8($at)'),
            ('insn', 0x8013BDE0, 'andi $v1,$v1,0x5041'),
            ('insn', 0x8013BDE8, 'beq $v1,$v0,0x8013be28'),
            ('insn', 0x8013BF5C, 'sb $a1,-0x4294($at)'),
            ('insn', 0x8013BF68, 'andi $v0,$v0,0xfe'),
            ('insn', 0x8013BF6C, 'sb $v0,0x1($a0)'),
            ('word', 0x8013BEB0, 0x90E7C018),
            ('word', 0x8013BEAC, 0x3C078018),
            ('insn', 0x8013E290, 'lbu $v1,-0x3fe8($v1)'),
            ('insn', 0x8013E2A8, 'jal 0x80144b60'),
            ('insn', 0x80144B94, 'lbu $v1,0x1($s0)'),
            ('insn', 0x80144B9C, 'andi $v0,$v1,0x1'),
            ('insn', 0x80144BA0, 'beq $v0,$zero,0x80144c14'),
        ]),
    dict(op=0x2C, claim=(
        'opcode 0x2C re-uploads every sprite palette into CLUT bank 0 and advances the '
        'VRAM target. The mislabelled callee 0x80133698 (called as '
        '0x80133698(area_header, 0, 1)) is the 256-entry palette uploader: it walks the '
        'area_header+0x5 palette count and reads the 256 RGB555 words at '
        '*(area_header+0xC + 4*i), optionally converts them through rgb15_bulk_convert '
        '0x80133618 / rgb15_pixel_convert 0x80133514 and calls vram_upload_strip_a '
        '@0x800C3C5C, which loads RECT(x=0, y=0x1E0 + byte_0x80179038, w=0x100, h=1) via '
        'gpu_loadimage_wrap 0x80148590 and then increments 0x80179038. The handler then '
        'calls sprite_colorize_upload_driver 0x801337B8(ptr, 0, 1) per area sprite '
        'object (area_header+0x20 pointer array, count at area_header+0x1C) and per party '
        'member (game_state[0x1B9C+char*4]+0x28); that driver sets the row counter to '
        'obj+0x7, memmoves 0x200 bytes from obj+0xC and uploads through '
        'vram_upload_strip_b 0x800C3CC8 (same RECT, h=0x20). Finally '
        'set_config_byte3(0x1A) parks the row counter.'),
        consumers=[0x80133698, 0x801337B8, 0x800C3C5C, 0x800C3CC8], checks=[
            ('scan_calls', 0x2C, 0x800C39E4),
            ('scan_calls', 0x2C, 0x800C39F4),
            ('scan_calls', 0x2C, 0x80133698),
            ('scan_calls', 0x2C, 0x801337B8),
            ('insn', 0x80133ABC, 'jal 0x80133698'),
            ('word', 0x800C39E8, 0xA0249038),
            ('word', 0x800C39F8, 0xA0249040),
            ('insn', 0x801336C4, 'lbu $a0,0x7($s5)'),
            ('insn', 0x801336D4, 'lbu $v0,0x5($s5)'),
            ('insn', 0x801336F0, 'lw $v1,0xc($s5)'),
            ('insn', 0x80133728, 'slti $v0,$s2,0x100'),
            ('insn', 0x80133770, 'jal 0x800c3c5c'),
            ('insn', 0x800C3C60, 'ori $v0,$zero,0x100'),
            ('insn', 0x800C3C90, 'addiu $v0,$v0,0x1e0'),
            ('insn', 0x800C3C94, 'jal 0x80148590'),
            ('insn', 0x800C3CA8, 'addiu $v0,$v0,0x1'),
            ('insn', 0x800C3CB0, 'sb $v0,-0x6fc8($at)'),
            ('insn', 0x80133AD0, 'lw $v0,0x1c($v1)'),
            ('insn', 0x80133AE0, 'lw $v0,0x20($v1)'),
            ('insn', 0x80133B1C, 'jal 0x800c39f4'),
            ('insn', 0x800C3CDC, 'sh $v0,0x14($sp)'),
            ('insn', 0x800C3CEC, 'lbu $v0,-0x6fc0($v0)'),
            ('insn', 0x800C3D00, 'addiu $v0,$v0,0x1e0'),
            ('insn', 0x801337F0, 'lbu $v1,0x5($s4)'),
            ('insn', 0x801338DC, 'jal 0x80147da8'),
            ('insn', 0x80133850, 'jal 0x80147da8'),
        ]),
    dict(op=0x3A, claim=(
        'opcode 0x3A stages a descriptor off-map, selected exactly as op 0x07. '
        'When descriptor +8 is non-zero it clears movement increment +5, writes 0xF0 into '
        'descriptor byte +0 for the fixed 0x8017BD74 descriptor (0x8013C8CC) or the '
        'constant 0xFE for the other two arms, and the delay-slot store 0x8013C8D8 writes 0xFE '
        'into descriptor byte +1. These are cell coordinates, read and scaled by8 '
        'at8012FD78/8012FDA0 and8012FDC4/8012FDD8. The separate graphics child is '
        'loaded through descriptor+8 at8012FD30 and remains attached. Its own '
        'byte+1 draw flag is a different field; this slot can be placed again.'),
        consumers=[0x8012FD30, 0x8012FD78, 0x8012FDA0, 0x8012FDC4, 0x8012FDD8], checks=[
            ('scan_reads', 0x3A, 0x8017DAA0),
            ('scan_reads', 0x3A, 0x8017AF94),
            ('materializes', 0x8013C89C, 0x8017BD74),
            ('word', 0x8013C8D8, 0xA0620001),
            ('word', 0x8013C8CC, 0x340200F0),
            ('word', 0x8013C8C8, 0x340200FE),
            ('insn', 0x8013C8C0, 'sb $zero,0x5($v1)'),
            ('insn', 0x8013C8A4, 'lw $v0,0x8($v1)'),
            ('insn', 0x8012FD30, 'lw $s2,0x8($s1)'),
            ('insn', 0x8012FD78, 'lbu $a0,0x0($s1)'),
            ('insn', 0x8012FDA0, 'sll $a0,$a0,3'),
            ('insn', 0x8012FDC4, 'lbu $v0,0x1($s1)'),
            ('insn', 0x8012FDD8, 'sll $v0,$v0,3'),
            ('insn', 0x80144B94, 'lbu $v1,0x1($s0)'),
            ('insn', 0x80144B9C, 'andi $v0,$v1,0x1'),
            ('insn', 0x800C3DB8, 'sb $a1,0x0($a0)'),
            ('insn', 0x800C3DDC, 'sb $v0,0x1($a0)'),
            ('insn', 0x800C3DD4, 'sb $zero,0x2($a0)'),
            ('insn', 0x800C3DD8, 'sb $zero,0x3($a0)'),
        ]),
    dict(op=0x3F, claim=(
        'opcode 0x3F is a per-area tile-entry object synchroniser, not a dialogue query. '
        'The handler reads two operands and calls 0x801384B8(idx, mode), which loads '
        'area_header_ptr and pairs count A = lhu area_header+0x24 / array '
        'area_header+0x28 + A*5 (the packed 5-byte tile records built by '
        'tile_array_build_from_area @0x8012E8F0..0x8012E9BC) against count B = lhu '
        'area_header+0x26 / destination tile_entry_table_ptr 0x8017C038 + B*12. Mode 0 '
        'copies the two header bytes source+0/+1 into destination+0/+1; modes 1..5 free '
        'the destination entry\'s +8 object and re-create it with '
        'obj_alloc_init(*area_header+0x20, source+1 + (mode==3)) with mode 4/5 gated on '
        'the area_state+0x454 counter. The tick discards the return value.'),
        consumers=[0x801384B8], checks=[
            ('scan_calls', 0x3F, 0x801384B8),
            ('insn', 0x8013947C, 'lbu $a0,0x0($v1)'),
            ('insn', 0x8013948C, 'lbu $a1,0x1($v1)'),
            ('insn', 0x80139490, 'jal 0x801384b8'),
            ('insn', 0x801384C8, 'lw $a0,-0x551c($a0)'),
            ('insn', 0x801384F4, 'lhu $v1,0x24($a0)'),
            ('insn', 0x801384FC, 'lw $a1,0x28($a0)'),
            ('insn', 0x80138504, 'addu $v0,$v0,$v1'),
            ('insn', 0x80138508, 'addu $s5,$v0,$a1'),
            ('insn', 0x80138514, 'lui $v1,0x8018'),
            ('insn', 0x80138518, 'lw $v1,-0x3fc8($v1)'),
            ('insn', 0x8013851C, 'lhu $a0,0x26($a0)'),
            ('insn', 0x80138528, 'addu $s4,$v0,$v1'),
            ('insn', 0x8013866C, 'lbu $v0,0x0($s5)'),
            ('insn', 0x80138674, 'sb $v0,0x0($s4)'),
            ('insn', 0x80138678, 'lbu $v0,0x0($s3)'),
            ('insn', 0x80138680, 'sb $v0,0x0($s0)'),
            ('insn', 0x8013858C, 'lw $a0,0x0($v0)'),
            ('insn', 0x80138590, 'jal 0x800c3d38'),
            ('insn', 0x801385F8, 'sw $v0,0x7($s0)'),
            ('insn', 0x80138698, 'lhu $v0,0x26($v0)'),
            ('insn', 0x80138690, 'addiu $s0,$s0,0xc'),
            ('insn', 0x8012E8F0, 'lbu $v0,0x26($v1)'),
            ('insn', 0x8012E8F4, 'lhu $v1,0x24($v1)'),
            ('insn', 0x8012E944, 'lw $a0,0x28($v0)'),
            ('insn', 0x8012E990, 'lbu $v1,0x4($a0)'),
        ]),
    dict(op=0x49, claim=(
        'Opcode49 consumes one selector except FD, which consumes an item id '
        'as a second operand. Selectors belowFD are item ids: they set pending '
        'record index +474, derive use count +477, and call800CA2F0, whose party-order '
        'scan inserts into the first bag with fewer than nine items. UI mode becomes '
        'one on insertion and zero on failure. FE/FF build the item message from '
        'stored index+474 through80167658 and append the source suffix; FF ORs '
        'the stored scenario mask, while FE clears the pending actor pointer, '
        'coordinates and flags. FD scans item entries in active party bags and '
        'calls the indexed removal wrapper800CA408 on a match. The pending actor '
        'record also has a consumer at8012D528 -> '
        '801379AC, which updates/frees its area object and XORs its scenario mask.'),
        consumers=[0x801379AC, 0x80137A40, 0x80137480, 0x80146BB4], checks=[
            ('scan_calls', 0x49, 0x80145194),
            ('scan_calls', 0x49, 0x80146BB4),
            ('scan_calls', 0x49, 0x800CA2F0),
            ('scan_calls', 0x49, 0x800CA408),
            ('sread', 0x49, 0x8017BE20, 0x474),
            ('swrite', 0x49, 0x8017BE20, 0x474),
            ('swrite', 0x49, 0x8017BE20, 0x476),
            ('swrite', 0x49, 0x8017BE20, 0x477),
            ('sread', 0x49, 0x8017BE20, 0x478),
            ('sread', 0x49, 0x8017BE20, 0x479),
            ('swrite', 0x49, 0x8017BE20, 0x47A),
            ('swrite', 0x49, 0x8017BE20, 0x47C),
            ('swrite', 0x49, 0x8017BE20, 0x47E),
            ('swrite', 0x49, 0x8017BE20, 0x480),
            ('insn', 0x8013B9E4, 'lhu $v0,0x474($v0)'),
            ('insn', 0x8013B9EC, 'sll $v0,$v0,2'),
            ('insn', 0x8013B9F4, 'addiu $at,$at,0x7658'),
            ('insn', 0x8013BB48, 'sw $zero,0x480($v0)'),
            ('insn', 0x8013BB4C, 'sh $v1,0x47a($v0)'),
            ('insn', 0x8013BB50, 'sh $v1,0x47c($v0)'),
            ('insn', 0x8013BB58, 'sh $zero,0x47e($v0)'),
            ('insn', 0x8013BB14, 'lbu $v0,0x478($v1)'),
            ('insn', 0x8013BB20, 'lbu $v1,0x479($v1)'),
            ('insn', 0x8013BB30, 'or $v0,$v0,$v1'),
            ('insn', 0x8013BC8C, 'jal 0x800ca2f0'),
            ('insn', 0x8013BCA0, 'sb $zero,-0x4294($at)'),
            ('insn', 0x8012D528, 'lhu $v0,0x474($a0)'),
            ('insn', 0x8012D538, 'jal 0x801379ac'),
            ('insn', 0x801379C0, 'lw $s0,0x480($v1)'),
            ('insn', 0x801379D0, 'lhu $v0,0x47e($v1)'),
            ('insn', 0x801379D8, 'andi $v0,$v0,0x20'),
            ('insn', 0x80137A0C, 'sw $v0,0xc($s0)'),
            ('insn', 0x80137A10, 'lbu $v0,0x47a($v1)'),
            ('insn', 0x80137A18, 'sb $v0,0x0($s0)'),
            ('insn', 0x80137A28, 'lbu $v0,0x47c($v0)'),
            ('insn', 0x80137A30, 'sb $v0,0x1($s0)'),
            ('insn', 0x80137A5C, 'xor $v0,$v0,$v1'),
            ('insn', 0x80137A70, 'sw $zero,0x480($v0)'),
            ('insn', 0x80137374, 'sb $t0,0x478($v0)'),
            ('insn', 0x80137384, 'sb $a3,0x479($v0)'),
            ('insn', 0x80137480, 'sw $t1,0x480($v1)'),
            ('struct_read', 0x8017BE20, 0x480, 0x801379C0),
            ('struct_write', 0x8017BE20, 0x480, 0x80137480),
            ('struct_write', 0x8017BE20, 0x474, 0x8013BC44),
            ('insn', 0x8013B97C, 'addiu $v0,$a0,0x1'),
            ('insn', 0x8013B99C, 'sltiu $v0,$v0,0x2'),
            ('insn', 0x8013B9A0, 'beq $v0,$zero,0x8013bb5c'),
            ('insn', 0x8013BB64, 'bne $v1,$v0,0x8013bc28'),
            ('insn', 0x8013BB6C, 'addiu $v0,$a0,0x2'),
            ('insn', 0x8013BB78, 'lbu $s0,0x1($a0)'),
            ('insn', 0x8013BBC0, 'lw $s3,0x1c($s4)'),
            ('insn', 0x8013BBDC, 'lhu $v0,0x20($s1)'),
            ('insn', 0x8013BBE4, 'bne $v0,$s6,0x8013bbf8'),
            ('insn', 0x8013BBF0, 'jal 0x800ca408'),
            ('insn', 0x800CA414, 'jal 0x800ca42c'),
            ('insn', 0x800CA474, 'sb $v0,0x1f($t0)'),
            ('insn', 0x800CA320, 'lbu $v0,0xe($v0)'),
            ('insn', 0x800CA348, 'sltiu $v0,$v0,0x9'),
            ('insn', 0x800CA354, 'jal 0x800ca38c'),
        ]),
    dict(op=0x4C, claim=(
        'opcode 0x4C is the money/counter op on game_state+0x1C, and its op-3 arm\'s '
        '"digit class" is the digit count handed to num_to_cmd_and_interpret. The handler '
        'adds the five-digit amount a + 100*b + 10000*c (0x80138D98..0x80138DDC) and '
        'computes the class at 0x80138DE0..0x80138EE0: s2 = 5 when amount/0x2710 != 0, '
        'else 4 when /0x3E8 != 0, else 3 when /0x64 != 0, else 2 when /0xA != 0. '
        'num_to_cmd_and_interpret @0x80146FE8 then writes a 5-byte right-aligned decimal '
        'string in the game text encoding at sp+0x12..sp+0x16 (0x80147010 puts 0x45 = '
        '"0" at sp+0x16, 0x80147044 puts 0x45 + remainder at each earlier byte) and '
        'tail-calls bytecode_interpreter(buffer, sp+0x17 - class). op 2 normalises each '
        'party member record through game_state[0x1B9C+id*4]+0x1C and then '
        'byte_threshold_classifier.'),
        consumers=[0x80146FE8, 0x80146BB4], checks=[
            ('scan_calls', 0x4C, 0x80146FE8),
            ('scan_calls', 0x4C, 0x80146BB4),
            ('scan_calls', 0x4C, 0x800CA60C),
            ('insn', 0x80138DE0, 'ori $v0,$zero,0x2710'),
            ('insn', 0x80138E20, 'ori $s2,$zero,0x5'),
            ('insn', 0x80138E24, 'ori $v0,$zero,0x3e8'),
            ('insn', 0x80138E64, 'ori $s2,$zero,0x4'),
            ('insn', 0x80138E98, 'beq $v0,$zero,0x80138ea8'),
            ('insn', 0x80138EA4, 'ori $s2,$zero,0x3'),
            ('insn', 0x80138EE0, 'ori $s2,$zero,0x2'),
            ('insn', 0x80138F38, 'jal 0x80146fe8'),
            ('word', 0x80147010, 0x34020045),
            ('insn', 0x80147014, 'sb $v0,0x16($sp)'),
            ('insn', 0x80147044, 'addiu $v0,$v0,0x45'),
            ('insn', 0x80147048, 'sb $v0,0x0($a1)'),
            ('insn', 0x80147068, 'subu $a1,$a1,$a2'),
            ('insn', 0x80147064, 'jal 0x80146bb4'),
            ('insn', 0x80147028, 'divu $v1,$t0'),
            ('insn', 0x80138D28, 'lhu $v0,0x4($v1)'),
            ('insn', 0x80138D30, 'sh $v0,0x6($v1)'),
            ('insn', 0x80138D3C, 'sh $zero,0x16($v0)'),
            ('insn', 0x80138D44, 'jal 0x800ca60c'),
        ]),
    dict(op=0x4D, claim=(
        'opcode 0x4D changes the variant of one area tile descriptor and rebuilds the '
        'tile object. The handler indexes area_tile_desc_table with tile*24 '
        '(0x80138B04..0x80138B10), loads the descriptor object from +8 (0x80138B50), '
        'waits while the object flag word +4 has bit 0x10000 (0x80138B20 lui 0x1 / '
        '0x80138B34 and), takes the base value from the low nibble of object byte +0 '
        '(0x80138B58 lbu +0 / 0x80138B60 andi 0xF), and applies op 3 = absolute / op 0 = '
        '+1 / op 1 = -1. obj_initializer @0x800C3DAC(object, variant) writes variant to '
        'object byte +0 (0x800C3DB8) and the variant\'s draw byte from the object\'s own '
        '+0x14 table into object byte +1 (0x800C3DDC), then rebuilds flag bits 0 and 16 '
        'of the +4 word. transition_dir_struct_setup @0x801343B4 installs the descriptor '
        '+8 and +0xC objects through struct_byte_set_24.'),
        consumers=[0x800C3DDC, 0x801343B4], checks=[
            ('scan_calls', 0x4D, 0x800C3DAC),
            ('scan_calls', 0x4D, 0x801343B4),
            ('insn', 0x80138B04, 'sll $v0,$v1,1'),
            ('insn', 0x80138B08, 'addu $v0,$v0,$v1'),
            ('insn', 0x80138B0C, 'sll $v0,$v0,3'),
            ('insn', 0x80138B10, 'addu $s1,$v0,$a0'),
            ('insn', 0x80138B34, 'and $v0,$v0,$v1'),
            ('insn', 0x80138B38, 'beq $v0,$zero,0x80138bb0'),
            ('insn', 0x80138B44, 'sw $v0,-0x507c($at)'),
            ('insn', 0x80138B58, 'lbu $v0,0x0($v0)'),
            ('insn', 0x80138B60, 'andi $s0,$v0,0xf'),
            ('insn', 0x80138B90, 'addiu $s0,$s0,0x1'),
            ('insn', 0x80138B94, 'addiu $s0,$s0,-0x1'),
            ('insn', 0x80138B9C, 'jal 0x800c3dac'),
            ('insn', 0x80138BA8, 'jal 0x801343b4'),
            ('insn', 0x800C3DB8, 'sb $a1,0x0($a0)'),
            ('insn', 0x800C3DDC, 'sb $v0,0x1($a0)'),
            ('insn', 0x800C3DFC, 'and $a2,$a2,$v1'),
            ('insn', 0x800C3E0C, 'or $a2,$a2,$v0'),
            ('insn', 0x800C3E10, 'sw $a2,0x4($a0)'),
            ('insn', 0x801343E8, 'jal 0x800c4244'),
            ('insn', 0x801343F8, 'jal 0x800c3dac'),
            ('insn', 0x8013440C, 'jal 0x800c42e8'),
            ('insn', 0x80134440, 'sb $v0,0x19($s1)'),
            ('insn', 0x80134448, 'jal 0x800c42e8'),
        ]),
    dict(op=0x2F, claim=(
        'opcode 0x2F uses a selector and n-1 raw byte labels, n = selector & 0x3F. '
        'T is the first label byte. The loop compares label[i] with T+n, then scans '
        'forward for its first equal byte, storing displacement from base=T+n-1. '
        'The base follows from adding n-1 to the cursor already advanced past '
        'the selector (0x8013A524/28/30). Stack word 0 is explicitly zero. '
        'The selected word is counts[mode] for bit 0x80, or counts[mode-1] '
        'otherwise. Targets are default base or matching label bytes in the arm '
        'bodies, not bytes inside the header. Four disc examples independently '
        'agree, including both mode-numbering forms.'),
        status='proven', consumers=[0x8017BD6C], checks=[
            ('scan_reads', 0x2F, 0x8017BD6C),
            ('insn', 0x8013A4A4, 'andi $t2,$a3,0x80'),
            ('insn', 0x8013A4A8, 'andi $a3,$a3,0x3f'),
            ('insn', 0x8013A4B0, 'addiu $v0,$v1,-0x1'),
            ('insn', 0x8013A4CC, 'subu $v1,$v1,$a2'),
            ('insn', 0x8013A4D0, 'addu $a0,$a0,$v1'),
            ('insn', 0x8013A524, 'addiu $v0,$a3,-0x1'),
            ('insn', 0x8013A4C8, 'lbu $v0,0x0($a0)'),
            ('insn', 0x8013A4D4, 'lbu $v1,0x0($a0)'),
            ('insn', 0x8013A4DC, 'beq $v1,$v0,0x8013a4fc'),
            ('insn', 0x8013A4E8, 'addiu $a0,$a0,0x1'),
            ('insn', 0x8013A4F8, 'addiu $a1,$a1,0x1'),
            ('insn', 0x8013A4FC, 'sw $a1,0x4($t0)'),
            ('insn', 0x8013A520, 'sw $zero,0x0($sp)'),
            ('insn', 0x8013A528, 'addu $v1,$v0,$v1'),
            ('insn', 0x8013A530, 'sw $v1,-0x507c($at)'),
            ('insn', 0x8013A540, 'lbu $v0,-0x4294($v0)'),
            ('insn', 0x8013A550, 'lw $v0,0x0($v0)'),
            ('insn', 0x8013A558, 'addu $v0,$v1,$v0'),
            ('insn', 0x8013A570, 'lw $v0,-0x4($v0)'),
            ('insn', 0x8013A578, 'addu $v0,$v1,$v0'),
            ('insn', 0x8013A580, 'sw $v0,-0x507c($at)'),
            ('insn', 0x8013A584, 'jr $ra'),
        ]),
]


# ---------------------------------------------------------------------------
# Validation helpers used by the self-test and the build gate.
# ---------------------------------------------------------------------------
