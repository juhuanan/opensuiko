"""Curated per-opcode event-VM effects."""

EFFECTS = {
    0x00: dict(
        name='event_slot_spawn_text',
        operands=[('idx', 'b'), ('x', 'b'), ('y', 'b'), ('w', 'b'), ('h', 'b')],
        layout='1 byte while slot idx is busy (wait), 5 bytes on the spawn path',
        reads=[0x8017DBB4],
        writes=[0x8017DBB0, 0x8017DBB4, 0x8017DBBC, 0x8017DBC0],
        calls=[0x80145194, 0x8013F6B4, 0x800C4DB4],
        effect='If sprite_slot_flags[idx] (stride 20) is set, rewind one byte and '
               'yield (wait for the slot). Otherwise allocate a sprite-text struct at '
               'screen (x*8-0x96, y*8-0x68) size (w+8, h), store it in '
               'sprite_slot_table[idx], clear that slot\'s flags, clear the text '
               'buffer and issue display command 0x0501 for the new struct.',
        control='rewind'),
    0x01: dict(
        name='event_slot_flag_set',
        operands=[('idx', 'b')],
        reads=[0x8017DBB0],
        writes=[0x8017DBB4, 0x8017DBB5, 0x8017C028],
        calls=[0x80145644],
        effect='sprite_flag_set_state(sprite_slot_table[idx], 0x14); set the slot '
               'state byte sprite_slot_flags[idx] = 2 and sprite_slot_byte_b5[idx] = 0; '
               'raise event_state_flags bit 1 (idx==0) or bit 2 (idx!=0).'),
    0x02: dict(
        name='wait_pad_press',
        operands=[],
        reads=[0x8017BE4C],
        effect='Rewind one byte (re-execute next frame) and, if pad_pressed_edge & 0x65 '
               'is zero, stay rewound: a wait for one of the pad buttons in mask 0x65. '
               'When a button is down the cursor is restored and execution continues.',
        control='rewind'),
    0x03: dict(
        name='inline_wait_read_args',
        operands=[],
        layout='inline: 1 opcode byte, then event_stream_read_args() decides 1-6 more',
        effect='NOT a table handler (table slot 3 is NULL). The tick handles 0x03 '
               'inline: while (event_state_flags & 3) it rewinds and yields; otherwise '
               'it parses a multi-byte operand group with event_stream_read_args '
               '(0x8013BF94), then enters the inline FD exit path, bypassing the handler re-loop test.',
        control='rewind'),
    0x04: dict(
        name='event_text_copy_indirect',
        operands=[('dst', 'b'), ('sel', 'b')],
        layout='2 bytes, or 3 bytes when sel == 0xFF',
        reads=[0x8017A128, 0x80171C14],
        calls=[0x8013B7A0],
        effect='partystruct_text_copy_dispatch(ptr, dst) where ptr is selected by sel: '
               'if sel != 0xFF it is room.text_table[sel], with the current16-byte '
               'room record at [0x8017A128] and its table pointer at record+0x0C; '
               'if sel == 0xFF it reads the word at0x80171C14+4*third_byte. The copy '
               'destination is the byte operand dst.',
        control='next'),
    0x05: dict(
        name='dialogue_box_render',
        operands=[('style', 'b'), ('sel', 'b'), ('completion_skip', 'b')],
        layout='Two bytes read on blocked updates; completion skips a third byte before the next opcode',
        writes=[0x8017C018, 0x8017BFDC],
        reads=[0x8017C018, 0x8017DBC4, 0x8017BFDC, 0x8017BE4C],
        calls=[0x801441B0, 0x80144620, 0x80144C24],
        consumers=[0x80144B60],
        effect='Two-arm dialogue-box driver on dialogue_box_state (0x8017C018) and the '
               'dialogue sprite handle 0x8017BFDC. **Arm A (state == 0xFF, box not yet '
               'built)**: read the style byte, store it back into 0x8017C018 with bit '
               '0x80 set, then ui_quad_elem_alloc(dialogue_word_dbc4, 0, style, 0x1E) '
               'with the stack argument 1 (or 2 when the style had bit 0x80); the '
               'returned handle goes to dialogue_sprite_word_8017bfdc. **Arm B (box '
               'open)**: read operand 1, extract its bit 0x80 into a "changed" flag, '
               'read operand 2, and set the new state = (operand1 & 0x7F) + operand2, '
               'then branch on pad_pressed_edge & 0x5041 - 0x1000 (triangle) steps it '
               'down by 1, 0x4000 (R2) steps it up by 1, 0x01/0x40/0x4000 (up/down/'
               'confirm) take the other arms; the result is written back to '
               '0x8017C018. When the pad produced a change the handler calls '
               'sprite_quad_packet_build(handle, dialogue_word_dbc4, 0, 2*state) and '
               'exits; otherwise it calls sprite_quad_packet_build(handle, ..., 1) and '
               'clears bit 0 of object byte +1 and frees the sprite. **Consumer**: '
               'sprite_manager_tick @0x8013E28C..0x8013E2A8 reads the same state byte, '
               'and while it is != 0xFF calls sprite_render_dispatch @0x80144B60 with '
               'dialogue_sprite_word_8017bfdc; that routine bails out unless object '
               '+0x20 has bit 0 and object byte +1 has bit 0, i.e. +1 bit 0 is the '
               'object draw-enable flag, separate from field-descriptor coordinates.',
        evidence='handler disassembly 0x8013BCDC..0x8013BF80; consumer '
                 '0x8013E28C + 0x80144B60..0x80144C14'),
    0x06: dict(
        name='sprite_upload_block_load',
        operands=[('n', 'b')],
        layout='1 count byte, then 3 bytes per loaded slot (n <= 8)',
        writes=[0x80171C29, 0x8017A148, 0x8017A150, 0x8017A158, 0x801716B8],
        consumers=[0x8013E450],
        effect='Fill the 8-entry sprite/text upload block: entity_flag_byte_80171c29 = 1; '
               'for i < n read three bytes into sprite_upload_type[i] (0x8017A148), '
               'sprite_upload_param[i] (0x8017A150) and sprite_upload_enable[i] (0x8017A158); '
               'for the remaining i < 8 write 0xFF to type[i] and 0 to enable[i]; finally set '
               'the 4-frame upload countdown event_upload_mode_801716b8 = 4. The block is '
               'consumed by sprite_struct_batch_update @0x8013E450: type == 0x80 selects the '
               'special/text path (0x8017BDCC = table_0x80171B88[param], and on the '
               'countdown==4 pass sets 0x8017BD79 = 2); any other type is an index into the '
               '24-byte area_tile_desc_table, whose descriptor +5 is set to 2 and which is '
               'drawn with the parameter table 0x80171B98[param]. The countdown is decremented '
               'at 0x8013E598 and the block is re-read each frame until it reaches zero.'),
    0x07: dict(
        name='glyph_descriptor_display',
        layout='selector and mode, plus one byte for modes 0..3 or three bytes for mode 4; modes 5/6 consume only selector and mode',
        operands=[('sel', 'b'), ('mode', 'b')],
        reads=[0x8017AF94, 0x8017DAA0, 0x8017BD74],
        calls=[0x8012F828],
        consumers=[0x8012F828, 0x8013C750, 0x8013C7A4],
        effect='Resolve a 24-byte entity descriptor from sel: bit 0x40 -> '
               'sysfont_desc_table[sel & 0x3F]; sel == 0x80 -> the fixed descriptor at '
               '0x8017BD74; otherwise area_tile_desc_table[sel]. Then obj_table_lookup_by_ptr '
               'returns its parallel 8-byte state record and the second operand (0..6) selects an '
               'arm of the jump table @0x800C1978: 0 -> descriptor +5 = byte; 1 -> +0 = byte '
               'then event_record_field_copy 0x8013C750; 2 -> +1 = byte then 0x8013C750; '
               '3 -> +0x16 = byte; 4 -> a 2-bit value merged into descriptor +4 selected by a '
               'third byte (1 |= 1, 2 &= 1, 3 |= 2, 0 &= 2), then +0/+1 = two more bytes and '
               'byte_value_dispatch 0x8013C7A4(descriptor, selector); 5 -> set bit 0x40 of the '
               'descriptor object byte +1; 6 -> toggle it. It is a display-list/text-fade '
               'primitive, not a stream jump (the old label event_stream_jump is wrong).',
        control='branch'),
    0x08: dict(
        name='scroll_set_x',
        operands=[('tile', 'b'), ('pos', 'b')],
        reads=[0x8017C028],
        writes=[0x8017A140, 0x8017A130, 0x8017C028],
        consumers=[0x8013ED6C],
        effect='Start a horizontal camera pan: scroll_target_x (0x8017A140) = tile, an index '
               'into the per-tile delta tables 0x80171860 (dx) / 0x80171870 (dy), and '
               'scroll_accum_x (0x8017A130) = pos*8, a countdown. Each frame '
               'scroll_offset_accumulator @0x8013ED6C (called from frame_update_driver '
               '@0x8013F148) adds the selected dx/dy to camera_scroll_x/y '
               '(0x8017C008/0x8017C010), subtracts 2 from the countdown, and when it reaches '
               'zero XORs event_state_flags bit 0x0004 off (the horizontal-pan flag).'),
    0x09: dict(
        name='gamestate_or_byte',
        operands=[('id', 'b'), ('bits', 'b')],
        reads=[0x8017DB24],
        writes=['game_state+0x190+id'],
        effect='game_state[0x190 + id] |= bits (the store sits in the jr $ra delay slot).'),
    0x0A: dict(
        name='scroll_set_y',
        operands=[('v', 'b')],
        reads=[0x8017C028],
        writes=[0x8017A138, 0x8017C028],
        consumers=[0x8013ED6C],
        effect='Arm a camera timer: scroll_accum_y (0x8017A138) = v*5, a countdown '
               'decremented by 1 each frame by scroll_offset_accumulator @0x8013ED6C, which '
               'XORs event_state_flags bit 0x0020 off when it reaches zero. Its consumer arm '
               'only updates the countdown and flag.'),
    0x0B: dict(
        name='dialogue_box_open_0',
        operands=[('layout', 'b')],
        reads=[0x8017DBB4],
        writes=[0x8017DBB0, 0x8017DBBC],
        calls=[0x80145194, 0x8013B0C8],
        effect='If sprite_slot_flags[0] is set, rewind one byte (wait). Otherwise '
               'allocate the box sprite-text struct (-0x7C, 0x26, 0x1E, 5) into '
               'sprite_slot_table[0], clear event_word_dbbc[0], and read the operand byte '
               'into dialogue_layout_calc(0, byte): opens dialogue box 0.',
        control='rewind'),
    0x0C: dict(
        name='sprite_setup_0',
        operands=[],
        calls=[0x8013B2F4],
        effect='Wrapper: event_obj_sprite_setup_indexed(0) - initialise the op-0x0D '
               'object array at slot 0.',
        control='next'),
    0x0D: dict(
        name='object_array_alloc',
        operands=[('n', 'b')],
        layout='1 count byte, then one tile-id byte per created entry; four copied bytes come from the tile record, not the stream',
        reads=[0x8017AAE4, 0x8017BE20, 0x8017C0BC],
        writes=[0x8017C050, 0x8017C0BC],
        calls=[0x800C2D30, 0x800C3D38],
        consumers=[0x800C3DAC,0x800C3E9C,0x800C4244],
        effect='Store count n at0x8017C0BC and malloc(n*12) pointer at0x8017C050. '
               'For each tile-id byte, select the five-byte area+0x2C record at '
               '(area_state+0x94 + tile_id)*5. Copy source bytes0/1/3/4 into '
               'entry0..3; source byte2 selects the animation sequence for '
               'obj_alloc_init(*area+0x20, source[2]). Store the28-byte object '
               'at entry+8 and its selected draw-descriptor bytes2/3 at entry+4/+5. '
               'The selector indexes resource+0x14; timed pairs select draws '
               'through resource+0x10, advanced by800C4244.',
        status='proven'),
    0x0E: dict(
        name='dialogue_cleanup',
        operands=[],
        calls=[0x80138410],
        effect='Wrapper for the dialogue teardown at 0x80138410: releases the dialogue '
               'box / text state.'),
    0x0F: dict(
        name='tile_entry_mark_free',
        operands=[('idx', 'b'), ('rel', 'b')],
        layout='1 byte, or 2 bytes when idx == 0xFF',
        reads=[0x8017C038, 0x8017AAE4],
        effect='Stage a scenery entry off-map by setting both coordinate bytes to '
               '0xFF: idx != 0xFF addresses tile_entry_table[idx] (stride 12); '
               'idx == 0xFF addresses entry (area_header.count + rel). The count '
               'and attached graphics remain unchanged.',
        control='next'),
    0x10: dict(
        name='camera_pan_to_tile',
        operands=[('x', 'b'), ('y', 'b')],
        reads=[0x8017BD74, 0x8017BD75],
        writes=[0x8017A160, 0x8017A168, 0x8017A170, 0x80171C29],
        calls=[0x8013D038],
        consumers=[0x8013D038, 0x8013E450, 0x8012C860],
        effect='Request scripted Hero alignment toward cell (x, y): sprite_batch_byte_8017a160 = 1 (the '
               'vertical-pan stage counter) and entity_flag_byte_80171c29 = 1; compare x with '
               'player_cell_x and y with player_cell_y, storing the horizontal '
               'direction (1 = right, 3 = left) and then the vertical direction code in '
               '0x8017A168 (0 = up, 2 = down) with the vertical distance in 0x8017A170; finally '
               'call the upload-block setter 0x8013D038(horizontal_dir, |dx|), which fills '
               'sprite upload slot 0 with type 0x80 and sets the countdown 0x801716B8 = 4. '
               'sprite_struct_batch_update @0x8013E450 then maps the direction through the code '
               'table 0x80171B88 into 0x8017BDCC and calls the direction dispatcher 0x8012C860; '
               'the vertical half is re-issued from 0x8013E628 via the same setter.'),
    0x11: dict(
        name='descriptor_state_transition',
        operands=[('sel', 'b'), ('t', 'b')],
        reads=[0x80171B98],
        calls=[0x8013CCF0],
        consumers=[0x8013CCF0, 0x8013C7A4],
        effect='Apply a 2-bit render-state transition to a descriptor: the second operand '
               'indexes the 4-word parameter table at 0x80171B98 (1, 3, 0, 2) and the word is '
               'passed with the first operand to the fixed routine h2da_flag80_gate_dispatch '
               '@0x8013CCF0. That routine resolves the 24-byte descriptor selected by the first '
               'operand exactly as op 0x07 does (0x80 -> fixed 0x8017BD74, 0x40|idx -> '
               'sysfont_desc_table[idx] when idx < obj_array_count, else area_tile_desc_table), '
               'bails out when descriptor +8 is zero, merges the transition into descriptor +4 '
               '(0: &= 2, 1: |= 1, 2: &= 1, 3: |= 2) and rebuilds through byte_value_dispatch '
               '0x8013C7A4. The text-record renderer calls the same routine at 0x8013E9BC, so '
               'this is the shared glyph/sprite state-transition primitive, not a callback '
               'table.'),
    0x12: dict(
        name='event_slot_wait_clear',
        operands=[('idx', 'b'), ('code', 'b')],
        reads=[0x8017DBB0, 0x8017DBC0],
        writes=[0x8017DBC0],
        calls=[0x8013FB58],
        consumers=[0x8013FB58, 0x8014695C],
        effect='Slot completion wait keyed on the per-slot status word '
               'event_slot_word_dbc0[idx] (stride 20). While it is not 1 the handler '
               'marks it 1, loads sprite_slot_table[idx] and calls the slot start '
               'helper 0x8013FB58(idx, code, slot_ptr), which also selects a character/custom image through 0x8013F584, then rewinds the cursor by 3 '
               '(wait). 0x8013FB58 walks the per-code string table at 0x80170588 '
               '(0x6E entries), copies the code\'s bytes into the 0x8017A190 buffer '
               '(appending 0x03), and runs them into the slot\'s sprite-text object: '
               'struct_byte4_set(obj, 0), sprite_flag_clear_bit11(obj, &0x8017A190) '
               'and obj+0xA = 0. Once the word is 1 the handler takes the code arm: '
               'code == 8 or code >= 0x7D clears the word at 0x8013AF4C and returns '
               '(no rewind, execution continues); any other code loads the slot object '
               'and tests its flag halfword +0x20 for bit 0x800 '
               '(the object loaded from sprite_slot_table[idx]), clearing the word at '
               '0x8013AF28 only '
               'when that bit is set - otherwise it falls to 0x8013AF88 and rewinds by '
               '3, i.e. it waits for the string to finish. **Consumer**: bit 0x800 of '
               'the sprite-text flag halfword is set by sprite_text_string_runner '
               '@0x80146A08 when its +0x54 string pointer reaches a NUL, and that '
               'runner is called per frame by sprite_obj_update @0x80145C74. So the '
               'code arm is "advance when the text has been consumed".',
        control='rewind',
        evidence='handler 0x8013AE80..0x8013AF9C; helper 0x8013FB58..0x8013FBC0; '
                 'completion bit 0x80146A08..0x80146A14; runner call site 0x80145C74'),
    0x13: dict(
        name='tile_grid_init_slot0',
        operands=[],
        reads=[0x8017DBB0],
        calls=[0x80146DFC],
        effect='tile_grid_packet_init(sprite_slot_table[0]): rebuild the tile-grid GPU '
               'packet for slot 0.'),
    0x14: dict(
        name='jump_forward',
        operands=[('off', 'b')],
        effect='Relative forward branch: cursor = cursor + off, where cursor already '
               'points at the operand byte (i.e. the target is opcode+1+off).',
        control='branch'),
    0x15: dict(
        name='switch_on_ui_mode',
        operands=[('n', 'b'), ('off', 'b')],
        layout='1 count byte, then n-1 relative offsets (2..7 bytes typical)',
        reads=[0x8017BD6C],
        effect='Multi-way switch on ui_state_mode_byte (0x8017BD6C): the operands form a '
               'table [1, off1, ...] indexed by the mode byte minus one; the selected '
               'offset is added to opcode+count, one byte before the physical end '
               'of the operand list; default offset 1 reaches the next instruction.',
        control='branch'),
    0x16: dict(
        name='gamestate_or_byte_280',
        operands=[('id', 'b'), ('bits', 'b')],
        reads=[0x8017DB24],
        writes=['game_state+0x280+id'],
        effect='game_state[0x280 + id] |= bits (store in the jr $ra delay slot).'),
    0x17: dict(
        name='dialogue_box_open_1',
        operands=[('layout', 'b')],
        reads=[0x8017DBC8],
        writes=[0x8017DBC4, 0x8017DBD0],
        calls=[0x80145194, 0x8013B0C8],
        effect='Dialogue box 1: if dialogue_byte_dbc8 (busy) is set, rewind one byte '
               '(wait). Otherwise allocate the sprite-text struct (-0x7C, 0x26, 0x1E, 5) '
               'into dialogue_word_dbc4, clear dialogue_word_dbd0, and pass the operand '
               'byte to dialogue_layout_calc(1, byte).',
        control='rewind'),
    0x18: dict(
        name='sprite_setup_1',
        operands=[],
        calls=[0x8013B2F4],
        effect='Wrapper: event_obj_sprite_setup_indexed(1).'),
    0x19: dict(
        name='tile_grid_init_box1',
        operands=[],
        reads=[0x8017DBC4],
        calls=[0x80146DFC],
        effect='tile_grid_packet_init(dialogue_word_dbc4): rebuild the tile-grid packet '
               'for dialogue box 1.'),
    0x1A: dict(
        name='text_effect_mode_200',
        operands=[('v', 'b')],
        reads=[0x8017C028],
        writes=[0x8017BD79, 0x8017BF00, 0x8017C028],
        effect='Enable text effect mode: event_state_flags |= 0x0200; clear '
               'text_effect_flag (0x8017BD79); store the operand byte in '
               'event_opcode_shadow (0x8017BF00).'),
    0x1B: dict(
        name='text_effect_mode_400',
        operands=[('v', 'b')],
        reads=[0x8017C028],
        writes=[0x8017BD79, 0x8017BF00, 0x8017C028],
        effect='As 0x1A but event_state_flags |= 0x0400.'),
    0x1C: dict(
        name='dialogue_text_3byte',
        operands=[('speaker', 'b'), ('table', 'b'), ('entry', 'b')],
        reads=[0x8017C108],
        calls=[0x8013F6B4, 0x8013B7A0],
        effect='The dialogue consumer. Clear the text buffer, then resolve the string by '
               'double indirection through the area struct: root = *(area_struct+0x14); '
               'text = root[table][entry]; then partystruct_text_copy_dispatch(text, '
               'speaker). This is the verified per-line dialogue opcode.',
        control='next'),
    0x1D: dict(
        name='tile_table_rebuild',
        operands=[('v', 'b')],
        reads=[0x8017C164],
        calls=[0x8012EBDC],
        effect='game_state_copy[0x1A] = v; tile_entry_table_rebuild().'),
    0x1E: dict(
        name='transition_struct_free',
        operands=[],
        reads=[0x8017C164],
        calls=[0x8012C598],
        effect='game_state_copy[0x1A] = 0xFF and struct_triple_free(0x8017C0A4): tear '
               'down the tile-transition struct.'),
    0x1F: dict(
        name='area_file_load',
        operands=[('file', 'b'), ('idx', 'b')],
        layout='1 byte, or 2 bytes when file == 0xFF',
        reads=[0x8017DB24, 0x8017AAE4],
        writes=['game_state+0x1AF4[file]'],
        calls=[0x800C48D4, 0x800C4864, 0x800C4954, 0x800C49B8, 0x800C2FA4, 0x801395FC],
        effect='Load an area data file and block on the CD: mark the file loaded in the '
               'game-state bitmap (game_state[0x1AF4 + file] |= 1) and, when file == 0xFF, '
               'take the id from the second operand; otherwise resolve the id through the '
               'area header file tables (+0x1C / +0x20). Then file_loader_by_id / '
               'file_slot_alloc / file_data_copy_20k / file_object_setup, looping on '
               'cd_sync_then_read, and finally char_recruit_count_total().',
        control='next'),
    0x20: dict(
        name='party_roster_edit',
        operands=[('op', 'b'), ('char', 'b')],
        layout='2 bytes for 0xFC/0xFE, 1 byte for 0xFF/0xFD and plain character ids',
        reads=[0x8017DB24],
        writes=['game_state+0xE party list', 'save-buffer recruit entries'],
        calls=[0x8013A0C0, 0x8013A038, 0x800C4AFC, 0x800C4C30, 0x80133184, 0x80139E10],
        effect='Add/remove a character in the six-slot party list (game_state+0xE): '
               'op 0xFF/0xFD delegates to party_item_assign_handler; 0xFC/0xFE compare '
               'the second operand against the slot occupant and then '
               'party_slot_char_set + savebuf_char_entry_remove_a/b; a plain char id is '
               'matched against the occupant and passed to party_slot_char_set '
               'and savebuf_char_entry_remove_b. Always ends with '
               'party_formation_sync().',
        control='next'),
    0x21: dict(
        name='camera_push_start',
        operands=[('rec', 'b'), ('repeats', 'b')],
        calls=[0x80140018],
        consumers=[0x80140018, 0x8013FF5C, 0x80140068, 0x80141E08],
        effect='Start a scripted camera push. The wrapper at 0x8013D24C calls '
               'flag800_apply_a @0x80140018: operand 1 indexes five-byte camera-offset records in the '
               'record table at 0x801718D4 and operand 2 is a repeat count; the record '
               'pointer goes to 0x801718D0 and the count to 0x801718CD, event_state_flags |= '
               '0x1000, text_effect_flag = 2, then 0x8013FF5C adds record[0]/record[1] to '
               'player_cell_x/y, sets the frame count 0x801718CE = record[4] and '
               'camera_offset_x/y (0x8017BD76/0x8017BD77) = record[2|3] * record[4]. The '
               'per-frame processor 0x80140068 (called from frame_orchestrator @0x80141E10) '
               'counts the frames down, rebuilds the tile objects, re-applies the record while '
               'the repeat count remains and finally clears event_state_flags bit 0x1000. '
               'The old "flag800" name and the 0x800-block flag-record reading were wrong: '
               'the table entries are camera deltas, not flags.'),
    0x22: dict(
        name='fade_scan_select',
        operands=[('sel', 'b'), ('v', 'b')],
        layout='1 byte (sel 0/1/3) or 2 bytes (sel 2)',
        calls=[0x801404B8, 0x80140860, 0x80140888, 0x8014095C],
        consumers=[0x801404B8, 0x80140860, 0x80140888, 0x8014095C, 0x80134158,
                   0x80130A48],
        effect='Select an arm of the fade-scan control block at area_state+0x441..+0x44E and '
               'set event_state_flags bit 0x800: 0 -> flag800_clear_all @0x801404B8 resets the '
               'block (+0x444 = 0, +0x443 = 0, +0x441 = 1, +0x448/+0x446/+0x44C = 0, '
               '+0x44E += 1, +0x442 = 0x12); 1 -> flag800_set_444_1 @0x80140860 (+0x444 = 1); '
               '2 -> flag800_set_441_444 @0x80140888 with the operand doubled (+0x441 = 1, '
               '+0x443 = 0, +0x444 = 2, +0x44C = 2*v); 3 -> flag800_apply_b @0x8014095C, which '
               'mallocs a 4-byte step vector into 0x801718FC holding the direction sign and '
               'the distance from +0x448 vs 0xB4. The +0x441 active flag is consumed by '
               'text_color_pair_driver @0x80134158 and entity_table_sweep_true @0x80130A48.',
        control='next'),
    0x23: dict(
        name='jump_backward',
        operands=[('off', 'b')],
        effect='Relative backward branch: cursor = cursor - off. Used to close loops that '
               '0x14/0x15 opened.',
        control='branch'),
    0x24: dict(
        name='fade_out_2',
        operands=[],
        reads=[0x8017BE20, 0x8017C028],
        writes=[0x8017C028],
        struct_writes=[(0x8017BE20, 0x4D8), (0x8017BE20, 0x4DC), (0x8017BE20, 0x4DD),
                       (0x8017BE20, 0x4DE)],
        consumers=[0x80131C08, 0x8013ED6C],
        effect='Start a full-screen fade overlay toward black with blend mode 2: '
               'area_state+0x4D8 = 1 (fade_enable_word), +0x4DC = 0 (fade_level), '
               '+0x4DD = 2 (fade_blend_mode), +0x4DE = 0x0A (fade_slot_index, in the jr $ra '
               'delay slot); event_state_flags |= 0x0010. field_update_driver @0x80131C08 '
               'draws the 320x240 overlay quad with +0x4DC copied into its three colour bytes, '
               '+0x4DD as the blend mode and +0x4DE as the draw slot; '
               'scroll_offset_accumulator @0x8013ED6C advances +0x4DC by 2*area_state+0x39 '
               'per frame and clears event_state_flags bit 0x10 when it would pass '
               '0xFF - 2*step, then sets +0x4DC = 0xFF and 0x80171594 = 0.'),
    0x25: dict(
        name='fade_in_text_color_2',
        operands=[],
        reads=[0x8017BE20, 0x8017C028],
        writes=[0x80171594, 0x8017C028],
        struct_writes=[(0x8017BE20, 0x4D8), (0x8017BE20, 0x4DC), (0x8017BE20, 0x4DD),
                       (0x8017BE20, 0x4DE)],
        calls=[0x80133F50],
        consumers=[0x80131C08, 0x80133F50, 0x8013ED6C],
        effect='Start a fade overlay from black toward the scene with blend mode 2 and the '
               'text-colour driver: area_state+0x4D8 = 1, +0x4DC = 0xFF, +0x4DD = 2, '
               '+0x4DE = 0x0A; 0x80171594 = 0x80; event_state_flags |= 0x0040; then '
               'text_color_pair_driver(0x80133F50). The bit-0x40 arm of '
               'scroll_offset_accumulator @0x8013EEDC decrements +0x4DC by '
               '2*area_state+0x39 per frame and, when it falls below that step, sets '
               '+0x4DC = 0, 0x80171594 = 0x80, clears fade_enable_word +0x4D8 and clears '
               'event_state_flags bit 0x40.'),
    0x26: dict(
        name='camera_scroll_set',
        operands=[('x', 'b'), ('y', 'b')],
        reads=[0x8017A120],
        writes=[0x8017BFE4, 0x8017C008, 0x8017C010],
        effect='Set the camera scroll: camera_scroll_x = x*8, camera_scroll_y = y*8; if '
               'the text-metrics struct (*(0x8017A120)) has bit 0x10 at +4, also set '
               'transition_flag_8017bfe4 = 1.',
        control='next'),
    0x29: dict(
        name='gamestate_andnot_byte',
        operands=[('id', 'b'), ('bits', 'b')],
        reads=[0x8017DB24],
        writes=['game_state+0x190+id'],
        effect='game_state[0x190 + id] &= ~bits (store in the jr $ra delay slot).'),
    0x2A: dict(
        name='fade_out_1',
        operands=[],
        reads=[0x8017BE20, 0x8017C028],
        writes=[0x8017C028],
        struct_writes=[(0x8017BE20, 0x4D8), (0x8017BE20, 0x4DC), (0x8017BE20, 0x4DD),
                       (0x8017BE20, 0x4DE)],
        consumers=[0x80131C08, 0x8013ED6C],
        effect='Start the same full-screen fade overlay as 0x24 but with fade_blend_mode '
               '+0x4DD = 1: area_state+0x4D8 = 1, +0x4DC = 0, +0x4DE = 0x0A; '
               'event_state_flags |= 0x0080. The bit-0x80 arm of scroll_offset_accumulator '
               '@0x8013EF60 advances +0x4DC by 2*area_state+0x39 and on completion sets '
               '+0x4DC = 0xFF, 0x80171594 = 0xFF and clears bit 0x80.'),
    0x2B: dict(
        name='fade_in_text_color_1',
        operands=[],
        reads=[0x8017BE20, 0x8017C028],
        writes=[0x8017C028],
        struct_writes=[(0x8017BE20, 0x4D8), (0x8017BE20, 0x4DC), (0x8017BE20, 0x4DD),
                       (0x8017BE20, 0x4DE)],
        consumers=[0x80131C08, 0x8013ED6C],
        effect='Start the same fade overlay as 0x25 but with fade_blend_mode +0x4DD = 1: '
               'area_state+0x4D8 = 1, +0x4DC = 0xFF, +0x4DE = 0x0A; event_state_flags |= '
               '0x0100. The bit-0x100 arm of scroll_offset_accumulator @0x8013EFE0 decrements '
               '+0x4DC by 2*area_state+0x39 and on completion clears it, sets 0x80171594 = '
               '0x80, clears the overlay word +0x4D8 and clears bit 0x100. Unlike 0x25 it does '
               'not call text_color_pair_driver at start-up, but its completion colour matches.'),
    0x2C: dict(
        name='sprite_palette_reupload',
        operands=[],
        reads=[0x8017AAE4, 0x8017C164, 0x8017DB24],
        calls=[0x800C39E4, 0x800C39F4, 0x80133698, 0x801337B8],
        consumers=[0x80133698, 0x801337B8, 0x800C3C5C, 0x800C3CC8],
        effect='Re-upload every sprite palette into CLUT bank 0 and then advance the '
               'VRAM target. set_config_byte2(0) sets the strip x-position byte '
               '0x80179038 and set_config_byte3(0) resets the strip row counter '
               '0x80179040; then the mislabelled helper 0x80133698(area_header, 0, 1) '
               'is NOT a debug dump - it is the 256-entry palette uploader: for each of '
               'area_header+0x5 palette-table entries it reads the 256 RGB555 words at '
               '*(area_header+0xC + 4*i), optionally converts them (rgb15_bulk_convert '
               '0x80133618 when the flags low nibble is 0, rgb15_pixel_convert '
               '0x80133514 otherwise, skipped entirely when flag bit 0x80 is set or the '
               'second argument equals 0x80) and calls vram_upload_strip_a @0x800C3C5C, '
               'which loads a RECT(x=0, y=0x1E0 + byte_0x80179038, w=0x100, h=1) via '
               'gpu_loadimage_wrap 0x80148590 and then increments 0x80179038 - so the '
               'n-th upload lands on CLUT row 0x1E0 + n in bank 0. The handler then '
               'calls sprite_colorize_upload_driver @0x801337B8(ptr, 0, 1) for each of '
               'the area_header+0x1C area sprite objects (dereferenced from the '
               'area_header+0x20 pointer array) and for each of the six party members '
               '(game_state[0x1B9C + char*4] + 0x28, skipping entries equal to 0xFF). '
               'That driver sets the row counter to obj+0x7, memmoves 0x200 bytes from '
               'obj+0xC and uploads via vram_upload_strip_b @0x800C3CC8, whose only '
               'difference is RECT height 0x20 instead of 1. Finally set_config_byte3 '
               '(0x1A) parks the row counter so the next palette load starts at row '
               '0x1E0 + 0x1A.',
        evidence='handler 0x80133A90..0x80133BB0; uploader 0x80133698..0x8013378C; '
                 'driver 0x801337B8..0x80133958; strips 0x800C3C5C / 0x800C3CC8; '
                 'setters 0x800C39E4 / 0x800C39F4'),

    0x2D: dict(
        name='scan_backward_label',
        operands=[('byte', 'b')],
        layout='1 search-key byte, then the handler scans the stream backwards',
        effect='Search the stream backwards for a byte equal to the operand; leave the '
               'cursor one past the match. Conditional-loop back edge.',
        control='branch'),
    0x2E: dict(
        name='scan_forward_label',
        operands=[('byte', 'b')],
        layout='1 search-key byte, then the handler scans the stream forwards',
        effect='Search the stream forwards for a byte equal to the operand; leave the '
               'cursor right after the match. Conditional-loop forward edge.',
        control='branch'),
    0x2F: dict(
        name='switch_on_ui_mode_labels',
        operands=[('selector', 'b')],
        layout='selector plus (selector & 0x3F)-1 label bytes; total operand '
               'length is selector & 0x3F for a nonzero count',
        reads=[0x8017BD6C],
        effect='Let T be the byte after the selector, n = selector & 0x3F and '
               'base = T + n - 1. The n-1 header bytes are raw byte labels. '
               'For each label, search from base+1 for its first equal byte and '
               'store its displacement from base in a stack word. Stack word 0 '
               'is zero (default arm at base). Select word[mode] when selector '
               'bit 0x80 is set, otherwise word[mode-1], then set cursor to '
               'base + displacement. Labels commonly use F8..FC, which the '
               'tick accepts as NOPs when the branch lands on them. The handler '
               'does not check mode bounds or missing labels.',
        control='branch',
        status='proven',
        evidence='handler 0x8013A484..0x8013A588; header/table arithmetic '
                 '0x8013A4B0/CC/D0 and 0x8013A524/28; four independently '
                 'checked disc switches in test_event_operand_lengths.py'),

    0x30: dict(
        name='continue_reloop',
        operands=[],
        writes=[0x8017A180],
        effect='Set the re-loop flag (0x8017A180) = 1: the tick keeps interpreting, so the '
               'next opcode runs in the same frame. The flag is cleared to 0 by '
               'pre_tick_setup @0x8013E17C when a stream is selected. Ordinary frame pumps '
               'preserve it; it remains set until a clearing handler or new selection.',
        control='reloop'),
    0x31: dict(
        name='yield_frame',
        operands=[],
        writes=[0x8017A180],
        effect='Clear the re-loop flag (0x8017A180) = 0: stop interpreting and return to '
               'the frame driver. The cursor is preserved for the next frame; this alone does not end the selected stream.',
        control='stop'),
    0x32: dict(
        name='draw_record_queue',
        operands=[('sel', 'b'), ('h', 'b')],
        layout='2 bytes; the handler then scans forward to the next 0x05 text-pause byte',
        reads=[0x801716B9, 0x8017AF94, 0x8017DAA0, 0x8017BF7C],
        writes=[0x801716B9, 0x8017DAA8],
        calls=[0x800C2D30],
        consumers=[0x8013E7E0, 0x8013F110],
        effect='Queue one 12-byte draw record and skip to the next text pause. Resolve a '
               '24-byte glyph descriptor from sel (sel == 0x80 -> the fixed descriptor at '
               '0x8017BD74, including record allocation; bit 0x40 -> sysfont_desc_table[sel & '
               '0x3F] when that index is below obj_array_count, otherwise no record; else '
               'area_tile_desc_table[sel]). When a record is allocated the handler mallocs '
               '0xC bytes (0x8013C3FC) and stores the *pointer* into the pointer array at '
               '0x8017DAA8[event_text_queue_count] with a 4-byte stride (0x8013C40C/0x8013C41C) '
               '-- 0x8017DAA8 is an array of pointers, not a 12-byte record array. Record '
               'fields: +0 selector byte, +4 source cursor (the event-stream cursor, ahead of '
               'the text that follows), +8 countdown/state (0), +0xA the descriptor height byte '
               '+5, +0xB flags (0); descriptor +2/+3 are cleared, descriptor +5 = 2 and '
               'event_text_queue_count is incremented. The cursor is then advanced two bytes at '
               'a time until stream[cursor+2] == 0x05 (the game-text pause code), then one more, '
               'so the opcode carries the text up to its next pause marker. The records are '
               'consumed every frame by sprite_slot_array_update @0x8013E7E0 (frame_update_driver '
               '@0x8013F158), which reads *0x8017DAA8[i], resolves the descriptor, drives the '
               '+8 countdown and dispatches the byte at the +4 cursor through the 12-entry jump '
               'table at 0x800C1A68.',
        control='branch'),
    0x33: dict(
        name='wait_text_queue_empty',
        operands=[],
        reads=[0x801716B9],
        effect='Rewind one byte; if event_text_queue_count (0x801716B9) is non-zero the '
               'cursor is restored and execution continues, otherwise it stays rewound: '
               'wait until the queued text records have been consumed.',
        control='rewind'),
    0x34: dict(
        name='descriptor_table_build',
        operands=[('n', 'b')],
        layout='1 count byte plus four bytes per entry; 0xFF selects the one-byte free path',
        reads=[0x8017BD74, 0x8017BD75, 0x8017C038, 0x8017BF7C],
        writes=[0x8017AF94, 0x8017BF7C],
        calls=[0x800C2D30, 0x8012E308, 0x8012EA40, 0x801343B4, 0x8013A770,
               0x8013A808],
        effect='Build the 24-byte glyph/Object descriptor array at 0x8017AF94: '
               'obj_array_count (0x8017BF7C) = n, malloc(n*24), then per entry read a '
               'character id and a tile byte from the stream, query the tile with '
               'tile_query_xy_layer, copy the record from the tile-entry table, allocate '
               'three party-member objects by id, and register a transition direction '
               'struct. n == 0xFF instead clears the array through '
               'c164_countdown_struct_init. The child selector is an animation-table '
               'index. transition_dir_struct_setup changes the middle child sequence '
               '(0xFF ticks it), writes the first child tint from80171594, the '
               'middle child tint/flags A0/2 when room+7==1, and last child22/1. '
               '800C3FBC consumes tint as RGB modulation;800C4180 consumes draw flags.',
        consumers=[0x800C3DAC,0x800C3E9C,0x800C3FBC,0x800C4180],
        status='proven'),
    0x35: dict(
        name='dialogue_box1_char',
        operands=[('char', 'b')],
        reads=[0x8017DBC8, 0x8017DBC4],
        writes=[0x8017DBC4, 0x8017DBC8, 0x8017DBCA, 0x8017DBCC, 0x8017DBD0,
                0x8017C028],
        calls=[0x80145194, 0x80133BB4, 0x8013AFA0, 0x800C4DB4, 0x8013F6B4],
        effect='Draw one character/code in dialogue box 1: if the box is busy '
               '(dialogue_byte_dbc8) rewind and wait; otherwise allocate the sprite-text '
               'struct, translate the operand through char_encoding_translate and '
               'text_char_decoder, store the resulting metrics in '
               'dialogue_layout_a/b (0x8017DBCA/0x8017DBCC), mark the box busy, raise '
               'event_state_flags bit 2, issue display command 0x0501 and clear the text '
               'buffer.',
        control='rewind'),
    0x36: dict(
        name='glyph_record_queue_a',
        operands=[],
        reads=[0x801716B9, 0x8017BF7C, 0x8017AF94, 0x8017BD7C, 0x80171A78],
        writes=[0x801716B9, 0x8017DAA8],
        calls=[0x8013A808, 0x800C2D30],
        consumers=[0x8013E7E0],
        effect='Queue one 12-byte draw record per glyph of obj_array_count (0x8017BF7C) '
               'through the same pointer array 0x8017DAA8[count++]: first call '
               'c164_countdown_struct_init 0x8013A808, then for i in 0..count-1 malloc 0xC '
               'and store the pointer (4-byte stride). The record selector is 0x40|i, i.e. '
               'sysfont_desc_table[i]; +4 points at the glyph code *word* from the per-page '
               'table 0x80171A78 indexed by *(0x8017BD7C) with a 20-byte page stride; +8 = 0; '
               '+0xA = the source descriptor byte +5 (height); +0xB = 0. Consumed by '
               'sprite_slot_array_update @0x8013E7E0, which advances the +4 cursor and feeds '
               'the byte through the 0x800C1A68 code table.',
        control='next'),
    0x37: dict(
        name='glyph_record_queue_b',
        operands=[],
        reads=[0x801716B9, 0x8017BF7C, 0x8017AF94, 0x8017BD7C, 0x80171B38],
        writes=[0x801716B9, 0x8017DAA8],
        calls=[0x800C2D30],
        consumers=[0x8013E7E0],
        effect='The initialising twin of 0x36: the glyph codes come from the second per-page '
               'table 0x80171B38 instead of 0x80171A78, the record gets +0xA = descriptor +5 '
               'and +0xB = 0, and for each entry the source descriptor is prepared too '
               '(byte +2 and +3 cleared, +5 set to 2) before the next record is queued. '
               'Records land in the same 0x8017DAA8 pointer array and are consumed by '
               'sprite_slot_array_update @0x8013E7E0.'),
    0x38: dict(
        name='text_queue_wait_free',
        operands=[],
        reads=[0x801716B9],
        calls=[0x8013ABF4],
        effect='Rewind one byte; if event_text_queue_count (0x801716B9) is non-zero '
               'continue (cursor restored), otherwise free the descriptor array via '
               '0x8013ABF4 and advance: wait for the text queue to drain, then tear the '
               'table down.',
        control='rewind'),
    0x39: dict(
        name='descriptor_table_free',
        operands=[],
        reads=[0x8017AF94, 0x8017BF7C],
        writes=[0x8017BF7C],
        calls=[0x800C3D8C, 0x800C2DC0],
        effect='Free the descriptor array: for each of obj_array_count entries free the '
               'three object pointers at +8/+0xC/+0x10, then free the array and set '
               'obj_array_count = 0.'),
    0x3A: dict(
        name='descriptor_release',
        operands=[('sel', 'b')],
        reads=[0x8017AF94, 0x8017DAA0, 0x8017BD74],
        consumers=[0x8012FD30, 0x8012FD78, 0x8012FDA0, 0x8012FDC4, 0x8012FDD8],
        effect='Stage a live descriptor off-map, selected exactly as op 0x07 (bit '
               '0x40 -> temporary_desc_table[sel & 0x3F], sel == 0x80 -> the fixed '
               'descriptor 0x8017BD74, else ordinary_desc_table[sel]). If descriptor '
               '+8 is zero nothing happens; otherwise it clears movement increment +5 and '
               'writes 0xF0 into descriptor byte +0 (0x8013C8CC) for the fixed 0x80 '
               'descriptor, or 0xFE into +0 for the other two arms, and then the '
               'delay-slot store at 0x8013C8D8 writes 0xFE into descriptor byte +1. '
               'Bytes +0/+1 are cell coordinates:8012FD78/8012FDC4 read them, '
               'and8012FDA0/8012FDD8 multiply by8 before camera subtraction. '
               'The graphics child is a separate object loaded through descriptor+8 '
               'at8012FD30. Its own byte+1 draw flag (800C3DDC/80144B94) is not '
               'the descriptor Y coordinate. This handler leaves the child attached '
               'and the slot reusable by later coordinate writes. The historical '
               'descriptor_release name remains a stable metadata label.',
        evidence='handler 0x8013C82C..0x8013C8E0; delay-slot constant store 0x8013C8D8 '
                 '= 0xFE; coordinate and child-pointer consumers8012FD30..8012FDD8'),

    0x3B: dict(
        name='party_order_set',
        operands=[('n', 'b')],
        layout='1 count byte, then n character-id bytes',
        reads=[0x8017BE20, 0x8017C164],
        writes=['area_state+0x89 party id list'],
        effect='Rebuild the six-entry party id list at area_state+0x89: save the current '
               'list, set all six to 0xFF, read n ids from the stream into the front, then '
               'fill the remaining slots from the saved list (skipping 0xFF).',
        control='next'),
    0x3C: dict(
        name='party_member_add',
        operands=[('char', 'b')],
        reads=[0x8017DB24],
        calls=[0x800C4BFC, 0x80139E10],
        effect='Recruit/add a character: scan the six party slots (game_state+8) for the '
               'operand id and add it to the save buffer with savebuf_char_entry_add, then '
               'party_formation_sync().',
        control='next'),
    0x3D: dict(
        name='area_effect_dispatch',
        layout='1 selector byte; continuation operands depend on the overlay callback',
        operands=[('sel', 'b')],
        reads=[0x8017C108, 0x80171E24, 0x80171ED8],
        writes=[0x80171E24, 0x80171ED8, 0x8017A240, 0x8017DA40, 0x8017DA41, 0x8017DA42],
        calls=[0x80142C38],
        effect='Increment render_flag_80171ed8; on the first call (color_sel_80171e24 == 0) '
               'mark it 1 and clear the render work bytes 0x8017DA40..0x8017DA42; then '
               'render_context_setup() and an indirect call through the area struct\'s '
               'function table (area_struct+0x10) at index sel+0xA, caching the target in '
               '0x8017A240. Context+4 points to the VM cursor cell; the callback can '
               'consume further operands. Selector-only fallthrough is not a complete '
               'instruction boundary without the overlay callback contract.',
        control='callback'),
    0x3E: dict(
        name='tile_entry_append',
        operands=[('tile', 'b')],
        reads=[0x8017AAE4, 0x8017C09C, 0x8017C038],
        writes=[0x8017C09C],
        calls=[0x800C3D38],
        effect='Append a tile entry: index = tile_entry_count++ (0x8017C09C); take the '
               'five-byte area tile record at (area_header.count + tile) from the area '
               'header +0x28 table, copy bytes 0/1/3/4 into the 12-byte entry at '
               'tile_entry_table[index], create the sprite object and store its handle at '
               'entry+8 with the object type bytes at +4/+5.',
        control='next'),
    0x3F: dict(
        name='tile_entry_object_sync',
        operands=[('idx', 'b'), ('mode', 'b')],
        calls=[0x801384B8],
        consumers=[0x801384B8],
        effect='Per-area tile-entry object synchroniser, NOT a dialogue query. The handler '
               'reads two operands and calls 0x801384B8(idx, mode). That routine loads '
               'area_header_ptr and: count A = lhu area_header+0x24, source array = '
               'area_header+0x28 + A*5 (5-byte records), count B = lhu area_header+0x26, '
               'destination = tile_entry_table_ptr (0x8017C038) + B*12 (12-byte tile '
               'entries). It then loops i < count B and, per mode: '
               'mode 0 -> destination[i]+0 = source[i]+0 and destination[i]+1 = source[i]+1 '
               '(the two-byte copy at 0x8013866C..0x80138680); '
               'mode 1..3 -> free the destination entry\'s object handle at +8 via '
               'free_wrapper and re-create it with obj_alloc_init(*area_header+0x20, '
               'source[i]+1 + (mode==3)) at 0x8013856C..0x8013859C; '
               'mode 4 -> the same free/re-create but with the source byte +1 pre-'
               'incremented (0x801385C8..0x801385F4) and only for the last tile '
               '(i == area_state+0x454 - 1); '
               'mode 5 -> the same only for i < area_state+0x454; '
               'mode 0 also copies source+0 -> destination+0 and source+1 -> '
               'destination+1 (the two-byte tile-entry header). So the stream operands '
               'are the tile-entry index/id and the mode that selects which half of the '
               'sync runs, and the effect is a bulk (re)allocation of the per-tile '
               'sprite objects in tile_entry_table from the area header\'s packed '
               '5-byte record array. The tick discards the return value (0x801394A4), '
               'which is why an earlier pass read this as a query.',
        evidence='handler 0x80139460..0x801394A4; callee 0x801384B8..0x801386D8; '
                 'source packing 0x8012E8F0..0x8012E9BC'),

    0x40: dict(
        name='tile_entry_object_lifecycle',
        operands=[('sel', 'b'), ('idx', 'b'), ('v', 'b')],
        layout='4 bytes for 0xFE, 2 for 0xFD, 1 for other selectors',
        reads=[0x8017BE20, 0x8017C038, 0x8017AAE4],
        calls=[0x800C2DC0, 0x800C3D8C, 0x800C3D38, 0x800C2D30],
        struct_reads=[(0x8017BE20, 0x450)],
        struct_writes=[(0x8017BE20, 0x450)],
        consumers=[0x8013EC20, 0x8012DD98, 0x8012F4D0, 0x8012F988, 0x80130080],
        effect='Maintain area_state+0x450, an 8-byte "current tile-entry object" record '
               '{+0 flags, +1 type, +4 = pointer to tile_entry_table[sel*12]}. sel == 0xFF '
               'frees the record (free 0x800C2DC0) and clears the pointer; sel == 0xFE reads '
               'two more stream bytes into tile_entry_table[idx]+0/+1; sel == 0xFD frees and '
               're-creates the sprite object handle at tile_entry_table[idx]+8 by calling '
               'obj_alloc_init(area_header+0x20 table entry, entry[+1]+1); any other selector '
               'mallocs 8 bytes, points it at tile_entry_table[sel*12] (+4) and zeroes +0/+1. '
               'The pointer is read by the record renderer sprite_slot_array_update @0x8013EC20 '
               'and by the entity movement/collision code (entity_move_collision_resolve '
               '@0x8012DD98, tile_type_update_scan @0x8012F4D0, entity_coord_stepper '
               '@0x8012F988, entity_sprite_position_calc @0x80130080).',
        control='next'),
    0x41: dict(
        name='area_index_set',
        operands=[('sel', 'b')],
        reads=[0x8017DB24, 0x80171C2C],
        calls=[0x80142440],
        effect='Set the current area index: read the halfword table at 0x80171C2C indexed '
               'by sel, call area_index_set_reset_driver(value) and store the same '
               'halfword into game_state+0x30.',
        control='next'),
    0x42: dict(
        name='ui_state_dispatch',
        operands=[('sel', 'b')],
        calls=[0x80141814],
        effect='ui_state_dispatcher(sel): run the UI/menu state selected by the operand '
               'byte.',
        control='next'),
    0x43: dict(
        name='area_transition_param_set',
        operands=[('sel', 'b'), ('idx', 'b')],
        reads=[0x8017BE20, 0x8017C108],
        writes=[0x80171C28, 0x80171C29, 0x8017DC4C],
        struct_writes=[(0x8017BE20, 0x4E0), (0x8017BE20, 0x498), (0x8017BE20, 0x494)],
        consumers=[0x801319E4, 0x80132C28, 0x8012D028],
        effect='Begin an area/menu transition. area_state+0x4E0 = sel (0xFF is stored as 0) is '
               'the field_transition_state byte that gates field_update_driver @0x801319E4 '
               '(nonzero starts the transition work). Then entry idx of the area struct +0x10 '
               'pointer table is resolved: for sel 0xFF or 0x80 the entry word itself goes to '
               'area_state+0x498, which game_state_driver @0x80132C28 loads and jalr\'s as a '
               'one-shot callback (clearing game_driver_word_dc4c first and re-setting it if '
               'the slot emptied); otherwise entry+0xC goes to area_state+0x494, the value read '
               'by menu_gold_setup_driver @0x8012D028 and the menu gold/transaction wrappers '
               '0x8012D054/0x8012D088/0x8012D0BC/0x8012D0F0. Finishes by clearing '
               'entity_collision_enable_flag, setting entity_flag_byte_80171c29 = 1 and '
               'game_driver_word_dc4c = 1.',
        control='next'),
    0x44: dict(
        name='cd_poll_wait',
        operands=[('flag', 'b')],
        calls=[0x800C30E4],
        effect='If the operand byte is zero, call cd_poll_wrap(); when it returns non-zero '
               'rewind the cursor by two bytes and yield - a CD/streaming wait.',
        control='rewind'),
    0x45: dict(
        name='char_recruit_toggle',
        operands=[('char', 'b'), ('v', 'b')],
        layout='1 byte, or 2 bytes when char == 0xFF',
        reads=[0x8017DB24],
        writes=['game_state+0x1AF4'],
        calls=[0x801395FC],
        effect='Toggle the recruit/loaded bit for a character in the game-state bitmap: '
               'char == 0xFF takes the id from the second operand and XORs bit 0 of '
               'game_state[0x1AF4 + id]; otherwise clears the whole byte when bit 1 is set '
               'and then ORs in bit 0, finishing with char_recruit_count_total().',
        control='next'),
    0x46: dict(
        name='conditional_unread',
        operands=[],
        reads=[0x8017C028],
        effect='If event_state_flags & 3 is non-zero, move the cursor back one byte '
               '(un-read a byte): the conditional component of the 0x03/0xFD wait pair.',
        control='rewind'),
    0x47: dict(
        name='event_flag_select',
        operands=[('sel', 'b'), ('idx', 'b')],
        layout='1 byte, or 2 bytes when sel == 0xFF',
        reads=[0x8017AAE4, 0x8017BE20, 0x8017DB24],
        writes=['area_state+0x37', 'game_state+0x1BB4/0x1BC0'],
        calls=[0x8012CBBC],
        effect='Select an event/flag record: sel == 0xFF sets area_state[+0x37] |= 8 and '
               'stores the second operand in game_state+0x1BC0; sel == 0xFE sets '
               'area_state[+0x37] |= 0x10; otherwise take entry (area_header+0x1C)[sel] '
               'from the +0x20 pointer table, store it in game_state+0x1BB4 and call '
               'be20_flag_bytes_set to arm the flag bytes.',
        control='next'),
    0x48: dict(
        name='area_state_store_39',
        operands=[('v', 'b')],
        reads=[0x8017BE20],
        writes=['area_state+0x39'],
        effect='area_state[+0x39] = v (store in the jr $ra delay slot).',
        control='next'),
    0x49: dict(
        name='dialogue_driver',
        operands=[('sel', 'b'), ('v', 'b')],
        layout='1 byte for item ids and 0xFE/0xFF messages; 2 bytes only for 0xFD item removal',
        reads=[0x8017BE20, 0x8017DB24, 0x80171C1C, 0x80171C20],
        writes=[0x8017DBB0, 0x8017DBBC],
        struct_reads=[(0x8017BE20, 0x478), (0x8017BE20, 0x479),
                      (0x8017BE20, 0x474)],
        struct_writes=[(0x8017BE20, 0x474), (0x8017BE20, 0x476),
                       (0x8017BE20, 0x477), (0x8017BE20, 0x47A),
                       (0x8017BE20, 0x47C), (0x8017BE20, 0x47E),
                       (0x8017BE20, 0x480)],
        calls=[0x80145194, 0x8013B0C8, 0x80146BB4, 0x800CA2F0, 0x800CA408],
        consumers=[0x801379AC, 0x80137A40, 0x80137480, 0x80146BB4],
        effect='For sel < 0xFD, read one item-id byte, store it in area_state+0x474, '
               'clear +0x476 and derive remaining uses +0x477 from item+0x1E when '
               'item+0x1C has bits0x0C. Call first-party-bag insert800CA2F0; '
               'UI mode is1 on success and0 when every active bag is full. '
               'For sel0xFE/0xFF, read one byte and build a box message from the '
               'stored item index through table80167658, append the source suffix, '
               'and interpret its glyphs. FF ORs the stored scenario mask; FE '
               'clears the pending actor coordinates/flags/pointer. '
               'For sel0xFD, read the item ID and scan the active party bags. '
               'Call the indexed removal wrapper800CA408 on matching entries. '
               'The pending actor record is also consumed by8012D528 ->801379AC '
               'for area-record position/object updates and scenario XOR.',
        evidence='handler 0x8013B950..0x8013BCCC; index use 0x8013B9E4; record zero '
                 '0x8013BB3C..0x8013BB58; +1 store 0x8013C8D8 independent; consumer '
                 '0x8012D528 + 0x801379AC..0x80137A8C; producers 0x80137374 / '
                 '0x80137480'),

    0x4A: dict(
        name='party_slot_edit_b',
        operands=[('mode', 'b'), ('id', 'b')],
        reads=[0x8017DB24],
        struct_writes=[(0x8017DB24, 0x28)],
        consumers=[0x8017DB24],
        effect='Add or remove a character id in the six-byte list at game_state+0x28. mode 0 '
               'scans slots 0..5 for the first empty (0xFF) slot and writes the operand id '
               'there - the store is the delay slot of the `j` at 0x80139288 '
               '(sb $a3,0x28($a0) at 0x8013928C); any other mode scans for the '
               'first slot equal to the operand and writes 0xFF (0x80139298). If no slot '
               'matches, nothing is written. The previous reading ("the result is returned in '
               '$v0, which the tick discards, so there is no observable effect") was an '
               'artefact of a scanner that could not follow a pointer global plus an index; '
               'the store is to *(game_state_ptr)+0x28+idx and is real.',
        control='next'),
    0x4B: dict(
        name='savebuf_id_table_apply',
        operands=[('op', 'b'), ('a', 'b'), ('v', 'b')],
        layout='2 bytes, 3rd byte iff op in (0, 1, 2)',
        calls=[0x8013875C, 0x800E9CC4, 0x800CA60C, 0x80138FB0],
        consumers=[0x8013875C, 0x80138FB0, 0x800E9CC4, 0x800CA60C],
        effect='Apply an id-table / item-count change. op 3/4 dispatch straight to '
               'flag_pair_dispatch 0x80138FB0(op). Otherwise savebuf_id_table_scan @0x8013875C '
               'looks up the save-buffer id table -- 78 (0x4E) records at game_state+0x294 with '
               'a 0x50 stride, matched on the leading word, returning the entry pointer or 0 -- '
               'first for operand 2 and then for the fixed id 8. The op 0 arm reads the third '
               'stream byte; op 1/2 derive the amount from the entry field +0xD. It then loops '
               'that many battle_tick_counter_advance 0x800E9CC4 calls and finishes with '
               'byte_threshold_classifier 0x800CA60C.',
        control='next'),
    0x4C: dict(
        name='counter_amount_op',
        operands=[('op', 'b'), ('a', 'b'), ('b', 'b'), ('c', 'b')],
        layout='op 0: 3 bytes if operand 2 is zero, otherwise 2; op 1/2: 2; op 3: 4; other selectors: 1',
        reads=[0x8017DB24, 0x80171C24],
        writes=['game_state+0x1C', 'game_state+0x1B9C party records',
                'sprite_slot_table[0]'],
        calls=[0x80145194, 0x8013B0C8, 0x80146FE8, 0x80146BB4, 0x800CA60C],
        consumers=[0x80146FE8, 0x80146BB4],
        effect='Amount/party-record update on game_state+0x1C: op 0 adds 10000*b when the '
               'second operand is 0 else 100*a; op 1 subtracts 100*x with a floor at zero '
               '(0x80138CC4..0x80138CDC); op 2 normalises each party member record '
               '(game_state[0x1B9C+id*4]+0x1C, copying +4 to +6 and clearing +0x16, '
               '0x80138D08..0x80138D3C, then byte_threshold_classifier '
               '0x800CA60C on each record); op 3 adds a five-digit amount '
               '(a + 100*b + 10000*c) at 0x80138DC8..0x80138F04 and selects the digit '
               'width class from the magnitude: s2 = 5 if the amount/0x2710 != 0, 4 if '
               '/0x3E8 != 0, 3 if /0x64 != 0, 2 if /0xA != 0. It then allocates the box '
               'sprite-text struct, calls dialogue_layout_calc(0, 0x80), and calls '
               'num_to_cmd_and_interpret @0x80146FE8 with the pixel-text buffer at '
               'sp+0x16 and an offset of 5 - s2. That routine writes a 5-byte '
               'right-aligned decimal string in the game text encoding (0x45-0x4E = '
               '0-9) at sp+0x12..sp+0x16 (0x80147010 sets the sp+0x16 byte to 0x45 = '
               '"0", 0x80147044 sets each following byte to 0x45 + remainder) and then '
               'tail-calls bytecode_interpreter(buffer + (5 - class), ...). Finally the '
               'fixed string at *(0x80171C24) is copied to the stack and run through '
               'bytecode_interpreter. So class = the digit count, which is why the '
               'function is a "digit class" selector.',
        control='next'),
    0x4D: dict(
        name='tile_variant_set',
        operands=[('op', 'b'), ('tile', 'b'), ('v', 'b')],
        layout='2 bytes, 3rd byte iff op == 3',
        reads=[0x8017DAA0],
        calls=[0x800C3DAC, 0x801343B4],
        consumers=[0x800C3DDC, 0x801343B4],
        effect='Change the variant of area tile descriptor tile: the handler indexes the '
               '24-byte area_tile_desc_table (0x80138B04..0x80138B10: index*24) and '
               'reads the descriptor\'s object pointer from +8 (0x80138B50). op == 2 '
               'waits: while the object\'s flag word +4 has bit 0x10000 (0x80138B20 = '
               'lui 0x1, 0x80138B2C = lw +4, 0x80138B34 = and) it rewinds to the opcode '
               '(0x80138B44). Otherwise the base value is the low nibble of the object\'s '
               'byte +0 (lbu +0 at 0x80138B58, andi 0xF at 0x80138B60 = s0); op 3 reads '
               'the third operand as the absolute value; op 0 adds 1 and op 1 subtracts 1 '
               '(0x80138B8C/0x80138B94). Then obj_initializer @0x800C3DAC(object, variant) '
               'writes variant into object byte +0 (0x800C3DB8), looks up the object\'s '
               'own +0x14 table entry [variant] and copies its byte +0 into object byte +1 '
               '(0x800C3DDC) - the draw flag used by op 0x05 - clears object bytes '
               '+2/+3, rebuilds flag bit 0 of the +4 word from sprite-table entry 1 bit 0 '
               'and bit 16 from sprite-table entry 0 bit 0 (0x800C3DFC..0x800C3E3C). '
               'Then801343B4 changes the middle child sequence (FF ticks it), '
               'sets the first child modulation from80171594, the middle '
               'child18/19=A0/2 when room+7==1, and last child18/19=22/1. '
               '800C3FBC consumes modulation;800C4180 consumes draw flags.',
        control='next'),
    0x4E: dict(
        name='idtable_state_store',
        operands=[('v', 'b')],
        writes=[0x8016F2A7],
        effect='idtable_state_byte_b (0x8016F2A7) = v.',
        control='next'),
    0x4F: dict(
        name='area_state_handler_install',
        operands=[('sel', 'b'), ('a', 'b'), ('b', 'b')],
        layout='1 byte when sel == 1, otherwise 3 bytes',
        reads=[0x8017C028, 0x801716BC],
        struct_writes=[(0x8017BE20, 0x49C)],
        consumers=[0x80132C04],
        effect='Install the area screen\'s per-frame state handler. sel == 1 is the wait arm: '
               'rewind one byte while event_state_flags & 0x8000 is set. Otherwise the word at '
               '0x801716BC + sel*4 is loaded and jalr\'d with the two remaining operand bytes. '
               'The six live callbacks (0, 2, 3, 4, 5, 6 -> 0x8013584C, 0x80135AE8, 0x80135CF0, '
               '0x80135EA8, 0x80136704, 0x801369E8; slot 1 is a hole for the wait arm) each '
               'allocate the 0x1670-byte trigger-scan work buffer through 0x801352E8 (which '
               'also raises event_state_flags bit 0x8000 and stores the buffer in 0x8017A118) '
               'and then store a handler address into area_state+0x49C: 0x801355EC, 0x80135958, '
               '0x80135B20, 0x80135D20, 0x801365AC and 0x80136754 respectively. That pointer is '
               'loaded and jalr\'d every frame by game_state_driver @0x80132C04 (0x80135344 '
               'clears it when the scan work buffer is freed).',
        control='rewind'),
    0x50: dict(
        name='inventory_item_op',
        operands=[('op', 'b'), ('id', 'b')],
        layout='1 byte, or 2 bytes when op in (0, 1, 2)',
        reads=[0x8017DB24],
        calls=[0x800CA50C, 0x800CA55C, 0x8013875C, 0x80138804, 0x800CA42C],
        consumers=[0x800CA50C, 0x800CA55C, 0x8013875C, 0x80138804, 0x800CA42C],
        effect='Inventory operation: op 0 appends item id with item_array_append 0x800CA50C, '
               'op 1 removes it with item_array_remove 0x800CA55C, op 2 applies the save-buffer '
               'id table -- resolving the id with savebuf_id_table_scan @0x8013875C (78 records '
               'at game_state+0x294, stride 0x50) and testing each entry with '
               'savebuf_id_table_op @0x80138804, which reads the entry halfword +0, indexes the '
               'item table at 0x80167658, tests bits 0x7000 of item+0x1C and returns a 0 / -1 '
               'predicate from the sign of entry+2 -- and on success increments '
               'game_state[0x90 + id] through dialogue_data_table_read 0x800CA42C.',
        control='next'),
    0x51: dict(
        name='transition_vector_build',
        operands=[('tile', 'b'), ('sel', 'b')],
        reads=[0x8017DAA0, 0x8017BD74, 0x8017BD75],
        writes=[0x801716B9, 0x8017DAA8],
        struct_writes=[(0x8017BE20, 0x0BC)],
        calls=[0x800C2D30],
        consumers=[0x8013E7E0, 0x8013B7A0],
        effect='Build a movement/turn command for an area tile descriptor and queue it as a '
               'draw record. The per-direction byte tables are 0x801716DC (dx, signed) and '
               '0x801716E0 (dy, signed) indexed by the second operand; the target is '
               'player_cell_x/y + (dx, dy). The selected 24-byte descriptor '
               '(area_tile_desc_table + tile*24) supplies the current coordinates at +0/+1, and '
               'a 4-byte command block is written into area_state+0xBC terminated by 0x05: '
               '+0xBC = 1 when the descriptor X is left of the target, 3 when right, else 0; '
               '+0xBD = |dx|; +0xBE = 0 when the descriptor Y is above the target, 2 when '
               'below; +0xBF = |dy|; +0xC0 = 0x05. The queued 12-byte record (malloc 0xC, '
               'pointer into the 0x8017DAA8 pointer array at event_text_queue_count++) has '
               'selector +0 = the tile descriptor index and +4 = area_state+0xBC, so '
               'sprite_slot_array_update @0x8013E7E0 reads the command bytes from that buffer; '
               'the same buffer is the destination of partystruct_text_copy_dispatch '
               '@0x8013B7BC.',
        control='next'),
}

# kit/work/variable_labels.csv, kit/docs/memory_map.md and this analysis).
# ---------------------------------------------------------------------------
# apply the field defaults to every entry
for _op, _entry in EFFECTS.items():
    _entry.setdefault('status', 'proven')
    _entry.setdefault('control', 'next')
    _entry.setdefault('reads', [])
    _entry.setdefault('writes', [])
    _entry.setdefault('calls', [])
    _entry.setdefault('operands', [])

GLOBALS = {
    0x801716B8: ('event_upload_mode_801716b8', 1, 'upload countdown set to 4 by op 0x06 and the 0x8013D038 setter; decremented by 0x8013E450'),
    0x801716B9: ('event_text_queue_count', 1, 'count of queued 12-byte draw records; indexes the 0x8017DAA8 pointer array'),
    0x801716BC: ('area_handler_table', 4, 'per-frame area screen handlers indexed by op 0x4F sel; installed into area_state+0x49C'),
    0x80171860: ('scroll_delta_x', 4, 'per-tile horizontal pan deltas; op 0x08 selects with 0x8017A140'),
    0x80171870: ('scroll_delta_y', 4, 'per-tile vertical pan deltas; op 0x08 selects with 0x8017A140'),
    0x801718CC: ('camera_push_record_index', 1, 'op 0x21 operand 1'),
    0x801718CD: ('camera_push_repeats', 1, 'op 0x21 operand 2, decremented per record completion'),
    0x801718CE: ('camera_push_frames', 1, 'per-record frame countdown, = record[4]'),
    0x801718D0: ('camera_push_record_ptr', 4, 'pointer to the active 20-byte camera-offset record at 0x801718D4'),
    0x801718D4: ('camera_offset_records', 1, '20-byte camera-offset records {dx, dy, xmul, ymul, frames}'),
    0x801718FC: ('fade_scan_step_vector', 4, '4-byte {sign, distance} record allocated by op 0x22 sel 3'),
    0x80171A78: ('glyph_page_codes_a', 1, 'per-page glyph code words, 20-byte page stride; read by op 0x36'),
    0x80171B38: ('glyph_page_codes_b', 1, 'second per-page glyph code table; read by op 0x37'),
    0x80171B88: ('scroll_direction_codes', 4, 'direction bit codes 0x1000/0x2000/0x4000/0x8000 selected by the op 0x10 upload parameter'),
    0x80171B98: ('descriptor_transition_params', 4, '4-word transition parameter table (1,3,0,2) read by op 0x11 and the draw-record renderer'),
    0x80171C14: ('event_text_ptr_table', 4, '4-entry pointer table used by op 0x04 (0xFF path)'),
    0x80171C1C: ('event_text_root_a', 4, 'read by op 0x49'),
    0x80171C20: ('event_text_root_b', 4, 'read by op 0x49'),
    0x80171C24: ('event_text_nibble_table_ptr', 4, 'pointer read by op 0x4C'),
    0x80171C28: ('entity_collision_enable_flag', 1, 'cleared by the tick on the 0xF0 path'),
    0x80171C29: ('entity_flag_byte_80171c29', 1, 'per-opcode work flag; set by several handlers'),
    0x80171E24: ('color_sel_byte_80171e24', 1, 'written by op 0x3D'),
    0x80171ED8: ('render_flag_80171ed8', 1, 'written by op 0x3D'),
    0x80171594: ('text_color_sel_80171594', 4, 'set to 0x80 by op 0x25'),
    0x8016F2A7: ('idtable_state_byte_b', 1, 'written by op 0x4E'),
    0x8017A120: ('text_metrics_ptr', 4, 'event slot struct; read by op 0x26'),
    0x8017A128: ('frame_driver_word_8017a128', 4, 'current16-byte room record; +0x0C text table used by op 0x04'),
    0x8017A130: ('scroll_accum_x', 2, 'set from op 0x08 (b1*8)'),
    0x8017A138: ('scroll_accum_y', 2, 'set from op 0x0A (b0*5)'),
    0x8017A140: ('scroll_target_x', 1, 'set from op 0x08 (b0)'),
    0x8017A148: ('sprite_upload_type', 1, '8-entry selector array; op 0x06 / 0x8013D038 fill it, 0x8013E450 consumes it'),
    0x8017A150: ('sprite_upload_param', 1, '8-entry parameter index; consumed at 0x8013E4BC / 0x8013E544'),
    0x8017A158: ('sprite_upload_enable', 1, '8-entry enable gate; consumed at 0x8013E4BC'),
    0x8017A160: ('sprite_batch_byte_8017a160', 1, 'set to 1 by op 0x10'),
    0x8017A168: ('h2da_byte_8017a168', 1, 'vertical pan direction code (0/2) from op 0x10'),
    0x8017A170: ('pan_remaining_y', 1, 'vertical pan distance from op 0x10'),
    0x8017A180: ('event_reloop_flag', 1, '1 = the tick re-loops for another opcode, 0 = yield'),
    0x8017A240: ('render_work_word_a240', 4, 'written by op 0x3D'),
    0x8017AAE4: ('area_header_ptr', 4, 'area header; +0x24 count, +0x1C/+0x20 file tables, +0x94 obj base'),
    0x8017AF84: ('event_stream_ptr', 4, 'the VM cursor'),
    0x8017AF94: ('sysfont_desc_table', 4, '24-byte scripted entity array (built by op 0x34; legacy symbol name)'),
    0x8017BD6C: ('ui_state_mode_byte', 1, 'selects a switch arm in op 0x15 / 0x2F'),
    0x8017BD74: ('player_cell_x', 1, 'fixed Hero cell X; read by op 0x10, written by the op 0x21 camera push, read as a descriptor by op 0x07'),
    0x8017BD75: ('player_cell_y', 1, 'fixed Hero cell Y; read by op 0x10, written by the op 0x21 camera push'),
    0x8017BD76: ('camera_offset_x', 1, 'set to record[2]*record[4] by the op 0x21 camera push (0x8013FFE8)'),
    0x8017BD77: ('camera_offset_y', 1, 'set to record[3]*record[4] by the op 0x21 camera push'),
    0x8017BD79: ('text_effect_flag', 1, 'cleared by op 0x1A/0x1B, set to 2 by op 0x21 and 0x32/0x36 consumers'),
    0x8017BD7C: ('h2da_probe_obj_0', 4, 'page selector for the glyph code tables 0x80171A78/0x80171B38; read by op 0x36/0x37'),
    0x8017BDCC: ('scroll_direction_code', 4, 'direction bit code (0x1000/0x2000/0x4000/0x8000) applied by 0x8012C860'),
    0x8017BE20: ('area_state_ptr', 4, 'area/runtime state struct'),
    0x8017BE4C: ('pad_pressed_edge', 4, 'edge-triggered pad bits; polled by op 0x02/0x05'),
    0x8017BF00: ('event_opcode_shadow', 1, 'text effect parameter stored by op 0x1A/0x1B'),
    0x8017BF7C: ('obj_array_count', 4, 'count for the table built by op 0x34 (sysfont_desc_table)'),
    0x8017BFDC: ('dialogue_sprite_word_8017bfdc', 4, 'dialogue box sprite handle; produced by op 0x05, rendered by sprite_manager_tick @0x8013E2A8 via sprite_render_dispatch @0x80144B60'),
    0x8017BFE4: ('transition_flag_8017bfe4', 1, 'set by op 0x26 when text metrics bit 0x10'),
    0x8017C008: ('camera_scroll_x', 4, 'set from op 0x26 (b0*8)'),
    0x8017C010: ('camera_scroll_y', 4, 'set from op 0x26 (b1*8)'),
    0x8017C018: ('dialogue_box_state', 1, 'dialogue box style/selection byte (0xFF = box not built); op 0x05 drives it, sprite_manager_tick @0x8013E290 gates the render on it'),
    0x8017C028: ('event_state_flags', 2, 'bit-mapped VM/engine mode flags'),
    0x8017C038: ('tile_entry_table_ptr', 4, 'tile entry array, 12 bytes/entry'),
    0x8017C050: ('event_buf_word_c050', 4, 'pointer to the op0x0D twelve-byte entry array'),
    0x8017C09C: ('tile_entry_count', 4, 'written by op 0x3E'),
    0x8017C0A4: ('transition_struct', 1, 'transition tile/dir struct freed by op 0x1E'),
    0x8017C0BC: ('teardown_word_c0bc', 4, 'entry count for the op0x0D array'),
    0x8017C108: ('area_struct_ptr', 4, 'area struct; +0x14 = dialogue text root'),
    0x8017C164: ('game_state_copy_ptr', 4, 'cached copy of the game-state pointer'),
    0x8017DA40: ('render_work_byte_40', 1, 'written by op 0x3D'),
    0x8017DA41: ('render_work_byte_41', 1, 'written by op 0x3D'),
    0x8017DA42: ('render_work_byte_42', 1, 'written by op 0x3D'),
    0x8017DAA0: ('area_tile_desc_table', 4, '24-byte per-area entity array (legacy symbol name)'),
    0x8017DAA8: ('draw_record_ptrs', 4, 'array of pointers to 12-byte draw records (4-byte stride); filled by ops 0x32/0x36/0x37/0x51, consumed by 0x8013E7E0'),
    0x8017DB24: ('game_state_ptr', 4, 'pointer to the game-state struct at 0x801B8000'),
    0x8017DBB0: ('sprite_slot_table', 4, '20-byte sprite/event slot array'),
    0x8017DBB4: ('sprite_slot_flags', 1, 'busy flag per slot, stride 20'),
    0x8017DBB5: ('sprite_slot_byte_b5', 1, 'slot sub-state, stride 20'),
    0x8017DBBC: ('event_word_dbbc', 4, 'secondary slot word, stride 20'),
    0x8017DBC0: ('event_slot_word_dbc0', 4, 'op 0x12 per-slot status word (0 -> 1 starts the wait), stride 20'),
    0x8017DBC4: ('dialogue_word_dbc4', 4, 'sprite-text struct for dialogue box 1'),
    0x8017DBC8: ('dialogue_byte_dbc8', 1, 'busy byte for dialogue box 1'),
    0x8017DBCA: ('dialogue_layout_a', 1, 'written by op 0x35'),
    0x8017DBCC: ('dialogue_layout_b', 1, 'written by op 0x35'),
    0x8017DBD0: ('dialogue_word_dbd0', 4, 'cleared when dialogue box 1 is opened'),
    0x8017DC4C: ('game_driver_word_dc4c', 4, 'set to 1 by the tick 0xF0 path'),
}

# Engine functions the handlers call (from kit/work/function_labels.csv plus the
# reads in this analysis).
CALL_NAMES = {
    0x800C2D30: 'malloc',
    0x800C2DC0: 'free',
    0x800C2FA4: 'cd_sync_then_read',
    0x800C30E4: 'cd_poll_wrap',
    0x800C39E4: 'set_config_byte2',
    0x800C39F4: 'set_config_byte3',
    0x800C3D38: 'obj_alloc_init',
    0x800C3D8C: 'free_wrapper',
    0x800C3DAC: 'obj_initializer',
    0x800C4864: 'file_slot_alloc',
    0x800C48D4: 'file_loader_by_id',
    0x800C4954: 'file_data_copy_20k',
    0x800C49B8: 'file_object_setup',
    0x800C4AFC: 'savebuf_char_entry_remove_a',
    0x800C4BFC: 'savebuf_char_entry_add',
    0x800C4C30: 'savebuf_char_entry_remove_b',
    0x800C4DB4: 'dialogue_cmd_issuer_0501',
    0x800CA2F0: 'dialogue_table_scan',
    0x800CA408: 'dialogue_data_access_wrap',
    0x800CA42C: 'dialogue_data_table_read',
    0x800CA50C: 'item_array_append',
    0x800CA55C: 'item_array_remove',
    0x800CA60C: 'byte_threshold_classifier',
    0x800E9CC4: 'battle_tick_counter_advance',
    0x8012C598: 'struct_triple_free',
    0x8012CBBC: 'be20_flag_bytes_set',
    0x8012E308: 'tile_query_xy_layer',
    0x8012EBA8: 'struct_triple_free_entry',
    0x8012EBDC: 'tile_entry_table_rebuild',
    0x8012F828: 'obj_table_lookup_by_ptr',
    0x8012C860: 'scroll_direction_dispatch',
    0x80133184: 'savebuf_char_remove_recruit_toggle',
    0x80133698: 'palette_table_upload',
    0x801337B8: 'sprite_colorize_upload_driver',
    0x80133BB4: 'char_encoding_translate',
    0x80133F50: 'text_color_pair_driver',
    0x801343B4: 'transition_dir_struct_setup',
    0x80138410: 'dialogue_cleanup_wrap',
    0x801384B8: 'tile_entry_object_sync',
    0x8013875C: 'savebuf_id_table_scan',
    0x80138804: 'savebuf_id_table_op',
    0x80138FB0: 'flag_pair_dispatch',
    0x801395FC: 'char_recruit_count_total',
    0x80139E10: 'party_formation_sync',
    0x8013A038: 'party_slot_char_set',
    0x8013A0C0: 'party_item_assign_handler',
    0x8013A770: 'party_member_obj_alloc_by_id',
    0x8013A808: 'c164_countdown_struct_init',
    0x8013AFA0: 'text_char_decoder',
    0x8013B0C8: 'dialogue_layout_calc',
    0x8013B2F4: 'event_obj_sprite_setup_indexed',
    0x8013B7A0: 'partystruct_text_copy_dispatch',
    0x8013C750: 'event_record_field_copy',
    0x8013C7A4: 'byte_value_dispatch',
    0x8013CCF0: 'descriptor_state_transition',
    0x8013D038: 'sprite_upload_block_set_slot0',
    0x8013F6B4: 'dialogue_textbuf_clear',
    0x8013FF5C: 'camera_push_record_apply',
    0x80140018: 'camera_push_apply',
    0x80140068: 'camera_push_tick',
    0x801404B8: 'fade_scan_reset',
    0x80140860: 'fade_scan_set_mode1',
    0x80140888: 'fade_scan_start_2',
    0x8014095C: 'fade_scan_step_vector',
    0x801352E8: 'trigger_scan_work_alloc',
    0x80135388: 'trigger_entry_coord_compute',
    0x80141814: 'ui_state_dispatcher',
    0x80142440: 'area_index_set_reset_driver',
    0x80142C38: 'render_context_setup',
    0x801441B0: 'ui_quad_elem_alloc',
    0x80144620: 'sprite_quad_packet_build',
    0x80144C24: 'sprite_obj_free',
    0x80145194: 'sprite_text_struct_alloc',
    0x80145644: 'sprite_flag_set_state',
    0x80146BB4: 'bytecode_interpreter',
    0x80146DFC: 'tile_grid_packet_init',
    0x80146FE8: 'num_to_cmd_and_interpret',
    0x8014695C: 'sprite_text_string_runner',
    0x80145DE8: 'struct_byte4_set',
    0x80146934: 'sprite_flag_clear_bit11',
    0x80146A28: 'struct_flag_set_200',
    0x80144B60: 'sprite_render_dispatch',
    0x80148590: 'gpu_loadimage_wrap',
    0x800C3C5C: 'vram_upload_strip_a',
    0x800C3CC8: 'vram_upload_strip_b',
    0x801343B4: 'transition_dir_struct_setup',
    0x800C3DAC: 'obj_initializer',
    0x80133514: 'rgb15_pixel_convert',
    0x80133618: 'rgb15_bulk_convert',
}


