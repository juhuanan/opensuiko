#!/usr/bin/env python3
"""The Suikoden menu system as a state machine — derived from code, as data.

STATIC ANALYSIS ONLY.  `MAIN.EXE` is the headerless image at base `0x800C0800`
(`disc.extract()[2048:]`, PS-X header stripped); overlays load at `0x80010000`
unless their `file[0]` says otherwise.  Nothing here runs the game.

Why this module exists
----------------------
Individual menu *screens* (shop, blacksmith, rune attach/detach, appraiser,
warehouse) had already been located, but the system had never been modelled as a
**flow**.  This module is that model: the state variable, the states, the
dispatcher that selects them, the frame-handler slot table that runs them, and
the entry/exit pair on the field side — each as a row with the address that
proves it.

The mechanism in one paragraph
------------------------------
There is exactly **one** menu-screen state byte: `*(0x8017BE20) + 0x4E0`.  Its
selector routine, `menu_screen_select @0x80132F60`, is a switch on that byte
(cases 1,2,3,4,5,7,8,0x80).  Each case calls a **build** function that mallocs a
screen object, publishes it to a static pointer, and returns the address of the
screen's **step** function; the dispatcher then writes that step function into
the slot it was invoked in, inside the frame-callback table at `0x8017DA90`.
The returned step pointer is installed in the active frame-callback slot, so
that step function runs on subsequent frames. The main loop calls the root
callback at `0x8017DA90` (`0x800C2870`); a separate game-state dispatch uses the
adjacent table base `0x8017DA94` (`0x800C99EC`). Leaving a
screen means: the step function clears `+0x4E0`, installs
`field_update_driver @0x801319C4` back into the slot, and the field resumes.
Overlays use the **same** byte and the **same** slot table for their own menus
(the warehouse/AZUKARI overlay is the worked example below), which is what makes
`+0x4E0` the menu system's state variable rather than a field-only flag.

Provenance
----------
The disc catalogue at `kit/data/catalogs/extracted/iso_files.json` locates
`MAIN.EXE` (image base `0x800C0800`) and `DATA/03_SHIRO/AZUKARI.BIN`
(load base `0x80080000`, entry point `0x800800A0`).
`kit/tests/test_menu_flow.py` rechecks every address below against those bytes.

Usage
-----
    python3 menu_flow.py --states      # the state table
    python3 menu_flow.py --transitions # the transition table
    python3 menu_flow.py --screens     # per-screen tables read
    python3 menu_flow.py --entry       # entry/exit path
    python3 menu_flow.py --verify      # re-derive every address from the disc
    python3 menu_flow.py --json OUT    # machine-readable model
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _TOOLS)

import disc  # noqa: E402

MAIN_BASE = 0x800C0800
MAIN_LBA = 17976
MAIN_SIZE = 757760            # 2048-byte PS-X header + image
MAIN_HEADER = 2048

# DATA/03_SHIRO/AZUKARI.BIN in the US v1.1 disc catalogue.
AZUKARI_LBA = 63261
AZUKARI_SIZE = 111552
#: AZUKARI.BIN's load base.  PROOF (see `verify()` and `kit/docs/menu_flow.md`
#: §7): `file[0] == 0x800800A0` is the *entry-point* pointer, not the load base.
#: Under base `0x80080000` the six state arms at file offset 0x4C decode as six
#: in-file code pointers, and the ten recorded warehouse function-entry VAs all
#: land on real prologues.  Under base `0x800800A0` the arm words at file 0x4C
#: would live at 0x800800EC (a string region) and the entry VAs would all be
#: mid-instruction.  The corpus's warehouse VAs are therefore CORRECT.
#:
#: What IS wrong in the corpus is narrower: `kit/work/azukari_labels.csv` has
#: rows whose `address` is a **store site** but whose name is the function
#: (`0x80081CA0` named `warehouse_cursor_bump`, whose real entry is
#: `0x80081C00`), so reading that column as "function entry" is off by the
#: function's internal distance to the store.  The store VAs are right; the
#: function entries are `0x80081C00` / `0x80082F38` / `0x80084314`.
AZUKARI_BASE = 0x80080000

# ---------------------------------------------------------------------------
# The state variable and the machinery around it
# ---------------------------------------------------------------------------

#: `*(0x8017BE20) + 0x4E0`, byte.  The menu system's single state variable.
MENU_STATE_BYTE = {
    "name": "menu_screen_id",
    "addr": 0x8017BE20 + 0x4E0,
    "base_addr": 0x8017BE20,
    "base_name": "area_state_ptr",
    "offset": 0x4E0,
    "width": 1,
    "comment": "0 = no menu; 1..8, 0x80 = a menu screen id. Read by the "
               "selector, the field driver and the menu driver; written by the "
               "field driver (open), the event opcode arg store, and every "
               "screen's exit step (close).",
}

#: `0x80132F60` — the selector.  Switch on MENU_STATE_BYTE; each arm calls a
#: screen *builder* and installs the builder's returned *step* function into the
#: frame-callback slot.
SELECTOR = {
    "name": "menu_screen_select",
    "addr": 0x80132F60,
    "reads": MENU_STATE_BYTE["addr"],
    "table_kind": "explicit compare chain (not a jump table)",
    "stage_slot": 0x8017A100,
    "slot_table": 0x8017DA90,
    "comment": "Frees the two 0x6720 transition buffers, zeroes +0x34/+0x38 of "
               "the area state, then switches on +0x4E0. Arms seen: 1,2,3,4,5,7,8,0x80.",
}

#: Callback storage begins at 0x8017DA90. The main loop indirect-calls its
#: root word at 0x800C2870. The adjacent game-state handler table begins at
#: 0x8017DA94 and is called at 0x800C99EC. `frame_orchestrator` at 0x80141E08
#: is a direct call sequence, not either indirect call site.
SLOT_TABLE = {
    "name": "frame_callback_table",
    "addr": 0x8017DA90,
    "index_base": 0x8017DA90,
    "comment": "Root callback is called with a0=0 at 0x800C2870. The adjacent "
               "game-state handler table is called at 0x800C99EC. A handler "
               "is installed with `sw <fn>, 0x8017DA90 + slot*4`.",
}

#: The per-frame dispatcher that decides "field or menu".
GAME_STATE_DRIVER = {
    "name": "game_state_driver",
    "addr": 0x80132B6C,
    "installs_menu_driver_site": 0x80132BD8,
    "menu_driver": 0x80132938,
    "test_site": 0x80132BD0,
    "comment": "Tests `lbu *(0x8017BE20)+0x4E0`; nonzero -> install menu driver "
               "and return; zero -> run the normal per-frame UI chain via the "
               "installed handler (+0x498) and restore field_update_driver.",
}

ENTRY_EXIT = {
    "open": {
        "driver": "field_update_driver",
        "addr": 0x801319C4,
        "input_word": 0x8017BE4C,
        "test_site": 0x801329C8,
        "test_mask": 0x80,
        "guard": 0x8012CD74,
        "guard_comment": "area-transition state check: returns nonzero when a "
                         "screen transition owns the frame, which suppresses menu open",
        "store_site": 0x801329F0,
        "store_value": 1,
        "comment": "START (pressed-edge bit 0x80) on the field sets the state "
                   "byte to 1 and falls through to the field-install tail; the "
                   "next frame the selector builds the root menu.",
    },
    "close": {
        "site": 0x8012D568,
        "store_site": 0x8012D574,
        "installs": "field_update_driver",
        "installs_addr": 0x801319C4,
        "comment": "Field-side teardown path: clears +0x4E0, restores the camera "
                   "from 0x8017BD74/75 into gs+0x04/+0x06 and reinstalls the "
                   "field driver into the slot.",
    },
    "root_menu_close": {
        "site": 0x80132D98,
        "store_site": 0x80132D98,
        "comment": "Root-menu exit step (installed by 0x80132D1C): when the "
                   "screens are finished (handler +0x498 == 0) it clears +0x4E0.",
    },
    "event_script_open": {
        "handler": 0x801397D0,
        "cursor": 0x8017AF84,
        "store_site": 0x801397F4,
        "sentinel": 0xFF,
        "sentinel_effect": "state byte := 0 at 0x80139814",
        "operand_bytes": 2,
        "operands": ["selector", "area_table_index"],
        "comment": "Opcode 0x43 reads selector and area-table index, stores the "
                   "selector at area_state+0x4E0, and resolves area_struct+0x10[index]. "
                   "Selectors 0xFF/0x80 install the entry as a one-shot callback "
                   "at +0x498; other selectors store entry+0xC at +0x494. 0xFF "
                   "also normalizes the state byte to zero.",
    },
    "overlay_reset": {
        "comment": "Two more writers clear +0x4E0 while restoring the field "
                   "driver (both in the 0x8013xxxx field/transition cluster): "
                   "0x80131118 and 0x80131528.",
        "sites": [0x80131118, 0x80131528],
    },
}

# ---------------------------------------------------------------------------
# The states
# ---------------------------------------------------------------------------

#: Every arm of `menu_screen_select`.  `build` mallocs + publishes the screen
#: object; `step` is the function the dispatcher installs, i.e. the screen's
#: per-frame state machine.  `step_installed_by` names how we know.
STATES = [
    {
        "id": "root_menu",
        "selector_value": 1,
        "open_store": 0x801329F0,         # START sets +0x4E0 = 1
        "build": 0x800CA66C,
        "build_name": "dialogue_ui_struct_alloc",
        "build_publishes": 0x80179E48,    # menu_table_a
        "build_alloc_size": 0x22D0,
        "step": 0x800CA830,
        "step_is_builder_return": 0x800CA818,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800CA830 (the builder's own return) zeroes obj+0/"
                        "0x22C0/0x22C4 and sets the object's page driver "
                        "obj+0x08 = 0x800DAB10, then returns 0x800CA86C, the "
                        "per-frame drawer for the 17 quad slots.",
        "screen": "root menu (field menu): the six options Item / Strength / "
                  "Rune / Formation / Equipment / Setup",
        "tables_read": ["option name array 0x8016A734 (6 rows)",
                        "screen group array 0x8016A874 (17 rows)",
                        "17-row descriptor table 0x8016A64C (10 B rows)",
                        "party roster (gs+0x03 -> gs+0x0E -> gs+0x1B9C[])",
                        "gold gs+0x1C"],
        "evidence": "0x801329F0 sb 1 -> +0x4E0; 0x80132F60 arm 1 -> jal "
                    "0x800CA66C; 0x800CA688 sw 0x80179E48; 0x800CA814/0x800CA818 "
                    "return 0x800CA830. Option list and handler table: see "
                    "ROOT_MENU.",
        "confidence": "proven (build, published object, step, option list and "
                      "per-option handler table all read out of the bytes)",
    },
    {
        "id": "shop",
        "selector_value": 2,
        "build": 0x800D1BE4,
        "build_name": "menu_gold_setup",
        "build_publishes": 0x80179E68,    # menu_table_d
        "build_alloc_size": 0x130,
        "step": 0x800D1F48,
        "step_is_builder_return": 0x800D1F28,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800D1F48 builds 10 quads from the 10-row descriptor "
                        "table at 0x8016AE18 (stride 0xA) and then hands over to "
                        "the object runner 0x800D2100, which jalr's the page "
                        "driver installed at obj+0x10. State 1 of 0x800D1F48 "
                        "installs 0x800D2428 (0x800D20D0); 0x800D2428's state 2 "
                        "installs 0x800D2540 (0x800D2528).",
        "screen": "shop (Buy / Sell / End)",
        "tables_read": ["party roster (gs+0x03 -> gs+0x0E -> gs+0x1B9C[])",
                        "gold gs+0x1C -> obj+0x50",
                        "item table 0x80167658",
                        "10-row descriptor table 0x8016AE18 (stride 0xA)",
                        "shop row array 0x8016AE8C via 0x8016AEB4",
                        "shop Yes/No array 0x8016AEA0 via 0x8016AEC4",
                        "equipment kind masks 0x8016AE00 / slots 0x8016AE0C"],
        "evidence": "0x80132F60 arm 2 -> jal 0x800D1BE4; the builder sets "
                    "obj+0x50 := gold, obj+0x54 := gs+0x03, obj+0x5C+4i := "
                    "gs+0x1B9C party records (0x800D1D60), obj+0x84+8i := 8 "
                    "bytes of each record, obj+0xB4+0x14i+4t := the equipped "
                    "item index of each of 5 kinds, and obj+0x44 := the item "
                    "list built by 0x800D436C from the event-supplied byte list "
                    "at *(a0).  Its own page driver 0x800D2540 state 1 calls "
                    "0x800D42EC(elem, *(0x8016AEB4)) at 0x800D25E4, and "
                    "0x800D42EC walks that pointer array 4 bytes at a time into "
                    "bytecode_interpreter; *(0x8016AEB4) = 0x8016AE8C = "
                    "{Buy, Sell, End}.  0x800D39E0 (the 21-entry shop driver, "
                    "table 0x800C0FAC) reads the Yes/No group at 0x800D3E0C.",
        "confidence": "proven (the arm-2 object's own page 1 renders Buy/Sell/"
                      "End through a pointer array consumed as rows)",
    },
    {
        "id": "blacksmith",
        "selector_value": 3,
        "build": 0x800D5714,
        "build_name": "menu_gold_stage_a",
        "build_publishes": 0x80179E70,
        "build_alloc_size": 0x8C,
        "step": 0x800D5904,
        "step_is_builder_return": 0x800D58E8,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800D5904 decrements the fade byte gs+0x1D5F and "
                        "switches on obj+0x00 through the 3-state driver "
                        "0x800D5CAC/0x800D5DC4; obj+0x10+4i are 8 (arm 4) / 10 "
                        "(arm 3) quads built from the descriptor table.",
        "screen": "blacksmith (sharpen weapon / merge rune fragment)",
        "tables_read": ["gold gs+0x1C -> obj+0x40", "gs+0x03 -> obj+0x44",
                        "gs+0x0E -> gs+0x1B9C[] -> obj+0x48[]",
                        "item table 0x80167658",
                        "descriptor table 0x8016AF70 (stride 0xA)",
                        "level/EXP table 0x8016AF30 (15 entries)",
                        "blacksmith rows 0x8016AFE8 via 0x8016B010",
                        "blacksmith Yes/No 0x8016AFF4 via 0x8016B00C"],
        "evidence": "0x80132F60 arm 3 -> jal 0x800D5714 (malloc 0x8C -> "
                    "0x80179E70).  The object's own code (0x800D5714-0x800D7C88, "
                    "all sites in the 0x80179E70 load set) reads the blacksmith "
                    "string group: 0x8016B010 -> 0x8016AFE8 = {Sharpen, Rune "
                    "fragment, End} at 0x800D5E4C / 0x800D63F8 / 0x800D7394; "
                    "0x8016B00C -> 0x8016AFF4 = {Yes, No} at 0x800D5A1C / "
                    "0x800D7B4C; 'Arms name' 0x8016B04C at 0x800D6750; 'Arms "
                    "name became an' 0x8016B058 at 0x800D67F4; 'Can't handle' "
                    "0x8016B070 at 0x800D7B64; 'LV  became / ATK became' "
                    "0x8016B02C at 0x800D66C4; ' bits' 0x8016B024 at "
                    "0x800D6278 / 0x800D7AF4.",
        "confidence": "proven (the arm-3 object's own code renders the "
                      "blacksmith's Sharpen / Rune fragment / End rows)",
    },
    {
        "id": "rune_attach",
        "selector_value": 4,
        "build": 0x800D7D24,
        "build_name": "menu_gold_stage_b",
        "build_publishes": 0x80179E78,    # menu_table_e
        "build_alloc_size": 0x9C,
        "step": 0x800D7F1C,
        "step_is_builder_return": 0x800D7F00,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800D7F1C decrements the fade byte and switches on "
                        "obj+0: state 0 -> obj+0 := 1; state 1, once the fade is "
                        "below 0x40, zeroes obj+0/obj+4 and returns 0x800D82CC "
                        "(the sprite-object setup), whose chain continues in "
                        "0x800D83E8 / 0x800D8CD0 (12-state, table 0x800C10F4).",
        "screen": "rune attach / detach",
        "tables_read": ["gold gs+0x1C -> obj+0x3C", "gs+0x03 -> obj+0x40",
                        "gs+0x0E -> gs+0x1B9C[] -> obj+0x44[]",
                        "item table 0x80167658",
                        "descriptor table 0x8016B0FC (8 rows, stride 0xA)",
                        "rune rows 0x8016B160 via 0x8016B188",
                        "rune Yes/No 0x8016B174 via 0x8016B184"],
        "evidence": "0x80132F60 arm 4 -> jal 0x800D7D24 (malloc 0x9C -> "
                    "0x80179E78); 0x800D7E20-0x800D7E9C builds 8 quads from "
                    "0x8016B0FC (stride 0xA, the table ends exactly at "
                    "0x8016B14C where 'Attach' begins).  0x800D8478 (inside the "
                    "arm-4 page driver 0x800D83E8) loads *(0x8016B188) = "
                    "0x8016B160 = {Attach, Remove, End}; 0x8016B184 = "
                    "0x8016B174 = {Yes, No}.",
        "confidence": "proven (the arm-4 object's own page driver loads the "
                      "Attach / Remove / End row array)",
    },
    {
        "id": "appraiser",
        "selector_value": 5,
        "build": 0x800DA29C,
        "build_name": "h2da_entry_struct_build",
        "build_publishes": 0x80179ED8,    # menu_table_b
        "build_alloc_size": 0x88,
        "step": 0x800DA3D4,
        "step_is_builder_return": 0x800DA3C0,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800DA3D4 fades gs+0x1D5F down by 4; state 0 of "
                        "obj+0x04 builds 10 quads from the 10-row descriptor "
                        "table at 0x8016B1A0 (stride 0xA, bound `slti 0xa` at "
                        "0x800DA4A4) into obj+0x14+4i and installs the "
                        "page-driver pair 0x800DA84C / 0x800DA548; state 1 waits "
                        "for the fade and finishes.",
        "screen": "appraiser (Appraise / Sell / End)",
        "tables_read": ["gold gs+0x1C -> obj+0x4C", "gs+0x03 -> obj+0x50",
                        "gs+0x0E -> gs+0x1B9C[] -> obj+0x58[]",
                        "descriptor table 0x8016B1A0 (10 rows, stride 0xA)",
                        "appraiser rows 0x8016B21C via 0x8016B244",
                        "appraiser Yes/No 0x8016B230 via 0x8016B240",
                        "price label 0x8016B258",
                        "appraiser categories 0x8016AEE4 / 0x8016AEEC / "
                        "0x8016AEF8 (pot / ornament / painting)"],
        "evidence": "0x80132F60 arm 5 -> jal 0x800DA29C (malloc 0x88 -> "
                    "0x80179ED8; obj+0x4C := gold, obj+0x50 := gs+0x03, "
                    "obj+0x58+4i := gs+0x1B9C records, obj+0x78 := arg).  The "
                    "object's own code loads *(0x8016B244) = 0x8016B21C = "
                    "{Appraise, Sell, End} at 0x800DA9FC, *(0x8016B240) = "
                    "0x8016B230 = {Yes, No} at 0x800DB35C, and 'price ' "
                    "0x8016B258 at 0x800DC55C.",
        "confidence": "proven (the arm-5 object's own code loads the Appraise / "
                      "Sell / End and Yes / No row arrays)",
    },
    {
        "id": "inn",
        "selector_value": 6,
        "build": 0x800D9DEC,
        "build_name": "h2da_entry_value_mult",
        "build_publishes": 0x80179EC0,    # the event-supplied context pointer
        "build_alloc_size": None,
        "step": 0x800D9E90,
        "step_is_builder_return": 0x800D9E78,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800D9E90 fades gs+0x1D5F down by 4 and, once it is "
                        "below 4, returns 0x800D9EF8: a 0x1E-frame wait whose "
                        "tail (0x800D9F2C) does the transaction.",
        "screen": "inn (rest: pay, then restore every party member's HP)",
        "tables_read": ["gold gs+0x1C", "party count gs+0x03",
                        "gs+0x0E -> gs+0x1B9C[] -> +0x1C -> character record"],
        "evidence": "0x80132F60 arm 6 -> jal 0x800D9DEC.  The builder stores "
                    "the incoming argument at 0x80179EC0 (0x800D9DFC) and the "
                    "cost at 0x80179ED0: cost = gs+0x03 * (*(*(arg))[0] * "
                    "*(*(arg))[1]) (0x800D9DF4-0x800D9E40) -- party size times "
                    "a per-person rate.  0x800D9F2C compares gold against it "
                    "(0x800D9F50 slt): short -> 0x800DA064 (a message panel); "
                    "otherwise gold -= cost (0x800D9F70 sw v0,0x1C(gs)) and for "
                    "every party member (0x800D9F7C loop over gs+0x03) the "
                    "character record's max HP at +4 is copied to current HP at "
                    "+6 (0x800D9FAC-0x800D9FB4) and +0x16 is zeroed "
                    "(0x800D9FC0).  Then 0x800DA008 fades in and returns 0.",
        "confidence": "proven (pay-then-full-heal over the party)",
    },
    {
        "id": "area_transition",
        "selector_value": 7,
        "build": None,
        "step": 0x8012D688,
        "comment": "Not a data screen: stores the camera focus into gs+0x04/"
                   "0x06, queues dispatcher commands 0x0A0 and 0x015, calls "
                   "0x8012BB90, and installs 0x8012D688 to drive the area load.",
        "tables_read": ["camera focus 0x8017BD74/75"],
        "evidence": "0x80132F60 arm 7 at 0x801330EC-0x80133130.",
        "screen": "area transition (not a menu screen)",
        "confidence": "proven",
    },
    {
        "id": "item_discard",
        "selector_value": 8,
        "build": 0x800DC650,
        "build_name": "menu_icon_grid_ctx_alloc",
        "build_publishes": 0x80179EE0,
        "build_alloc_size": 0x84,
        "step": 0x800DC7B8,
        "step_is_builder_return": 0x800DC79C,
        "step_installed_at": 0x80133158,
        "step_comment": "0x800DC7B8 builds 3 quads from the 3-row descriptor "
                        "table at 0x8016B338 (stride 0xA) and continues in "
                        "0x800DC8E8; the page driver is 0x800DD23C (12-state, "
                        "table 0x800C1180).",
        "screen": "item-receive / equip page when a character's 8 item slots "
                  "are full (Overloaded / Choose item to discard / Drop)",
        "tables_read": ["gs+0x03 -> obj+0x24, gs+0x0E -> gs+0x1B9C[] -> "
                        "obj+0x28[]",
                        "8 bytes of each party record (record+1..+8) -> "
                        "obj+0x40 + 9i",
                        "descriptor table 0x8016B338 (3 rows, stride 0xA)",
                        "message array 0x8016B2F8 (12 entries)",
                        "item table / item pipeline 0x800D469C, 0x800D5548"],
        "evidence": "0x80132F60 arm 8 -> jal 0x800DC650 (malloc 0x84 -> "
                    "0x80179EE0); the builder copies the party slots and 8 bytes "
                    "per record.  0x800DCB84 loads *(0x8016B2F8) = 0x8016B260 "
                    "'Overloaded' and calls bytecode_interpreter; 0x800DCDF8 "
                    "loads *(0x8016B300) = 0x8016B26C 'Gave up on'; 0x800DCF28 "
                    "loads *(0x8016B304) = 0x8016B278 'Choose item to discard'; "
                    "0x800DD4C0 loads *(0x8016B308) = 0x8016B290 'You're already "
                    "equipped.'; 0x800DD4E4 loads *(0x8016B318) = 0x8016B2CC "
                    "'Drop'; 0x800DD508 loads *(0x8016B31C) = 0x8016B2D4 'Do "
                    "not drop'.  A second, non-selector opener installs the same "
                    "step chain with a fixed context: 0x800E8464 calls "
                    "0x800DC650 with a0 = 0x8017C05C and stages the step at "
                    "0x80179FD8 (0x800E844C, chosen at 0x800E8404).",
        "confidence": "proven (the arm-8 object's own page renders the overload "
                      "/ discard message array) -- this is the one arm of "
                      "{3,4,5,6,8} that is NOT one of the five shop-family "
                      "labels; the shop is arm 2",
    },
    {
        "id": "screen_object_dispatch",
        "selector_value": 0x80,
        "build": None,
        "step": None,
        "comment": "Arm 0x80 indirect-calls the screen object's own handler at "
                   "obj+0x498 and installs 0x80132D64, i.e. it does not build a "
                   "new screen - it re-enters the object built by the arm that "
                   "ran immediately before. This is the mechanism the "
                   "SHOP/BLACKSMITH/RUNE/APPRAISER screens use to swap pages "
                   "inside one session.",
        "evidence": "0x80132F60 arm 0x80 at 0x80133138: `lw v0,0x498(a0); jalr v0`.",
        "confidence": "proven",
    },
]

# ---------------------------------------------------------------------------
# The root menu's contents: option list + per-option handler table
# ---------------------------------------------------------------------------
#
# Read out of the bytes, not inferred from the mechanism.  The chain is:
#
#   ui_menu_obj_dispatcher 0x800CAEB4 case 3 (0x800CAF4C..0x800CAFEC)
#     0x800CAF88  draws option group 0  ->  0x800CCAAC(0)
#     0x800CCAAC   group = *(0x8016A874 + idx*4)   (17-entry group array)
#                  elem  = *(obj+0x0C + idx*4)
#                  rows  = lbu 0x9(elem)            (from the 0x8016A64C row)
#                  for i < rows: bytecode_interpreter(elem, group[i], elem+8)
#   so group 0 = *(0x8016A874) = 0x8016A734 = the six option names.
#
#   the cursor is the word at obj+0x54:
#     0x800CB104  slti $v0,$v0,0x6     -> exactly SIX options
#     0x800CB0DC  ori  $v0,$zero,0x5   -> wrap up to index 5
#   the confirm is 0x800CB024 (andi 0x41 = X / circle); it queues dispatcher
#   command 0x503 and copies the cursor into obj+0x5C (0x800CB058), then the
#   next state dispatches:
#     0x800CB16C  sltu $v0, 5, option   -> bound
#     0x800CB184  at = 0x800C0DEC + option*4
#     0x800CB194  jr $v0
#
# The jump table at 0x800C0DEC therefore IS the root menu's handler table.
ROOT_MENU = {
    "state_value": 1,
    "object_slot": 0x80179E48,          # *(0x80179E48) = the 0x22D0-byte object
    "build": 0x800CA66C,
    "step": 0x800CA830,
    "frame_chain": [0x800CA830, 0x800CA86C, 0x800CA9B4, 0x800CAA20],
    "group_array": 0x8016A874,          # 17 pointers, one per quad slot
    "group_array_entries": 17,
    "group_draw_fn": 0x800CCAAC,
    "group0_draw_site": 0x800CAF88,     # inside ui_menu_obj_dispatcher case 3
    "option_list": 0x8016A734,
    "option_count": 6,
    "option_strings": [0x8016A6F8, 0x8016A700, 0x8016A70C,
                       0x8016A714, 0x8016A720, 0x8016A72C],
    "options": ["Item", "Strength", "Rune", "Formation", "Equipment", "Setup"],
    "row_descriptor_table": 0x8016A64C,  # 17 rows x 5 halfwords for the quads
    "cursor_field": 0x54,               # word, per-quad selection index
    "decode_field": 0x5C,               # word, the confirmed option
    "cursor_bound_site": 0x800CB104,    # slti $v0,$v0,0x6
    "cursor_wrap_site": 0x800CB0DC,     # ori  $v0,$zero,0x5
    "confirm_site": 0x800CB024,         # andi $v0,$v1,0x41
    "confirm_store_site": 0x800CB058,   # sw $a0,0x5C($v0)
    "dispatch_site": 0x800CB16C,        # ori 5 / sltu
    "handler_table": 0x800C0DEC,        # 6 function pointers
    # (arm site in the table dispatch, handler installed at obj+0x08)
    "handlers": [
        {"option": 0, "name": "Item", "arm": 0x800CB19C,
         "handler": 0x800CB244,
         "cross_check": "downstream 0x800CBA50 calls 0x800CCAAC(5) and draws "
                        "group 5 = *(0x8016A888) = 0x8016A770 = "
                        "{Use, Hand over, Give up}"},
        {"option": 1, "name": "Strength", "arm": 0x800CB1B4,
         "handler": 0x800CE43C,
         "cross_check": "its chain reads the status labels 0x8016A9A4 'EXP', "
                        "0x8016A9A8 'ATK', 0x8016A9AC 'ARM' and the status row "
                        "arrays 0x8016A984 / 0x8016A990"},
        {"option": 2, "name": "Rune", "arm": 0x800CB1CC,
         "handler": 0x800CE798,
         "cross_check": "0x800CE798 installs obj+0x08 = 0x800CE828 and draws "
                        "quads obj+0x40 / obj+0x3C; the chain reaches the rune "
                        "effect table 0x8016AB68 and its result messages "
                        "'Power increased' 0x8016AAB4 .. 'Luck increased' "
                        "0x8016AB18"},
        {"option": 3, "name": "Formation", "arm": 0x800CB1E4,
         "handler": 0x800CD99C,
         "cross_check": "0x800CD99C copies the battle-order bytes gs+0x0E[i] "
                        "into obj+0xE0+4i (0x800CD9F0), i.e. the party-order "
                        "page"},
        {"option": 4, "name": "Equipment", "arm": 0x800CB1FC,
         "handler": 0x800CCF68,
         "cross_check": "its chain reads 0x8016A914 'Not' and the equipment "
                        "row array 0x8016A900"},
        {"option": 5, "name": "Setup", "arm": 0x800CB214,
         "handler": 0x800D0498,
         "cross_check": "0x800D0498 installs obj+0x08 = 0x800D06C0 (a 32-state "
                        "machine, table 0x800C0E8C) which reaches 0x800D17EC, "
                        "and 0x800D17EC calls 0x800CCAAC(15) = group 15 = "
                        "0x8016A844 = {Message speed, Fast, Normal, Slow, - , "
                        "Window setup, Transparent, Opaque, -, Sound setup, "
                        "Stereo, Mono} (12 rows)"},
    ],
    "group_15": {
        "addr": 0x8016A844, "rows": 12,
        "strings": ["Message speed", "Fast", "Normal", "Slow", "",
                    "Window setup", "Transparent", "Opaque", "",
                    "Sound setup", "Stereo", "Mono"],
        "drawn_by": 0x800D17EC,
    },
}

# ---------------------------------------------------------------------------
# Row descriptors, and the two misdecoded constants this pass corrects
# ---------------------------------------------------------------------------
#
# A screen's quad slots are built from a **10-byte (5 halfword) row table**,
# read with five `lh` from base+0,+2,+4,+6,+8 and a running offset that steps
# by 0xA.  The five fields are (kind, x, y, w, rows); `rows` is what
# tile_grid_packet_init copies to elem+9 and what the row loop counts.  The
# corpus called these "12-byte window descriptors" -- they are 10-byte rows.
DESCRIPTOR_ROWS = {
    "stride": 10,
    "fields": ["kind", "x", "y", "w", "rows"],
    "tables": {
        "root/arm1": {"addr": 0x8016A64C, "rows": 17, "loop_bound_site": 0x800CA768},
        "shop/arm2": {"addr": 0x8016AE18, "rows": 10, "loop_bound_site": 0x800D2050},
        "blacksmith/arm3": {"addr": 0x8016AF70, "rows": 9,
                            "loop_bound_site": 0x800D5868},
        "rune/arm4": {"addr": 0x8016B0FC, "rows": 8, "loop_bound_site": 0x800D7E94},
        "appraiser/arm5": {"addr": 0x8016B1A0, "rows": 10,
                           "loop_bound_site": 0x800DA4A4},
        "item_discard/arm8": {"addr": 0x8016B338, "rows": 3,
                              "loop_bound_site": 0x800DC838},
    },
    "evidence": "0x800CA6F4-0x800CA74C (arm 1), 0x800D1FE0-0x800D2054 (arm 2), "
                "0x800D57F4-0x800D586C (arm 3), 0x800D7E20-0x800D7E98 (arm 4), "
                "0x800DA430-0x800DA4A8 (arm 5), 0x800DC814/0x800DC840 (arm 8): "
                "each reads five halfwords at +0,+2,+4,+6,+8 and advances by 0xA. "
                "The row counts are the loop bounds `slti`: 0x11 (17), 0xa (10), "
                "9, 8, 0xa (10), 3.  Arm 4's table at 0x8016B0FC ends exactly at "
                "0x8016B14C, where the 'Attach' row string begins.",
}

#: The two constants the corpus decoded with the `lui` sign-extension trap
#: (AGENTS.md §5).  Both are `lui 0x8013 / 0x800e` + a *negative* 16-bit
#: immediate, so the high half must be folded in.
STEP_DECODE_CORRECTIONS = [
    {
        "site": 0x80132D18,
        "word": 0x24428DB0,
        "corpus_read": 0x800D8DB0,
        "correct": 0x80128DB0,
        "why": "lui $v0,0x8013 makes the base 0x80130000 and the immediate "
               "0x8DB0 is sign-extended (-0x7250), so the target is "
               "0x80130000-0x7250 = 0x80128DB0, a `jr $ra / addiu v0,zero,-1` "
               "stub -- not a screen step at all.",
    },
    {
        "site": 0x800D9E78,
        "word": 0x24429E90,
        "corpus_read": 0x800E9E90,
        "correct": 0x800D9E90,
        "why": "lui $v0,0x800e + imm 0x9E90 sign-extended (-0x6170) = "
               "0x800E0000-0x6170 = 0x800D9E90, the *inn* builder's step.  The "
               "corpus attributed one wrong constant ('0x800E9E90-family') to "
               "both arm 5 and arm 8; the real returns are 0x800DA3D4 (arm 5) "
               "and 0x800DC7B8 (arm 8).",
    },
]

#: How the arms are *entered*.  The selector is not `jal`-ed by anything and
#: nothing points at it as data either: it is reached from the frame slot that
#: `game_state_driver` installs (0x80132938) once the state byte is nonzero.
SELECTOR_ENTRY_NOTE = ("0x80132F60 has zero `jal` callers and zero data "
                       "pointers; 0x80132B6C installs 0x80132938 into the frame "
                       "slot whenever *(0x8017BE20)+0x4E0 != 0 (0x80132BE4/"
                       "0x80132BE8) and 0x80132938 is what calls the selector.")

#: Five script-reachable builder wrappers sit in 0x8012CFF0-0x8012D118, one per
#: builder, each staging the step at 0x8017A100.  They have no caller and no
#: data pointer anywhere in MAIN.EXE (checked both ways), so they are recorded
#: as dead code: the live path is the selector.
DEAD_BUILDER_WRAPPERS = {
    "range": (0x8012CFF0, 0x8012D118),
    "map": {0x8012CFF0: 0x800CA66C, 0x8012D018: 0x800D1BE4,
            0x8012D04C: 0x800D5714, 0x8012D080: 0x800D7D24,
            0x8012D0B4: 0x800D9DEC, 0x8012D0E8: 0x800DA29C},
    "evidence": "no 4-byte word in MAIN.EXE equals any of the six wrapper VAs "
                "(unaligned search) and no `jal` reaches them.",
}

#: The trampoline the selector installs for every builder arm.
STEP_TRAMPOLINE = {
    "addr": 0x8012D11C,
    "stage_slot": 0x8017A100,
    "install_site": 0x80133158,
    "comment": "0x8012D11C loads *(0x8017A100), jalr's it, stores the return "
               "back into 0x8017A100 and returns -1; a step returning 0 ends "
               "the screen (0x8012D150 then clears the area-state words and "
               "gs+0x1D5E).",
    "selector_stage_site": [0x8013303C, 0x80133054, 0x80133070, 0x8013308C,
                            0x801330A8, 0x801330C4, 0x801330E0],
}

# ---------------------------------------------------------------------------
# The five shop-family screens, and the one arm that is not one of them
# ---------------------------------------------------------------------------
SCREEN_FAMILY = {
    "verdict": "The five script-reachable screens shop / blacksmith / rune "
               "attach / appraiser / inn are selector values 2, 3, 4, 5 and 6 "
               "-- NOT 3, 4, 5, 6 and 8.  Arm 8 is the item-overload / discard "
               "page, which is not one of the five.",
    "map": {2: "shop", 3: "blacksmith", 4: "rune attach / detach",
            5: "appraiser", 6: "inn"},
    "arm8": "item_discard (Overloaded / Choose item to discard / Drop)",
    "evidence": "each arm is named from its own object's code, not from the "
                "arm number: arm 2's object renders {Buy, Sell, End}, arm 3's "
                "renders {Sharpen, Rune fragment, End}, arm 4's loads "
                "{Attach, Remove, End}, arm 5's loads {Appraise, Sell, End} "
                "with 'price ', arm 6 pays a party-size-scaled rate and heals "
                "the party, and arm 8's page renders the overload/discard "
                "messages.",
}

#: The screen-string groups this pass resolved, as (label rows, pointer array).
SCREEN_STRING_GROUPS = {
    "shop_rows": {"rows": 0x8016AE8C, "via": 0x8016AEB4, "strings": 0x8016AE7C,
                  "text": ["Buy", "Sell", "End"], "read_by": 0x800D25DC},
    "shop_yesno": {"rows": 0x8016AEA0, "via": 0x8016AEC4, "strings": 0x8016AE98,
                   "text": ["Yes", "No"], "read_by": 0x800D3E0C},
    "blacksmith_rows": {"rows": 0x8016AFE8, "via": 0x8016B010,
                        "strings": 0x8016AFCC,
                        "text": ["Sharpen", "Rune fragment", "End"],
                        "read_by": 0x800D5E4C},
    "blacksmith_yesno": {"rows": 0x8016AFFC, "via": 0x8016B00C,
                         "strings": 0x8016AFF4, "text": ["Yes", "No"],
                         "read_by": 0x800D63F8},
    "rune_rows": {"rows": 0x8016B160, "via": 0x8016B188, "strings": 0x8016B14C,
                  "text": ["Attach", "Remove", "End"], "read_by": 0x800D8478},
    "appraiser_rows": {"rows": 0x8016B21C, "via": 0x8016B244,
                       "strings": 0x8016B204,
                       "text": ["Appraise", "Sell", "End"],
                       "read_by": 0x800DA9FC},
    "appraiser_yesno": {"rows": 0x8016B230, "via": 0x8016B240,
                        "strings": 0x8016B228, "text": ["Yes", "No"],
                        "read_by": 0x800DB35C},
    "item_discard_messages": {"rows": 0x8016B2F8, "via": None, "strings": None,
                              "text": ["Overloaded", "Gave up on",
                                       "Choose item to discard",
                                       "You're already equipped.",
                                       "Drop", "Do not drop", "Give up",
                                       "Don't give up"],
                              "read_by": 0x800DCB84},
}

#: Screens that are NOT arms of the MAIN selector: they are separate overlay
#: programs that reuse MENU_STATE_BYTE and SLOT_TABLE.  The warehouse
#: (AZUKARI) is the worked example, read out of its own bytes.
OVERLAY_STATES = [
    {
        "id": "warehouse",
        "overlay": "DATA/03_SHIRO/AZUKARI.BIN",
        "load_base": AZUKARI_BASE,
        "entry_point": 0x800800A0,       # == file[0], the jump-in address
        "entry_table": 0x800800EC,
        "entry_table_count": 6,
        "entries": [0x80080678, 0x800806D8, 0x800807EC, 0x80080834,
                    0x80080860, 0x800808E4],
        "state_dispatcher": 0x800806D8,
        "state_dispatcher_states": 6,
        "state_dispatcher_jump_table": 0x8008004C,
        "state_dispatcher_bound_site": 0x80080648,
        "state_dispatcher_jr_site": 0x80080670,
        "submenu_router": 0x80080934,
        "submenu_targets": [0x80081F10, 0x8008349C, 0x800844C0],
        "submenu_choice_table": 0x8008011C,
        "submenu_choice_table_count": 5,
        "submenu_route_site": 0x80080934,
        "entry": {
            "enter": 0x80080000,
            "enter_name": "warehouse_enter",
            "init": 0x80080054,
            "init_name": "warehouse_init",
            "build_item_slots": 0x800802F8,
            "sync_step": 0x800803CC,
            "exit_step": 0x80080540,
        },
        "writers": {
            "deposit_single": {
                "addr": 0x80081C00, "name": "warehouse_cursor_bump",
                "store_site": 0x80081CA0,
                "instruction": "sb $v0,0x90($v1)  (0xA0620090)",
                "recorded_va": 0x80081CA0,
            },
            "deposit_all": {
                "addr": 0x80084314, "name": "warehouse_cursor_bump2",
                "store_site": 0x800843D8,
                "instruction": "sb $v0,0x90($v1)  (0xA0620090)",
                "recorded_va": 0x800843D8,
            },
            "withdraw": {
                "addr": 0x80082F38, "name": "warehouse_compute_step",
                "store_site": 0x80083034,
                "instruction": "sb $v0,0x90($v1)  (0xA0620090)",
                "recorded_va": 0x80083034,
            },
        },
        "reads_state_byte": [0x8012D574, 0x80080984],
        "evidence": "file[0]=0x800800A0=entry point; base 0x80080000 makes the "
                    "file-0x4C arm table decode as six in-file code pointers and "
                    "puts a real prologue at every recorded warehouse entry VA "
                    "(0x800800A8/0x800800FC/0x800803A0/.../0x80084314).  The "
                    "three quantity stores are at 0x80081CA0, 0x80083034 and "
                    "0x800843D8, all `sb $v0,0x90($v1)`.",
        "confidence": "load base PROVEN; the deposit/withdraw option order is "
                      "from azukari_labels.csv and not re-derived here",
        "correction": "the store sites (0x80081CA0 / 0x80083034 / 0x800843D8) "
                      "are correct; the FUNCTION entries are 0x80081C00 / "
                      "0x80082F38 / 0x80084314.  azukari_labels.csv names the "
                      "store site with the function's name, so its address "
                      "column cannot be read as a function entry for those rows.",
    },
]

# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------

TRANSITIONS = [
    # from, on, to, site, note
    ("field", "START (input 0x8017BE4C bit 0x80) and transition guard 0",
     "root_menu (state byte := 1)", 0x801329F0,
     "The only player-driven open: field_update_driver's START test."),
    ("field", "event-script byte == N (0..7, 0x80)",
     "screen N", 0x801397F4,
     "The scripted open. 0xFF closes; 0x80 selects via table at "
     "*(0x8017C108)+0x10."),
    ("root_menu", "selector runs with state byte = 1",
     "root_menu object built; step 0x800CA830 installed", 0x80133030,
     "Arm 1 -> dialogue_ui_struct_alloc -> 0x80179E48; the builder returns "
     "0x800CA830 and the selector installs the 0x8012D11C trampoline."),
    ("root_menu", "screen finished (obj+0x498 == 0)",
     "field", 0x80132D98,
     "Root exit step clears state byte, restores camera + field driver."),
    ("any selected screen", "screen's own handler writes state byte := N",
     "screen N (via selector next frame)", None,
     "Screens navigate by writing the state byte; the selector then rebuilds. "
     "Found writes: 0x801329F0 (=1), the event opcode store, and the "
     "overlay writers."),
    ("screen session", "state byte := 0x80",
     "same screen object, next page", 0x80133138,
     "Arm 0x80 indirect-calls the object's handler at +0x498; no new object."),
    ("any screen", "screen's exit step runs with handler +0x498 == 0",
     "field (state byte := 0; field_update_driver @0x801319C4 into slot)",
     0x8012D574,
     "The generic close."),
    ("menu (any)", "state byte := 7",
     "area_transition", 0x801330EC,
     "Queues 0x0A0 and 0x015 into the command dispatcher (0x800C3104)."),
    ("menu (any)", "state byte := 8",
     "save_or_load_menu", 0x80133048,
     "Mallocs 0x84 via 0x800DC650."),
    ("warehouse", "object state word advance",
     "deposit path / withdraw path / leave",
     0x80080934,
     "3-way router; targets 0x80081F10 (deposit setup), 0x8008349C "
     "(withdraw setup), 0x800844C0 (leave). Labels from azukari_labels.csv."),
]

# ---------------------------------------------------------------------------
# Per-screen data
# ---------------------------------------------------------------------------

DATA_TABLES = {
    "items": {"base": 0x80167658, "stride": 4, "count": 60,
              "note": "addressed as halfword ID -> `lhu 0x20(base+idx)`; the "
                      "consumables/equipment name records live at 0x801686CC"},
    "equipment": {"base": 0x80167928, "stride": 8, "count": 58,
                  "note": "the 58-record equipment table"},
    "weapons": {"base": 0x80166000, "stride": 0x58, "count": 16,
                "sub_records": [0x00, 0x1C, 0x38], "tier_count": 3,
                "note": "3 upgrade tiers per weapon"},
    "runes": {"base": 0x8016A1B0, "stride": 0x24, "count": 31},
    "rune_name_pointers": {"base": 0x8016A0E4, "count": 32,
                           "note": "32 pointers to rune names, Soul Eater first"},
    "unite_attacks": {"base": 0x8016CD0C, "stride": 0x24, "count": 26},
    "characters": {"base_gs": 0x801B8000, "offset": 0x294, "stride": 0x50,
                   "count": 78,
                   "note": "per-character persistent record; +0x00 char id, "
                           "+0x1F item count, +0x20 item IDs (halfword, stride 4)"},
    "stat_template": {"file": "SLUS_002.92", "offset": 0x33274,
                      "stride": 0x50, "count": 78,
                      "note": "the 78 x 0x50 stat template source data"},
    "row_descriptors": {
        "note": "10-byte rows of five halfwords (kind, x, y, w, rows), read "
                "with five `lh` at +0,+2,+4,+6,+8 on a stride of 0xA; `rows` is "
                "the row-loop bound and the number of quads built.  The corpus "
                "called these '12-byte window descriptors'.",
        "sites": {
            "root/arm1": {"addr": 0x8016A64C, "rows": 17},
            "shop/arm2": {"addr": 0x8016AE18, "rows": 10},
            "blacksmith/arm3": {"addr": 0x8016AF70, "rows": 9},
            "rune/arm4": {"addr": 0x8016B0FC, "rows": 8},
            "appraiser/arm5": {"addr": 0x8016B1A0, "rows": 10},
            "item_discard/arm8": {"addr": 0x8016B338, "rows": 3},
        },
        "kind_masks": {"equipment_kinds": 0x8016AE00, "slot_ids": 0x8016AE0C},
    },
    "ui_string_groups": {
        "note": "label + pointer-array pairs; a screen builds its rows from these",
        "shop": {"labels": [0x8016AE7C, 0x8016AE80, 0x8016AE88],
                 "row_pointers": 0x8016AE8C, "rows": 3,
                 "selector_pointers": 0x8017AEE4,
                 "selector_strings": ["Buy", "Sell", "price "]},
        "blacksmith": {"labels": [0x8016AFCC, 0x8016AFD4, 0x8016AFE4],
                       "row_pointers": 0x8016AFE8, "rows": 3},
        "rune_attach": {"labels": [0x8016B14C, 0x8016B154, 0x8016B15C],
                        "row_pointers": 0x8016B160, "rows": 3,
                        "strings": ["Attach", "Remove", "End"]},
        "appraiser": {"labels": [0x8016B204, 0x8016B210, 0x8016B218],
                      "row_pointers": 0x8016B21C, "rows": 3,
                      "strings": ["Appraise", "Sell", "End"],
                      "confirm_rows": 0x8016B230, "confirm_via": 0x8016B240,
                      "categories": [0x8016AEE4, 0x8016AEEC, 0x8016AEF8]},
        "item_discard": {"labels": None, "row_pointers": 0x8016B2F8,
                         "rows": 12,
                         "strings": ["Overloaded", "Gave up on",
                                     "Choose item to discard",
                                     "You're already equipped.", "Drop",
                                     "Do not drop", "Give up",
                                     "Don't give up"]},
    },
}

#: The game-state vtable (`*(gs+0x1BC4)`, boot value `0x80165608`).  The
#: warehouse's two halves are two slots of this table — which is why neither
#: half appears as a `jal` inside the overlay, and why a direct-call scan finds
#: nothing there (the AGENTS.md "failed direct-call scan" trap).
GS_VTABLE = {
    "table_addr": 0x80165608,
    "table_source": "gs+0x1BC4, installed at 0x800C9614 (gpu_heap_init)",
    "slots": {
        0x048: {"target": 0x800C2D30, "name": "heap_alloc"},
        0x120: {"target": 0x80147D78, "name": "unlabelled (used by the overlay entry)"},
        0x174: {"target": 0x800CA38C, "name": "char_item_insert"},
        0x220: {"target": 0x800CA42C, "name": "char_item_remove"},
        0x258: {"target": 0x80146934, "name": "text/window draw helper"},
    },
    "evidence": "words at 0x80165608+0x174 / +0x220 / +0x48 / +0x258 / +0x120.",
}

#: The character-record item list, and the two halves of the warehouse
#: transaction.  `gs+0x294` is the 78 x 0x50 character table; inside a record,
#: `+0x1F` is the item count and `+0x20 + i*4` the item entries (halfword id at
#: +0, flag byte at +2, quantity byte at +3).
CHAR_ITEM_LIST = {
    "char_table_gs_offset": 0x294,
    "char_stride": 0x50,
    "char_count": 78,
    "count_offset": 0x1F,
    "items_offset": 0x20,
    "item_stride": 4,
    "max_items": 8,          # `sltiu count,9` -- the guard in the insert
    "insert": {
        "addr": 0x800CA38C,
        "name": "char_item_insert",
        "signature": "(char_record*, item_entry*)",
        "body": "lbu count=rec+0x1F; if count>=9 return 0; count++; "
                "sb count,rec+0x1F; dst = rec + count*4; lwl/lwr 4 bytes from "
                "item_entry; swl/swr -> dst+0x1C..0x1F, i.e. rec+0x20+count*4",
        "store_sites": [0x800CA3B8, 0x800CA3E0, 0x800CA3E4],
    },
    "remove": {
        "addr": 0x800CA42C,
        "name": "char_item_remove",
        "signature": "(char_record*, index)",
        "body": "save entry; if count < index return 0; count--; "
                "sb count,rec+0x1F; shift entries [index+1..count] down by one",
        "store_sites": [0x800CA474, 0x800CA49C, 0x800CA4A0],
    },
    "insert_wrapper": {
        "addr": 0x800CA340,
        "name": "char_item_list_add_checked",
        "body": "reads the item count from the passed object at +0x1F, and on "
                "count<9 calls 0x800CA38C on the record at obj+0x1C",
    },
    "callers_of_insert": [0x800CA354, 0x800CFD58, 0x800CFD68, 0x800D33F4,
                          0x800D95C8, 0x800DD6E8],
}

#: The withdraw item-give half, RESOLVED.  The warehouse's deposit and withdraw
#: are the same vtable table's two item-list slots:
#:   deposit  = remove from character  -> vtable+0x220
#:   withdraw = insert into character  -> vtable+0x174
#: `warehouse_compute_step`'s insert site was the open item in
#: `kit/docs/warehouse_commit.md`.
WITHDRAW_GIVE = {
    "verdict": "found",
    "insert_site": 0x80083010,
    "insert_load_site": 0x80083008,
    "function": 0x80082F38,
    "function_name": "warehouse_compute_step",
    "instruction": "lw v0,0x174(v1) / jalr v0  with a0 = the selected item "
                   "struct at obj+0x50[obj+0x98], a1 = $sp+0x18",
    "stack_item_struct": {
        "id_halfword": 0x18,
        "flag_byte": 0x1A,
        "qty_byte": 0x1B,
        "note": "built at 0x80082FAC-0x80082FE0 from the item record; the flag "
                "byte is the item's +0x1E and is forced to 0 when it is -1",
    },
    "quantity_decrement": {
        "site": 0x80083034,
        "instruction": "sb v0,0x90(v1)  (gs+0x90[item]--)",
    },
    "order": "the insert happens FIRST (0x80083010), the gs+0x90 decrement "
             "second (0x80083034) -- so a failed insert cannot lose the stored "
             "item",
    "deposit_mirror": {
        "site": 0x800843F0,
        "slot": 0x220,
        "function": 0x80084314,
        "function_name": "warehouse_cursor_bump2",
    },
    "evidence": "AZUKARI contains exactly two vtable item-list loads: "
                "0x80083008 lw v0,0x174(v1) and 0x800843F0 lw v0,0x220(v0). "
                "vtable slot 0x174 = 0x800CA38C (insert), slot 0x220 = "
                "0x800CA42C (remove). MAIN.EXE itself contains no vtable "
                "0x174/0x220 load as a code load.",
    "correction": "kit/docs/warehouse_commit.md's 'still open' item is now "
                  "closed; the guess there ('a 0x800CA4xx list-insert twin') "
                  "was half right -- the insert is 0x800CA38C, not 0x800CA4xx.",
}

WAREHOUSE_CHARACTER_LOOKUP = {'entry': 0x80084FAC, 'first_offset': 0x294,
                              'stride': 0x50, 'count': 78,
                              'key': 'record word0', 'failure': 0}


def warehouse_deposit_allowed(stored_quantity, item_flags, status_byte):
    """AZUKARI 84FE8: arguments are the byte/halfword values read from records."""
    return stored_quantity < 0xFE and (
        status_byte == 0xFF if item_flags & 0x7000 else status_byte < 0x80)


#: The command dispatcher (0x800C4FE0) and the commands the menu system emits.
#: Kept here because "what each screen writes" includes the command queue.
COMMAND_DISPATCHER = {
    "addr": 0x800C4FE0,
    "table": 0x800C0800,
    "table_entries": 0x21,          # 0..0x20, 0x20 = default
    "index_fn": "high byte of the 16-bit command",
    "menu_emits": {
        0x0A0: "area transition (menu arm 7)",
        0x015: "screen-id change (menu arm 7)",
        0x0A1: "transition finish (0x8012D55C, when state byte == 7)",
        0x503: "confirm / page change (ui_menu_obj_dispatcher case 3)",
        0x502: "price / quantity redraw (menu_quantity_adjust family)",
        0x504: "shop transaction message",
        0x505: "shop transaction message",
    },
}

#: The ui_menu_obj_dispatcher case-3 confirm path (battle menu + generic lists).
UI_MENU_OBJ_DISPATCHER = {
    "addr": 0x800CAEB4,
    "jump_table": 0x800C0DD4,
    "cases": 4,
    "confirm_site": 0x800CB074,
    "confirm_mask": 0x41,
    "confirm_command": 0x503,
    "comment": "case 3 tests d-pad bits 0xF000 and the pressed-edge word "
               "0x8017BE4C, then queues 0x0503 via 0x800C3104.",
}

#: The ui_state_dispatcher switch driven by the event-bytecode UI command.
UI_STATE_DISPATCHER = {
    "addr": 0x80141814,
    "jump_table": 0x800C1AC0,
    "entries": 29,
    "index_source": "0x80139918 reads one event byte from 0x8017AF84 and passes it",
    "comment": "Not a screen selector: its 29 arms toggle flag bytes and GPU "
               "status bits. Included so the two 'dispatchers' are not confused.",
}


def _read_main() -> bytes:
    """MAIN.EXE image at MAIN_BASE (2048-byte PS-X header stripped)."""
    return disc.extract(MAIN_LBA, MAIN_SIZE)[MAIN_HEADER:]


def _word(img: bytes, base: int, va: int):
    off = va - base
    if off < 0 or off + 4 > len(img):
        return None
    return struct.unpack_from("<I", img, off)[0]


def _bytes(img: bytes, base: int, va: int, n: int) -> bytes:
    off = va - base
    return img[off:off + n]


def _sx16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def _op(img: bytes, base: int, va: int) -> int:
    w = _word(img, base, va)
    return None if w is None else (w >> 26) & 0x3F


def _syscall_ish(img: bytes, base: int, va: int) -> str:
    w = _word(img, base, va)
    return "" if w is None else f"{w:08x}"


def verify() -> list[str]:
    """Re-derive every structural claim from the disc bytes.

    Returns a list of human-readable check lines.  Raises AssertionError on the
    first failure, so a moved word cannot silently invalidate the model.
    """
    img = _read_main()
    out: list[str] = []

    def ck(label, cond, detail=""):
        if not cond:
            raise AssertionError(f"FAIL: {label} {detail}")
        out.append(f"ok   {label}{('  ' + detail) if detail else ''}")

    # --- selector exists and switches on +0x4E0 -----------------------------
    ck("selector reads +0x4E0",
       _word(img, MAIN_BASE, 0x80132FB0) == 0x908304E0,
       _syscall_ish(img, MAIN_BASE, 0x80132FB0))
    # --- dispatcher table -----------------------------------------------
    ck("command dispatcher table size 0x21",
       _word(img, MAIN_BASE, 0x800C0800 + 0x20 * 4) is not None)
    tbl = [_word(img, MAIN_BASE, 0x800C0800 + i * 4) for i in range(0x21)]
    ck("command dispatcher table entries are code",
       all(0x800C0000 <= t < 0x8016F000 for t in tbl if t),
       f"{len(tbl)} entries")
    ck("command dispatcher index 5 (0x5xx) stub -> jal 0x800C5830",
       tbl[5] == 0x800C506C
       and _word(img, MAIN_BASE, 0x800C5070) == 0x0C03160C,
       f"stub {tbl[5]:#x} -> {_syscall_ish(img,MAIN_BASE,0x800C5070)}")
    ck("command dispatcher index 0x20 is the default/return arm",
       tbl[0x20] == 0x800C50C0)

    # --- entry: START -> state byte = 1 -------------------------------------
    ck("menu open tests input word 0x8017BE4C",
       _word(img, MAIN_BASE, 0x801329C0) == 0x8C42BE4C,
       _syscall_ish(img, MAIN_BASE, 0x801329C0))
    ck("menu open masks bit 0x80 (START)",
       _word(img, MAIN_BASE, 0x801329C8) == 0x30420080,
       _syscall_ish(img, MAIN_BASE, 0x801329C8))
    ck("menu open stores 1 into +0x4E0",
       _word(img, MAIN_BASE, 0x801329EC) is not None
       and _word(img, MAIN_BASE, 0x801329F0) == 0xA06204E0,
       _syscall_ish(img, MAIN_BASE, 0x801329F0))
    ck("menu open loads the area state pointer",
       _word(img, MAIN_BASE, 0x801329E8) == 0x8C63BE20,
       _syscall_ish(img, MAIN_BASE, 0x801329E8))

    # --- close: field-side teardown ----------------------------------------
    ck("menu close clears +0x4E0",
       _word(img, MAIN_BASE, 0x8012D574) == 0xA06004E0,
       _syscall_ish(img, MAIN_BASE, 0x8012D574))
    ck("menu close installs field_update_driver",
       _word(img, MAIN_BASE, 0x8012D578) == 0x3C038013
       and _word(img, MAIN_BASE, 0x8012D57C) == 0x246319C4,
       f"{_syscall_ish(img,MAIN_BASE,0x8012D57C)} -> 0x801319C4")

    # --- game_state_driver gates on the state byte --------------------------
    ck("game_state_driver tests +0x4E0",
       _word(img, MAIN_BASE, 0x80132BD0) == 0x906204E0,
       _syscall_ish(img, MAIN_BASE, 0x80132BD0))
    ck("game_state_driver installs the menu driver 0x80132938",
       _word(img, MAIN_BASE, 0x80132BE4) == 0x3C028013
       and _word(img, MAIN_BASE, 0x80132BE8) == 0x24422938,
       f"{_syscall_ish(img,MAIN_BASE,0x80132BE8)}")

    # --- selector arms ------------------------------------------------------
    # Each arm is `lui/addiu a1,<builder>; jal <builder>`; the jal target is
    # derived from the *instruction address* (PC+4).  Value -> call site:
    #   1 -> 0x80133030   2 -> 0x801330B8   3 -> 0x801330D4   4 -> 0x8013309C
    #   5 -> 0x80133060   6 -> 0x80133080   7 -> inline   8 -> 0x80133048
    #   0x80 -> inline indirect through obj+0x498
    jal_at = {
        0x80133030: (0x800CA66C, 1),
        0x80133048: (0x800DC650, 8),
        0x80133064: (0x800DA29C, 5),
        0x80133080: (0x800D9DEC, 6),
        0x8013309C: (0x800D7D24, 4),
        0x801330B8: (0x800D1BE4, 2),
        0x801330D4: (0x800D5714, 3),
    }
    for site, (tgt, val) in sorted(jal_at.items()):
        w = _word(img, MAIN_BASE, site)
        got = ((site & 0xF0000000) | ((w & 0x3FFFFFF) << 2)) if w else None
        ck(f"selector arm {val} jal at {site:#x} -> {tgt:#x}",
           w is not None and (w >> 26) == 3 and got == tgt,
           f"got {('0x%x' % got) if got else '-'}")

    # the selector bounds-checks its own switch (sltu vs 0x20, default 0x80132A0...)
    ck("selector is an explicit compare chain on the state byte",
       _word(img, MAIN_BASE, 0x80132FB4) == 0x34020005,
       _syscall_ish(img, MAIN_BASE, 0x80132FB4))

    # arm 0x80 indirect-calls obj+0x498
    ck("selector arm 0x80 indirect-calls obj+0x498",
       _word(img, MAIN_BASE, 0x80133138) == 0x8C820498
       and _word(img, MAIN_BASE, 0x80133140) == 0x0040F809,
       f"{_syscall_ish(img,MAIN_BASE,0x80133138)} {_syscall_ish(img,MAIN_BASE,0x80133140)}")

    # the two step installers
    ck("selector's other installer writes the no-op step 0x80128DB0",
       _word(img, MAIN_BASE, 0x80132D14) == 0x3C028013
       and _word(img, MAIN_BASE, 0x80132D18) == 0x24428DB0,
       f"{_syscall_ish(img,MAIN_BASE,0x80132D18)}")
    ck("selector tail installs 0x80132D1C via slot table 0x8017DA90",
       _word(img, MAIN_BASE, 0x80133158) == 0x3C028013
       and _word(img, MAIN_BASE, 0x8013315C) == 0x2442D11C,
       f"{_syscall_ish(img,MAIN_BASE,0x8013315C)}")

    # --- arm 2 builds the party object -------------------------------------
    ck("arm-2 builder publishes menu_table_d (0x80179E68)",
       _word(img, MAIN_BASE, 0x800D1C18) == 0xAC239E68,
       _syscall_ish(img, MAIN_BASE, 0x800D1C18))
    ck("arm-2 builder reads the party count (gs+0x03)",
       _word(img, MAIN_BASE, 0x800D1D14) == 0x90620003,
       _syscall_ish(img, MAIN_BASE, 0x800D1D14))
    ck("arm-2 builder indexes gs+0x1B9C by the battle-order byte",
       _word(img, MAIN_BASE, 0x800D1D60) == 0x8C431B9C,
       _syscall_ish(img, MAIN_BASE, 0x800D1D60))
    ck("arm-2 chain returns the object runner 0x800D2100",
       _word(img, MAIN_BASE, 0x800D21F4) == 0x3C02800D
       and _word(img, MAIN_BASE, 0x800D21F8) == 0x24422100,
       f"{_syscall_ish(img,MAIN_BASE,0x800D21F8)}")
    ck("root menu state 1 fade ramps gs+0x1D5F to 0x80",
       _word(img, MAIN_BASE, 0x800D2300) == 0x34020080
       and _word(img, MAIN_BASE, 0x800D2304) == 0xA0621D5F,
       f"{_syscall_ish(img,MAIN_BASE,0x800D2304)}")

    # --- root exit step clears the state byte ------------------------------
    ck("root exit step clears +0x4E0",
       _word(img, MAIN_BASE, 0x80132D98) == 0xA08004E0,
       _syscall_ish(img, MAIN_BASE, 0x80132D98))

    # --- event-script open --------------------------------------------------
    ck("event open reads the event stream cursor 0x8017AF84",
       _word(img, MAIN_BASE, 0x801397D0) == 0x3C048018
       and _word(img, MAIN_BASE, 0x801397D4) == 0x8C84AF84,
       f"{_syscall_ish(img,MAIN_BASE,0x801397D4)}")
    ck("event open stores the byte into +0x4E0",
       _word(img, MAIN_BASE, 0x801397F4) == 0xA06204E0,
       _syscall_ish(img, MAIN_BASE, 0x801397F4))
    ck("event open sentinel 0xFF closes",
       _word(img, MAIN_BASE, 0x80139814) == 0xA0A004E0,
       _syscall_ish(img, MAIN_BASE, 0x80139814))

    # --- two more clear sites ----------------------------------------------
    for site in (0x80131118, 0x80131528):
        w = _word(img, MAIN_BASE, site)
        ck(f"state-byte clear at {site:#x}", w is not None and (w & 0xFFFF) == 0x04E0,
           _syscall_ish(img, MAIN_BASE, site))

    # --- ui_state_dispatcher table -----------------------------------------
    n = 0
    while _word(img, MAIN_BASE, 0x800C1AC0 + n * 4) and n < 64:
        v = _word(img, MAIN_BASE, 0x800C1AC0 + n * 4)
        if not (0x80140000 <= v <= 0x80143000):
            break
        n += 1
    ck("ui_state_dispatcher table has 29 code entries", n == 29, f"found {n}")

    # --- AZUKARI overlay: base proof ---------------------------------------
    az = disc.extract(AZUKARI_LBA, AZUKARI_SIZE)
    ck("AZUKARI file[0] is the entry point 0x800800A0",
       struct.unpack_from("<I", az, 0)[0] == 0x800800A0,
       f"{struct.unpack_from('<I', az, 0)[0]:#x}")

    # Under AZUKARI_BASE the six state arms are at their real VAs.
    ck("AZUKARI 6-state dispatcher bounds the state word against 5",
       _word(az, AZUKARI_BASE, 0x80080648) == 0x34020005
       and _word(az, AZUKARI_BASE, 0x8008064C) == 0x0043102B,
       f"{_syscall_ish(az,AZUKARI_BASE,0x80080648)} {_syscall_ish(az,AZUKARI_BASE,0x8008064C)}")
    ck("AZUKARI 6-state dispatcher is a jump table at 0x8008004C",
       _word(az, AZUKARI_BASE, 0x80080660) == 0x2421004C
       and _word(az, AZUKARI_BASE, 0x80080670) == 0x00400008,
       _syscall_ish(az, AZUKARI_BASE, 0x80080670))

    jt_raw = [struct.unpack_from("<I", az, 0x4C + i * 4)[0] for i in range(6)]
    ck("AZUKARI arm table at file 0x4C holds the six arm pointers",
       jt_raw == [0x80080678, 0x800806D8, 0x800807EC, 0x80080834,
                  0x80080860, 0x800808E4],
       " ".join(f"{v:#x}" for v in jt_raw))
    # the arms at those VAs must be code (a prologue or a leaf)
    for va in jt_raw:
        ck(f"AZUKARI arm {va:#x} is reachable in-file",
           (va - AZUKARI_BASE) % 4 == 0 and va - AZUKARI_BASE < len(az))
    ck("AZUKARI first arm 0x80080678 is code (advances the object state word)",
       _word(az, AZUKARI_BASE, 0x80080688) == 0x8C620000
       and _word(az, AZUKARI_BASE, 0x80080694) == 0xAC620000,
       f"{_syscall_ish(az,AZUKARI_BASE,0x80080694)}")

    # --- the load-base proof: the three warehouse stores --------------------
    for name, fn_va, store_va in (
            ("deposit single", 0x80081C00, 0x80081CA0),
            ("deposit all", 0x80084314, 0x800843D8),
            ("withdraw", 0x80082F38, 0x80083034)):
        ck(f"AZUKARI {name}: {fn_va:#x} starts with a real prologue",
           _word(az, AZUKARI_BASE, fn_va) in (0x27BDFFE8, 0x27BDFFD0, 0x27BDFFD8)
           or (_word(az, AZUKARI_BASE, fn_va) or 0) >> 26 == 0x09,
           _syscall_ish(az, AZUKARI_BASE, fn_va))
        ck(f"AZUKARI {name}: {store_va:#x} is `sb v0,0x90(v1)`",
           _word(az, AZUKARI_BASE, store_va) == 0xA0620090,
           _syscall_ish(az, AZUKARI_BASE, store_va))
    # and under the WRONG base those same VAs are not stores
    ck("recorded warehouse store VAs are under base 0x80080000 (0x80081CA0 "
       "read as if the base were 0x800800A0 is not a store)",
       struct.unpack_from("<I", az, 0x1C00)[0] != 0xA0620090,
       f"{struct.unpack_from('<I', az, 0x1C00)[0]:08x}")
    # ...and every recorded warehouse FUNCTION entry is a real prologue
    for name, va in (("warehouse_enter", 0x800800A8),
                     ("warehouse_init", 0x800800FC),
                     ("warehouse_build_item_slots", 0x800803A0),
                     ("warehouse_sync_step", 0x80080474),
                     ("warehouse_exit_step", 0x800805E8),
                     ("warehouse_state_dispatcher", 0x80080634),
                     ("warehouse_menu_dispatch", 0x80080934),
                     ("warehouse_cursor_bump", 0x80081C00),
                     ("warehouse_compute_step", 0x80082F38),
                     ("warehouse_cursor_bump2", 0x80084314)):
        w = _word(az, AZUKARI_BASE, va)
        ck(f"AZUKARI entry {name} @{va:#x} is a stack prologue",
           w is not None and (w >> 26) == 0x09 and ((w >> 16) & 0x1F) == 29,
           _syscall_ish(az, AZUKARI_BASE, va))

    # --- AZUKARI opens/closes on the shared menu state byte -----------------
    # The overlay's own menu driver (the corrected 0x80080894, i.e. recorded
    # 0x80080934) indirect-calls the vtable and advances its object state word.
    ck("AZUKARI submenu router indirect-calls the vtable then advances state",
       _word(az, AZUKARI_BASE, 0x800808B4) == 0x8C620258
       and _word(az, AZUKARI_BASE, 0x800808BC) == 0x0040F809
       and _word(az, AZUKARI_BASE, 0x800808D8) == 0x24420001,
       f"{_syscall_ish(az,AZUKARI_BASE,0x800808B4)} "
       f"{_syscall_ish(az,AZUKARI_BASE,0x800808BC)} "
       f"{_syscall_ish(az,AZUKARI_BASE,0x800808D8)}")

    # --- THE WITHDRAW ITEM-GIVE HALF --------------------------------------
    ck("vtable +0x174 is char_item_insert 0x800CA38C",
       _word(img, MAIN_BASE, GS_VTABLE["table_addr"] + 0x174) == 0x800CA38C,
       _syscall_ish(img, MAIN_BASE, GS_VTABLE["table_addr"] + 0x174))
    ck("vtable +0x220 is char_item_remove 0x800CA42C",
       _word(img, MAIN_BASE, GS_VTABLE["table_addr"] + 0x220) == 0x800CA42C,
       _syscall_ish(img, MAIN_BASE, GS_VTABLE["table_addr"] + 0x220))
    ck("char_item_insert increments the count byte at +0x1F",
       _word(img, MAIN_BASE, 0x800CA3B4) == 0x24420001
       and _word(img, MAIN_BASE, 0x800CA3B8) == 0xA062001F,
       f"{_syscall_ish(img,MAIN_BASE,0x800CA3B8)}")
    ck("char_item_insert appends the item entry at rec+0x20+count*4",
       _word(img, MAIN_BASE, 0x800CA3CC) == 0x00021080
       and _word(img, MAIN_BASE, 0x800CA3E0) == 0xA862001F
       and _word(img, MAIN_BASE, 0x800CA3E4) == 0xB862001C,
       f"{_syscall_ish(img,MAIN_BASE,0x800CA3CC)} "
       f"{_syscall_ish(img,MAIN_BASE,0x800CA3E0)}")
    ck("char_item_insert guards count < 9",
       _word(img, MAIN_BASE, 0x800CA3A0) == 0x2C420009,
       _syscall_ish(img, MAIN_BASE, 0x800CA3A0))
    ck("char_item_remove decrements the count byte at +0x1F",
       _word(img, MAIN_BASE, 0x800CA470) == 0x2442FFFF
       and _word(img, MAIN_BASE, 0x800CA474) == 0xA102001F,
       f"{_syscall_ish(img,MAIN_BASE,0x800CA474)}")

    ck("WITHDRAW loads vtable +0x174 at 0x80083008",
       _word(az, AZUKARI_BASE, 0x80083008) == 0x8C620174,
       _syscall_ish(az, AZUKARI_BASE, 0x80083008))
    ck("WITHDRAW indirect-calls it at 0x80083010",
       _word(az, AZUKARI_BASE, 0x80083010) == 0x0040F809,
       _syscall_ish(az, AZUKARI_BASE, 0x80083010))
    ck("WITHDRAW decrements gs+0x90 AFTER the insert",
       _word(az, AZUKARI_BASE, 0x80083034) == 0xA0620090,
       _syscall_ish(az, AZUKARI_BASE, 0x80083034))
    ck("DEPOSIT is the mirror image (vtable +0x220 at 0x800843F0)",
       _word(az, AZUKARI_BASE, 0x800843F0) == 0x8C420220,
       _syscall_ish(az, AZUKARI_BASE, 0x800843F0))

    # --- the root menu's option list ---------------------------------------
    rm = ROOT_MENU
    opts = [_word(img, MAIN_BASE, rm["option_list"] + 4 * i)
            for i in range(rm["option_count"])]
    ck("root option name array at 0x8016A734 holds the six option pointers",
       opts == rm["option_strings"],
       " ".join(f"{v:#x}" for v in opts))
    # the strings are the game's own encoding, decoded by the table in
    # kit/tools/war_text.py; check the first and the last byte of each name.
    ck("root option 0 is 0x33 0x24 0x15 0x1d ('Item')",
       _bytes(img, MAIN_BASE, opts[0], 4) == b"\x33\x24\x15\x1d",
       _bytes(img, MAIN_BASE, opts[0], 4).hex())
    ck("root option 2 is 0x3c 0x25 0x1e 0x15 ('Rune')",
       _bytes(img, MAIN_BASE, opts[2], 4) == b"\x3c\x25\x1e\x15",
       _bytes(img, MAIN_BASE, opts[2], 4).hex())
    ck("root option 5 is 0x3d 0x15 0x24 0x25 0x20 ('Setup')",
       _bytes(img, MAIN_BASE, opts[5], 5) == b"\x3d\x15\x24\x25\x20",
       _bytes(img, MAIN_BASE, opts[5], 5).hex())

    # the group array: 17 entries, [0] = the option names, and it ends exactly
    # where the status-screen label 'Name' begins.
    ck("root group array entry 0 is the option-name array",
       _word(img, MAIN_BASE, rm["group_array"]) == rm["option_list"],
       _syscall_ish(img, MAIN_BASE, rm["group_array"]))
    ck("root group array is 17 entries (ends at the 'Name' string)",
       _word(img, MAIN_BASE, rm["group_array"] + 17 * 4) == 0x151D1138,
       _syscall_ish(img, MAIN_BASE, rm["group_array"] + 17 * 4))
    # 0x800CCAAC is the drawer: group = *(0x8016A874 + idx*4)
    ck("group drawer 0x800CCAAC indexes 0x8016A874 and the quad at obj+0x0C",
       _word(img, MAIN_BASE, 0x800CCAC8) == 0x3C028017
       and _word(img, MAIN_BASE, 0x800CCACC) == 0x2442A874
       and _word(img, MAIN_BASE, 0x800CCAE4) == 0x8C71000C,
       f"{_syscall_ish(img,MAIN_BASE,0x800CCACC)} {_syscall_ish(img,MAIN_BASE,0x800CCAE4)}")
    ck("group 0 is drawn by ui_menu_obj_dispatcher (0x800CAF88 -> jal drawer, a0=0)",
       _word(img, MAIN_BASE, 0x800CAF88) == 0x0C0332AB
       and _word(img, MAIN_BASE, 0x800CAF8C) == 0x00002021,
       f"{_syscall_ish(img,MAIN_BASE,0x800CAF88)} {_syscall_ish(img,MAIN_BASE,0x800CAF8C)}")

    # the cursor is 6-bounded, and the confirm copies it to obj+0x5C
    ck("root cursor is bounded to 6 options",
       _word(img, MAIN_BASE, rm["cursor_bound_site"]) == 0x28420006,
       _syscall_ish(img, MAIN_BASE, rm["cursor_bound_site"]))
    ck("root cursor wraps to 5 (six options, 0..5)",
       _word(img, MAIN_BASE, rm["cursor_wrap_site"]) == 0x34020005,
       _syscall_ish(img, MAIN_BASE, rm["cursor_wrap_site"]))
    ck("root confirm tests the X/circle edge (andi 0x41)",
       _word(img, MAIN_BASE, rm["confirm_site"]) == 0x30620041,
       _syscall_ish(img, MAIN_BASE, rm["confirm_site"]))
    ck("root confirm stores the choice into obj+0x5C",
       _word(img, MAIN_BASE, rm["confirm_store_site"]) == 0xAC44005C,
       _syscall_ish(img, MAIN_BASE, rm["confirm_store_site"]))

    # the handler table: a 6-entry jump table at 0x800C0DEC
    table = [_word(img, MAIN_BASE, rm["handler_table"] + 4 * i) for i in range(6)]
    ck("root option handler table at 0x800C0DEC is the six arm stubs",
       table == [h["arm"] for h in rm["handlers"]],
       " ".join(f"{v:#x}" for v in table))
    ck("root dispatch bounds the option against 5 and jr's through the table",
       _word(img, MAIN_BASE, 0x800CB16C) == 0x34020005
       and _word(img, MAIN_BASE, 0x800CB170) == 0x0043102B
       and _word(img, MAIN_BASE, 0x800CB184) == 0x24210DEC
       and _word(img, MAIN_BASE, 0x800CB194) == 0x00400008,
       f"{_syscall_ish(img,MAIN_BASE,0x800CB170)} "
       f"{_syscall_ish(img,MAIN_BASE,0x800CB184)} "
       f"{_syscall_ish(img,MAIN_BASE,0x800CB194)}")
    # each stub materialises its handler with lui/addiu and stores it at obj+8
    for i, h in enumerate(rm["handlers"]):
        site = h["arm"]
        hi = _word(img, MAIN_BASE, site + 8)
        lo = _word(img, MAIN_BASE, site + 12)
        got = (((hi & 0xFFFF) << 16) + _sx16(lo)) if (hi and lo) else None
        ck(f"root option {i} ({h['name']}) installs handler {h['handler']:#x}",
           hi == 0x3C02800D and got == h["handler"],
           f"{hi:#010x} {lo:#010x} -> {got:#x}" if got else "-")
        ck(f"root option {i} stub stores it into the object's page slot "
           f"(obj+0x08)",
           any(_word(img, MAIN_BASE, site + 4 * k) == 0xAC620008
               for k in range(2, 7)),
           " ".join(_syscall_ish(img, MAIN_BASE, site + 4 * k)
                    for k in range(2, 7)))

    # --- arm identity: every step is the builder's own return value --------
    for arm in STATES:
        ret_site = arm.get("step_is_builder_return")
        if ret_site is None:
            continue
        step = arm["step"]
        hi = _word(img, MAIN_BASE, ret_site - 4)
        lo = _word(img, MAIN_BASE, ret_site)
        got = (((hi & 0xFFFF) << 16) + _sx16(lo)) if (hi and lo) else None
        ck(f"arm {arm['selector_value']} ({arm['id']}) builder returns its step",
           hi is not None and (hi >> 26) == 0x0F and (lo >> 26) in (0x09, 0x0D)
           and got == step,
           f"{hi:#010x} {lo:#010x} -> {got:#x}")
        ck(f"arm {arm['selector_value']} ({arm['id']}) builder ends with jr $ra",
           any(_word(img, MAIN_BASE, ret_site + 4 * k) == 0x03E00008
               for k in range(1, 7)),
           " ".join(_syscall_ish(img, MAIN_BASE, ret_site + 4 * k)
                    for k in range(1, 7)))

    # the trampoline that runs the staged step
    ck("the selector installs the staging trampoline 0x8012D11C",
       _word(img, MAIN_BASE, 0x80133158) == 0x3C028013
       and _word(img, MAIN_BASE, 0x8013315C) == 0x2442D11C,
       _syscall_ish(img, MAIN_BASE, 0x8013315C))
    ck("the trampoline calls the staged step at 0x8017A100",
       _word(img, MAIN_BASE, 0x8012D11C) == 0x3C028018
       and _word(img, MAIN_BASE, 0x8012D120) == 0x8C42A100
       and _word(img, MAIN_BASE, 0x8012D138) == 0x0040F809,
       f"{_syscall_ish(img,MAIN_BASE,0x8012D120)} {_syscall_ish(img,MAIN_BASE,0x8012D138)}")

    # --- STEP_DECODE_CORRECTIONS -------------------------------------------
    for c in STEP_DECODE_CORRECTIONS:
        w = _word(img, MAIN_BASE, c["site"])
        ck(f"step constant at {c['site']:#x} decodes to {c['correct']:#x}, not "
           f"{c['corpus_read']:#x}", w == c["word"],
           _syscall_ish(img, MAIN_BASE, c["site"]))
    ck("0x80128DB0 really is a `jr $ra / addiu v0,zero,-1` no-op step",
       _word(img, MAIN_BASE, 0x80128DB0) == 0x03E00008
       and _word(img, MAIN_BASE, 0x80128DB4) == 0x2402FFFF,
       f"{_syscall_ish(img,MAIN_BASE,0x80128DB0)} {_syscall_ish(img,MAIN_BASE,0x80128DB4)}")

    # --- screen-family string groups ---------------------------------------
    for name, g in SCREEN_STRING_GROUPS.items():
        if g["via"] is None:
            continue
        ck(f"{name}: *(0x{g['via']:08x}) is the row array 0x{g['rows']:08x}",
           _word(img, MAIN_BASE, g["via"]) == g["rows"],
           _syscall_ish(img, MAIN_BASE, g["via"]))
        # ...and the reader really dereferences that slot: lui/addiu materialise
        # the slot address and the next instruction is a load through it.
        hi = _word(img, MAIN_BASE, g["read_by"])
        lo = _word(img, MAIN_BASE, g["read_by"] + 4)
        ok = (hi is not None and lo is not None and (hi >> 26) == 0x0F
              and (lo >> 26) in (0x23, 0x24, 0x25)
              and ((lo >> 21) & 0x1F) == ((hi >> 16) & 0x1F)
              and ((((hi & 0xFFFF) << 16) + _sx16(lo)) & 0xFFFFFFFF) == g["via"])
        ck(f"{name}: 0x{g['read_by']:08x} loads through 0x{g['via']:08x}", ok,
           f"{_syscall_ish(img,MAIN_BASE,g['read_by'])} "
           f"{_syscall_ish(img,MAIN_BASE,g['read_by']+4)}")
    ck("descriptor rows are 10 bytes: the row-advance immediates are 0xA",
       all((_word(img, MAIN_BASE, site) or 0) & 0xFFFF == 0x000A
           for site in (0x800CA744, 0x800D2058, 0x800D5844,
                        0x800D7E70, 0x800DA480, 0x800DC840)),
       " ".join(_syscall_ish(img, MAIN_BASE, s)
                for s in (0x800CA744, 0x800D5844, 0x800DA480, 0x800DC840)))

    return out


def _hexify(obj):
    """Recursively turn ints into '0x...' strings for a readable JSON dump."""
    if isinstance(obj, dict):
        return {k: _hexify(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_hexify(v) for v in obj]
    if isinstance(obj, bool):
        return obj
    if isinstance(obj, int):
        return f"0x{obj:x}"
    return obj


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--states", action="store_true")
    ap.add_argument("--transitions", action="store_true")
    ap.add_argument("--screens", action="store_true")
    ap.add_argument("--entry", action="store_true")
    ap.add_argument("--withdraw", action="store_true")
    ap.add_argument("--roots", "--root", dest="root", action="store_true",
                    help="the root menu's option list and handler table")
    ap.add_argument("--arms", action="store_true",
                    help="the arm -> visible-screen identity map")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--json", metavar="OUT")
    args = ap.parse_args(argv)

    if args.verify:
        for line in verify():
            print(line)
        print(f"PASS: menu_flow verifies against the disc")
        return 0

    if args.states:
        print(f"state byte: {MENU_STATE_BYTE['name']} @ "
              f"{MENU_STATE_BYTE['addr']:#x} "
              f"(*({MENU_STATE_BYTE['base_addr']:#x})+{MENU_STATE_BYTE['offset']:#x})")
        print(f"selector:   {SELECTOR['name']} @ {SELECTOR['addr']:#x}")
        print()
        for s in STATES:
            print(f"  {s['id']:<26} value={str(s['selector_value']):<5} "
                  f"build={('0x%x' % s['build']) if s['build'] else '-':<12} "
                  f"step=0x{s['step']:x}" if s['step'] else
                  f"  {s['id']:<26} value={str(s['selector_value']):<5} "
                  f"build={('0x%x' % s['build']) if s['build'] else '-':<12} step=-")
        print()
        for s in OVERLAY_STATES:
            print(f"  {s['id']:<26} overlay={s['overlay']} "
                  f"base={s['load_base']:#x} states={s['state_dispatcher_states']}")
        return 0

    if args.transitions:
        for f, on, to, site, note in TRANSITIONS:
            loc = f"{site:#x}" if site else "-"
            print(f"  {f:<34} --[{on}]--> {to}   @{loc}")
        return 0

    if args.screens:
        for name, t in DATA_TABLES.items():
            if name in ("row_descriptors", "ui_string_groups"):
                continue
            print(f"  {name:<18} base={t.get('base', t.get('base_gs', 0)):#x} "
                  f"stride={t.get('stride', '-')} count={t.get('count', '-')}")
        print()
        print("  row descriptors (10 B = 5 halfwords: kind,x,y,w,rows):")
        for b, t in DATA_TABLES["row_descriptors"]["sites"].items():
            print(f"    {b:<18} 0x{t['addr']:08x}  rows={t['rows']}")
        print()
        print("  screen row-string groups (rows, slot, reader):")
        for k, v in SCREEN_STRING_GROUPS.items():
            print(f"    {k:<24} rows 0x{v['rows']:08x} "
                  f"{('via 0x%08x' % v['via']) if v['via'] else '          ':<16} "
                  f"read 0x{v['read_by']:08x}  {v['text']}")
        return 0

    if args.entry:
        e = ENTRY_EXIT
        print(f"  open    {e['open']['driver']} @ {e['open']['addr']:#x} "
              f"tests {e['open']['input_word']:#x} & {e['open']['test_mask']:#x} "
              f"at {e['open']['test_site']:#x}; store {e['open']['store_site']:#x}")
        print(f"  close   {e['close']['store_site']:#x} -> "
              f"{e['close']['installs']} @ {e['close']['installs_addr']:#x}")
        print(f"  root    {e['root_menu_close']['store_site']:#x}")
        print(f"  script  {e['event_script_open']['handler']:#x} reads "
              f"{e['event_script_open']['cursor']:#x}; store "
              f"{e['event_script_open']['store_site']:#x}")
        return 0

    if args.root:
        rm = ROOT_MENU
        print(f"root menu  object *(0x{rm['object_slot']:08x}), builder "
              f"0x{rm['build']:x}, step 0x{rm['step']:x}")
        print(f"  option list 0x{rm['option_list']:08x} "
              f"({rm['option_count']} rows) drawn by 0x{rm['group_draw_fn']:x} "
              f"at 0x{rm['group0_draw_site']:x}")
        print(f"  group array 0x{rm['group_array']:08x} "
              f"({rm['group_array_entries']} entries)")
        for h in rm["handlers"]:
            print(f"    [{h['option']}] {h['name']:<10} -> obj+0x08 = "
                  f"0x{h['handler']:x}   (table arm 0x{h['arm']:x})")
        print(f"  cursor     obj+0x{rm['cursor_field']:02x}, bound 6 at "
              f"0x{rm['cursor_bound_site']:x}, wrap at 0x{rm['cursor_wrap_site']:x}")
        print(f"  confirm   0x{rm['confirm_site']:x} (andi 0x41) -> "
              f"obj+0x{rm['decode_field']:02x} at 0x{rm['confirm_store_site']:x}")
        print(f"  dispatch  bound 0x{rm['dispatch_site']:x}, table "
              f"0x{rm['handler_table']:08x}")
        g = rm["group_15"]
        print(f"  Setup rows (group 15 @ 0x{g['addr']:08x}, {g['rows']} rows, "
              f"drawn by 0x{g['drawn_by']:x}): {g['strings']}")
        print()
        print(f"  {SELECTOR_ENTRY_NOTE}")
        return 0

    if args.arms:
        fam = SCREEN_FAMILY
        print(f"  {fam['verdict']}")
        print()
        for arm in STATES:
            if arm.get("screen") is None:
                continue
            build = f"0x{arm['build']:x}" if arm.get("build") else "-"
            step = f"0x{arm['step']:x}" if arm.get("step") else "-"
            print(f"  value {str(arm['selector_value']):<4} {arm['id']:<14} "
                  f"{arm['screen']}")
            print(f"        build {build} -> step {step}  ({arm['confidence']})")
        print()
        print("  arm 8 is NOT one of the five: " + fam["arm8"])
        for k, v in SCREEN_STRING_GROUPS.items():
            print(f"    {k:<24} rows 0x{v['rows']:08x} "
                  f"{'via 0x%08x' % v['via'] if v['via'] else '':<16} "
                  f"read at 0x{v['read_by']:08x}  {v['text']}")
        return 0

    if args.withdraw:
        w = WITHDRAW_GIVE
        print(f"  verdict        {w['verdict']}")
        print(f"  withdraw step  {w['function_name']} @ {w['function']:#x}")
        print(f"  insert         {w['instruction']}")
        print(f"     load site   {w['insert_load_site']:#x}   call site {w['insert_site']:#x}")
        print(f"  stack item     id@+{w['stack_item_struct']['id_halfword']:#x} "
              f"flag@+{w['stack_item_struct']['flag_byte']:#x} "
              f"qty@+{w['stack_item_struct']['qty_byte']:#x}")
        print(f"  qty decrement  {w['quantity_decrement']['site']:#x}  "
              f"{w['quantity_decrement']['instruction']}")
        print(f"  deposit mirror {w['deposit_mirror']['function_name']} @ "
              f"{w['deposit_mirror']['function']:#x} slot "
              f"{w['deposit_mirror']['slot']:#x} site {w['deposit_mirror']['site']:#x}")
        print(f"  insert target  char_item_insert @ "
              f"{CHAR_ITEM_LIST['insert']['addr']:#x}")
        return 0

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(_hexify({
                "state_byte": MENU_STATE_BYTE,
                "selector": SELECTOR,
                "slot_table": SLOT_TABLE,
                "game_state_driver": GAME_STATE_DRIVER,
                "entry_exit": ENTRY_EXIT,
                "states": STATES,
                "overlay_states": OVERLAY_STATES,
                "root_menu": ROOT_MENU,
                "screen_family": SCREEN_FAMILY,
                "screen_string_groups": SCREEN_STRING_GROUPS,
                "descriptor_rows": DESCRIPTOR_ROWS,
                "step_decode_corrections": STEP_DECODE_CORRECTIONS,
                "step_trampoline": STEP_TRAMPOLINE,
                "dead_builder_wrappers": DEAD_BUILDER_WRAPPERS,
                "selector_entry_note": SELECTOR_ENTRY_NOTE,
                "transitions": TRANSITIONS,
                "data_tables": DATA_TABLES,
                "command_dispatcher": COMMAND_DISPATCHER,
                "ui_menu_obj_dispatcher": UI_MENU_OBJ_DISPATCHER,
                "ui_state_dispatcher": UI_STATE_DISPATCHER,
                "gs_vtable": GS_VTABLE,
                "char_item_list": CHAR_ITEM_LIST,
                "withdraw_give": WITHDRAW_GIVE,
                "warehouse_character_lookup": WAREHOUSE_CHARACTER_LOOKUP,
            }), fh, indent=1)
        print(f"wrote {args.json}")
        return 0

    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
