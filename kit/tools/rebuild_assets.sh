#!/usr/bin/env bash
# rebuild_assets.sh -- one-command clean rebuild of the Suikoden static
# asset pipeline.
#
#   disc bytes -> tools/bootstrap_sources.py   (fresh source extraction)
#             -> tools/lzss.py (canonical LZSS)
#             -> tools/parse_04play.py -> tools/dump_sprites.py
#             -> tools/make_contacts.py (+ work/character_names.json)
#             -> tools/build_area_cluts.py
#             -> tools/export_assets.py       (package + validated manifest)
#
# UPDATED 2026-10-04 (milestone 5 of asset_pipeline_consolidation_plan):
#   * The 04_PLAY / DATA sources are now BOOTSTRAPPED FROM THE DISC through
#     tools/bootstrap_sources.py, so kit/extracted is no longer a prerequisite.
#     It is still used as the idempotency reference by the bootstrap's own tests.
#   * The exporter is now IN the gate. A package whose manifest fails validation
#     fails the build, so the graphics count assertions can no longer stand in
#     for package validation.
#   * Two isolated builds: set BUILD_ROOT to build everything under one fresh
#     directory, then compare two roots with tools/compare_builds.py:
#         bash kit/tools/rebuild_assets.sh
#         BUILD_ROOT=/tmp/b1 bash kit/tools/rebuild_assets.sh
#         BUILD_ROOT=/tmp/b2 bash kit/tools/rebuild_assets.sh
#         python3 kit/tools/compare_builds.py /tmp/b1 /tmp/b2   # must agree
#
# Usage:  bash kit/tools/rebuild_assets.sh
# Env:    PYTHON       python interpreter to use (default: python3)
#         DISC_IMAGE   override for the disc image path (exported as
#                      $SUIKODEN_DISC); when unset disc.py resolves it.
#         BUILD_ROOT   when set, ALL outputs go under it (isolated run).
#         SUIKODEN_CURATED  curated metadata input root
#                      (default kit/work/accepted, always read-only here).
#
# Exit 0 only if every step passes and every count verifies;
# any failure aborts non-zero with a clear message.
set -euo pipefail

# Fail if a rebuild step imports the historical instruction runner.
export SUIKODEN_STATIC_ONLY=1

# ---------------- Step 0: sources & prerequisites ----------------
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
TOOLS="$KIT/tools"
"$PYTHON" "$TOOLS/prepare_layout.py"

if [ -n "${DISC_IMAGE:-}" ]; then
    export SUIKODEN_DISC="$DISC_IMAGE"
fi

# Build outputs live under work/build; BUILD_ROOT redirects them for comparison.
# prepare_layout exposes the disc catalogs and local output directories.
if [ -n "${BUILD_ROOT:-}" ]; then
    SRC_ROOT="$BUILD_ROOT/src"
    OUT_SPRITES="$BUILD_ROOT/dump_sprites"
    OUT_CONTACTS="$BUILD_ROOT/contacts"
    OUT_ATLAS="$BUILD_ROOT/area_atlas"
    OUT_SCENE="$BUILD_ROOT/area_scene"
    OUT_PKG="$BUILD_ROOT/package"
    OUT_PHYSICAL="$BUILD_ROOT/physical_runes"
else
    SRC_ROOT="$KIT/work/build/src"
    OUT_SPRITES="$KIT/work/build/dump_sprites"
    OUT_CONTACTS="$KIT/work/build/contacts"
    OUT_ATLAS="$KIT/work/build/area_atlas"
    OUT_SCENE="$KIT/work/build/area_scene"
    OUT_PKG="$KIT/work/build/package"
    OUT_PHYSICAL="$KIT/work/build/physical_runes"
fi
SRC_DATA="$SRC_ROOT/DATA"
SRC_04PLAY="$SRC_DATA/04_PLAY"
LBA_JSON="$KIT/data/catalogs/extracted/overlay_lba_table.json"
NAMES_JSON="$KIT/data/catalogs/character_names.json"
CURATED="${SUIKODEN_CURATED:-$KIT/work/accepted}"

fail() { echo "BUILD FAILED: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

# safe_wipe DIR EXPECTED_GLOB...
# Wipes DIR, but refuses to destroy anything it did not generate. Regenerating
# an output directory must never silently delete a curated file -- on 2026-10-03
# a plain `rm -rf` here destroyed kit/work/dump_sprites/f_anims.json (f-record
# animation data that NO tool in this kit regenerates) on every single run.
safe_wipe() {
    local dir="$1"; shift
    [ -e "$dir" ] || return 0
    local keep="" f base ok
    while IFS= read -r f; do
        base="$(basename "$f")"
        ok=0
        for pat in "$@"; do
            # shellcheck disable=SC2053
            case "$base" in $pat) ok=1; break ;; esac
        done
        [ "$ok" -eq 1 ] || keep="$keep $f"
    done < <(find "$dir" -type f)
    if [ -n "$keep" ]; then
        echo "safe_wipe: PRESERVING files this build does not generate:"
        for f in $keep; do echo "    $f"; done
        # move them aside, wipe, restore
        local tmp; tmp="$(mktemp -d)"
        for f in $keep; do
            mkdir -p "$tmp/$(dirname "${f#$dir/}")"
            mv "$f" "$tmp/${f#$dir/}"
        done
        rm -rf "$dir"
        mkdir -p "$dir"
        (cd "$tmp" && tar cf - .) | (cd "$dir" && tar xf -)
        rm -rf "$tmp"
        echo "safe_wipe: restored the preserved files"
    else
        rm -rf "$dir"
    fi
}

step "Step 0: prerequisites"
command -v "$PYTHON" >/dev/null 2>&1 || fail "python interpreter not found: $PYTHON"
"$PYTHON" -c "import PIL" 2>/dev/null || fail "PIL (pillow) not importable under $PYTHON (pip install -r kit/requirements.txt)"
"$PYTHON" -c "import numpy" 2>/dev/null || fail "numpy not importable under $PYTHON (pip install -r kit/requirements.txt)"

# Resolve the disc through tools/disc.py -- it is the single source of truth
# (.bin vs .iso, $SUIKODEN_DISC, explicit-vs-search) and prints the full search
# list itself if nothing is found.
DISC_IMAGE="$("$PYTHON" - "$TOOLS" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import disc
try:
    print(disc.resolve()[0])
except disc.DiscNotFound as ex:
    sys.stderr.write(str(ex) + "\n")
    sys.exit(1)
PYEOF
)" || fail "disc.py could not resolve a disc image"
[ -f "$DISC_IMAGE" ] || fail "disc image missing: $DISC_IMAGE"
[ -f "$LBA_JSON" ] || fail "LBA table missing: $LBA_JSON"
[ -f "$NAMES_JSON" ] || fail "character names input missing: $NAMES_JSON"
[ -d "$CURATED" ] || fail "curated metadata root missing: $CURATED"
echo "KIT=$KIT"
echo "PYTHON=$PYTHON"
echo "disc image: $DISC_IMAGE"
echo "source root: $SRC_ROOT"
echo "package out: $OUT_PKG"
if [ -n "${BUILD_ROOT:-}" ]; then echo "ISOLATED BUILD_ROOT=$BUILD_ROOT"; fi

# ---------------- Step 0b: bootstrap sources from the disc ----------------
# kit/extracted is deliberately NOT read here. The extraction is regenerated
# from the disc on every build and is idempotent, so this step is cheap.
step "Step 0b: bootstrap DATA sources from the disc -> $SRC_ROOT"
"$PYTHON" "$TOOLS/bootstrap_sources.py" --set DATA --out "$SRC_ROOT" \
    || fail "bootstrap_sources.py failed"
[ -d "$SRC_04PLAY" ] || fail "bootstrap produced no 04_PLAY dir: $SRC_04PLAY"
n_src="$(ls "$SRC_04PLAY"/*.BIN | wc -l)"
[ "$n_src" -eq 78 ] || fail "expected 78 bootstrapped 04_PLAY files, found $n_src"
echo "bootstrapped 04_PLAY files: $n_src"

# ---------------- Step 1: regression gates ----------------
step "Step 1: regression gate (tools/regress.py)"
"$PYTHON" "$KIT/tests/test_prepare_layout.py" || fail "layout compatibility tests failed"
"$PYTHON" "$TOOLS/regress.py" --corpus "$SRC_DATA" || fail "regress.py not green"
step "Step 1b: disc reader tests"
"$PYTHON" "$KIT/tests/test_iso_extract.py" || fail "iso_extract tests failed"
step "Step 1c: PS1 VRAM model tests"
"$PYTHON" "$KIT/tests/test_psx_vram.py" || fail "psx_vram tests failed"
step "Step 1d: SPU tests"
"$PYTHON" "$KIT/tests/test_spu_adpcm.py" || fail "spu_adpcm tests failed"
"$PYTHON" "$KIT/tests/test_xa_decode.py" || fail "independent XA codec checks failed"
"$PYTHON" "$KIT/tests/test_defeat_audio.py" || fail "static defeat audio checks failed"
"$PYTHON" "$KIT/tests/test_spu_envelope.py" || fail "SPU envelope/first-traversal tests failed"
"$PYTHON" "$KIT/tests/test_spu_reverb.py" || fail "SPU reverb/mixer reference-vector tests failed"
"$PYTHON" "$KIT/tests/test_seq_controls.py" || fail "SEQ static control/reverb tests failed"
"$PYTHON" "$KIT/tests/test_seq_mix.py" || fail "SEQ static volume/pan tests failed"
"$PYTHON" "$KIT/tests/test_seq_bend.py" || fail "SEQ static bend/pitch tests failed"
"$PYTHON" "$KIT/tests/test_seq_voices.py" || fail "SEQ static voice allocation and flush tests failed"
"$PYTHON" "$KIT/tests/test_seq_voice_ramps.py" || fail "SEQ static per-voice transition tests failed"
"$PYTHON" "$KIT/tests/test_audio_fade_modes.py" || fail "Game audio fade mode tests failed"
"$PYTHON" "$KIT/tests/test_seq_sound_commands.py" || fail "SEQ sound request/lifecycle tests failed"
"$PYTHON" "$KIT/tests/test_seq_event_renderer.py" || fail "SEQ ordered renderer tests failed"
"$PYTHON" "$KIT/tests/test_seq_loops.py" || fail "SEQ native loop playback tests failed"
"$PYTHON" "$KIT/tests/test_seq_tick_cadence.py" || fail "SEQ tick cadence tests failed"
"$PYTHON" "$KIT/tests/test_seq_clock.py" || fail "SEQ static quantized clock tests failed"
"$PYTHON" "$KIT/tests/test_seq_tempo.py" || fail "SEQ tempo consumer tests failed"
"$PYTHON" "$KIT/tests/test_seq_pitch.py" || fail "SEQ pitch consumer tests failed"
"$PYTHON" "$KIT/tests/test_vag_extents.py" || fail "VAG extent tests failed"
"$PYTHON" "$KIT/tests/test_vab_tones.py" || fail "VAB tone routing tests failed"
"$PYTHON" "$KIT/tests/test_seq_bank_slots.py" || fail "SEQ bank slot tests failed"
"$PYTHON" "$KIT/tests/test_unite_target_flag.py" || fail "unite target flag tests failed"
"$PYTHON" "$KIT/tests/test_talisman_unite.py" || fail "Talisman/Fisherman static contract checks failed"
"$PYTHON" "$KIT/tests/test_journey_battle.py" || fail "connected episode static spell/status contracts failed"
"$PYTHON" "$KIT/tests/test_battle_exit.py" || fail "battle exit static contract checks failed"
"$PYTHON" "$KIT/tests/test_battle_bribe.py" || fail "battle Bribe static contract checks failed"
"$PYTHON" "$KIT/tests/test_battle_free_will_static.py" || fail "battle Free Will static witness tests failed"
"$PYTHON" "$KIT/tests/test_rabbit_target_scan_static.py" || fail "Rabbit static target-scan checks failed"
"$PYTHON" "$KIT/tests/test_source_enemy_target_scan_static.py" || fail "source enemy static target-scan checks failed"
"$PYTHON" "$KIT/tests/test_bonbon_source_motion_static.py" || fail "BonBon static motion checks failed"
"$PYTHON" "$KIT/tests/test_wild_boar_source.py" || fail "Wild boar static actor source checks failed"
"$PYTHON" "$KIT/tests/test_battle_departure.py" || fail "balloon departure static motion checks failed"
"$PYTHON" "$TOOLS/battle_departure.py" --check || fail "stale balloon departure motion report"
"$PYTHON" "$KIT/tests/test_world_b_party.py" || fail "Region B party static clock and retained trace checks failed"
"$PYTHON" -B "$KIT/tests/test_vb6_room0_population.py" || fail "VB6 village population source tests failed"
"$PYTHON" "$KIT/tests/test_field_initializers.py" || fail "field initialization source tests failed"
"$PYTHON" "$KIT/tests/test_field_party_queue.py" || fail "field party queue static source tests failed"
"$PYTHON" "$KIT/tests/test_field_dialogue.py" || fail "field dialogue static source tests failed"
"$PYTHON" "$KIT/tests/test_companion_page_tables.py" || fail "companion page-table tests failed"
"$PYTHON" "$KIT/tests/test_duel_embedded_residency.py" || fail "duel residency tests failed"
"$PYTHON" "$KIT/tests/test_duel_fade_rectangle.py" || fail "duel fade rectangle tests failed"
"$PYTHON" "$KIT/tests/test_tile_trigger_result.py" || fail "tile trigger result tests failed"
"$PYTHON" "$KIT/tests/test_text_packet_lowering.py" || fail "text packet lowering tests failed"
"$PYTHON" "$KIT/tests/test_system_glyphs.py" || fail "system glyph source tests failed"
"$PYTHON" "$KIT/tests/test_text_control04.py" || fail "text control04 tests failed"
"$PYTHON" "$KIT/tests/test_stone_composite_palettes.py" || fail "STONE composite palette tests failed"
"$PYTHON" "$KIT/tests/test_entity_graphics_selection.py" || fail "static entity graphics selection tests failed"
"$PYTHON" "$KIT/tests/test_entity_predicates.py" || fail "entity predicate tests failed"
"$PYTHON" "$KIT/tests/test_vb2_dice_states.py" || fail "VB2 dice UI state tests failed"
"$PYTHON" "$KIT/tests/test_vad_callbacks.py" || fail "VAD callback state tests failed"
"$PYTHON" "$KIT/tests/test_battle_picker.py" || fail "battle command picker tests failed"
"$PYTHON" "$KIT/tests/test_port_battle_picker.py" || fail "Zig picker conformance vectors failed"
"$PYTHON" "$KIT/tests/test_battle_resource_selection.py" || fail "battle resource selection tests failed"
"$PYTHON" "$KIT/tests/test_enemy_rewards.py" || fail "enemy reward and inventory tests failed"
"$PYTHON" "$KIT/tests/test_enemy_record_fields.py" || fail "enemy source record fields tests failed"
"$PYTHON" "$KIT/tests/test_battle_stat_refresh.py" || fail "battle stat refresh and actor selection tests failed"
"$PYTHON" "$KIT/tests/test_vcd_palettes.py" || fail "static VCD palette consumer tests failed"
"$PYTHON" "$KIT/tests/test_worldmap_descriptor_fields.py" || fail "world-map descriptor consumer tests failed"
"$PYTHON" "$KIT/tests/test_damage_instructions.py" || fail "damage instruction/model agreement failed"
"$PYTHON" "$KIT/tests/test_character_record_fields.py" || fail "character record field tests failed"
"$PYTHON" "$KIT/tests/test_character_status_word.py" || fail "character status word tests failed"
"$PYTHON" "$KIT/tests/test_character_growth_storage.py" || fail "character level-up byte-use tests failed"
"$PYTHON" "$KIT/tests/test_character_record_lookups.py" || fail "character record lookup copy tests failed"
"$PYTHON" "$KIT/tests/test_character_script_aliases.py" || fail "character script-byte alias tests failed"
"$PYTHON" "$KIT/tests/test_character_equipment_stats.py" || fail "character equipment stat tests failed"
"$PYTHON" "$KIT/tests/test_preparation.py" || fail "equipment and blacksmith source tests failed"
"$PYTHON" "$KIT/tests/test_rune_preparation.py" || fail "rune preparation source tests failed"
"$PYTHON" "$KIT/tests/test_magic_expansion.py" || fail "expanded magic static source checks failed"
"$PYTHON" "$KIT/tests/test_poison_rules.py" || fail "poison source tests failed"
"$PYTHON" "$KIT/tests/test_front_promotion.py" || fail "front promotion source tests failed"
"$PYTHON" "$KIT/tests/test_passive_runes_port.py" || fail "passive rune static source contracts failed"
"$PYTHON" "$KIT/tests/test_actor_status_static.py" || fail "actor status static source contracts failed"
"$PYTHON" "$KIT/tests/test_party_melee_export.py" || fail "party melee scripts, callback consumers and shared impact pixels failed"
"$PYTHON" "$KIT/tests/test_battle_actor_atlas.py" || fail "actor atlas pixel-preserving packing failed"
"$PYTHON" "$KIT/tests/test_balloon_departure.py" || fail "balloon departure source tests failed"
"$PYTHON" "$KIT/tests/test_enemy_policies.py" || fail "enemy policy source tests failed"
"$PYTHON" "$KIT/tests/test_enemy_ivy.py" || fail "Ivy vine static source/art checks failed"
"$PYTHON" "$KIT/tests/test_enemy_ivy_geometry.py" || fail "Ivy packet geometry witnesses failed"
"$PYTHON" "$KIT/tests/test_appraisal_catalogue.py" || fail "complete appraisal catalogue source checks failed"
"$PYTHON" "$TOOLS/enemy_ivy.py" --check || fail "stale Ivy vine source report"
"$PYTHON" "$KIT/tests/test_spell_effect_sources.py" || fail "spell effect source inventory tests failed"
"$PYTHON" "$KIT/tests/test_spell_effect_entries.py" || fail "spell effect sampling tests failed"
"$PYTHON" "$KIT/tests/test_battle_effect_vertices.py" || fail "spell effect vertex instruction checks failed"
"$PYTHON" "$KIT/tests/test_battle_drops.py" || fail "Drops choreography/geometry checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_source.py" || fail "Static spell callback compiler checks failed"
"$PYTHON" "$TOOLS/spell_scene_source.py" --scalars --check || fail "stale bulk spell scalar compiler report"
"$PYTHON" "$KIT/tests/test_spell_scene_objects.py" || fail "spell constructor loop compiler checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_columns.py" || fail "spell column compiler checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_wind.py" || fail "wind strip compiler checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_scolding.py" || fail "Scolding quad source checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_warp.py" || fail "Spell screen-sampling source checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_soul.py" || fail "Soul Eater lifecycle source checks failed"
"$PYTHON" "$KIT/tests/test_spell_scene_export.py" || fail "Portable spell scene checks failed"
"$PYTHON" "$KIT/tests/test_battle_audio.py" || fail "Battle audio checks failed"
"$PYTHON" "$KIT/tests/test_battle_sfx.py" || fail "Battle sound candidate checks failed"
"$PYTHON" "$KIT/tests/test_party_ranged_actors.py" || fail "Party ranged actor checks failed"
"$PYTHON" "$KIT/tests/test_assemble_battle_review.py" || fail "Battle candidate assembly checks failed"
"$PYTHON" "$KIT/tests/test_bundle_macos.py" || fail "Candidate app manifest checks failed"
"$PYTHON" "$KIT/tests/test_guardian_rule.py" || fail "Guardian rule checks failed"
"$PYTHON" "$KIT/tests/test_physical_runes_port.py" || fail "physical rune static contract checks failed"
"$PYTHON" "$KIT/tests/test_storage_port.py" || fail "storage source tests failed"
"$PYTHON" "$KIT/tests/test_appraisal_port.py" || fail "appraisal source tests failed"
"$PYTHON" "$KIT/tests/test_canonical_start.py" || fail "canonical source entry tests failed"
"$PYTHON" "$KIT/tests/test_campaign_coverage.py" || fail "campaign coverage inventory tests failed"
"$PYTHON" "$KIT/tools/check_port_plan.py" || fail "port roadmap references failed"
"$PYTHON" "$KIT/tests/test_weapon_rune_fragments.py" || fail "weapon rune fragment producer/consumer tests failed"
"$PYTHON" "$KIT/tests/test_palace_exit.py" || fail "palace exit script tests failed"
"$PYTHON" "$KIT/tests/test_worldmap_z_loader.py" || fail "Z world-map loader tests failed"
"$PYTHON" "$KIT/tests/test_worldmap_points.py" || fail "world-map point/camera tests failed"
"$PYTHON" "$KIT/tests/test_worldmap_scripted_routes.py" || fail "world-map scripted-route tests failed"
"$PYTHON" "$KIT/tests/test_xy_command_selection.py" || fail "coordinate command-source tests failed"
"$PYTHON" "$KIT/tests/test_play_s1_consumers.py" || fail "static S1 animation consumer tests failed"
"$PYTHON" "$KIT/tests/test_play_upload_path.py" || fail "04_PLAY upload path tests failed"
"$PYTHON" "$KIT/tests/test_text_layout.py" || fail "text layout tests failed"
"$PYTHON" "$KIT/tests/test_spu_loop.py" || fail "spu_loop tests failed"
step "Step 1e: MIPS writer-classification tests"
"$PYTHON" "$KIT/tests/test_scanner_writers.py" >/dev/null || fail "scanner writer tests failed"
echo "ok   test_scanner_writers.py"
step "Step 1f: scanner clobber/pointer-invalidation counterexample tests"
"$PYTHON" "$KIT/tests/test_scanner_clobbers.py" >/dev/null || fail "scanner clobber tests failed"
echo "ok   test_scanner_clobbers.py"
"$PYTHON" "$KIT/tests/test_scanner_control_flow.py" || fail "scanner control-flow and ownership tests failed"
"$PYTHON" "$KIT/tests/test_game_state_storage.py" || fail "game-state storage and heap-lifetime tests failed"
"$PYTHON" "$KIT/tests/test_gte_library_provenance.py" || fail "GTE library provenance tests failed"
step "Step 1g: visual bounds tests"
"$PYTHON" "$KIT/tests/test_visual_bounds.py" | tail -1 || fail "visual bounds tests failed"
step "Step 1h: area-render manifest tests"
"$PYTHON" "$KIT/tests/test_area_render_manifest.py" | tail -1 || fail "area render manifest tests failed"
step "Step 1n: area tilemap record-class tests"
"$PYTHON" "$KIT/tests/test_area_tilemap_probe.py" | tail -1 || fail "area tilemap probe tests failed"
step "Step 1o: area per-tile CLUT probe tests"
"$PYTHON" "$KIT/tests/test_visual_frame_probe.py" | tail -1 || fail "area frame probe tests failed"
step "Step 1p: area CLUT channel-trace tests"
"$PYTHON" "$KIT/tests/test_area_clut_trace.py" | tail -1 || fail "area CLUT trace tests failed"
step "Step 1q: area tile materials and independent VRAM sampling"
"$PYTHON" "$KIT/tests/test_area_tile_materials.py" || fail "area tile materials tests failed"
step "Step 1r: area scene composition counterexamples"
"$PYTHON" "$KIT/tests/test_area_scene.py" | tail -1 || fail "area scene tests failed"
# The world map's container structure: the five tile pages at S+0x08 (55/55
# containers of exactly 16,384 B), the per-atlas record table at S+0x10, S+0x04
# as an index bound, the inline CLUTs at S+0x18+k*0x200, and the tilemap chain
# (cell -> *8 -> tile-info record) that settles how the plane is composed.
# NOTE: this agent's first version shipped a "these do not compose" negative from
# that test; it was REFUTED (the plane is a tilemap whose cells index the pages).
# Producer kit/tools/world_map_pages.py; structure doc kit/docs/world_map_composition.md;
# the composition authority is kit/docs/world_map_render.md.
step "Step 1s: world map container structure (pages / blocks / constants)"
"$PYTHON" "$KIT/tests/test_world_map_pages.py" | tail -1 || fail "world map composition tests failed"
# The battle arithmetic: participant/slot layout re-derived by executing the
# index chain, both physical-damage branches property-tested over their whole
# input domain, the MIPS truncating remainder, the accuracy clamp [60,99], the
# HP-apply clamp, and the template-accessor offsets (the "not a stat block"
# reading of those accessors is corrected in test_growth_rules.py below: they
# dereference slot+0x0C, they do not read the character table).
"$PYTHON" "$KIT/tests/test_battle_formulas.py" | tail -1 || fail "battle formula tests failed"
# The battle remainder: the turn-order weight table's real address (0x8016BDC8,
# a lui sign-extension -- the corpus's 0x8017BDC8 was 64 KiB high, above the
# image end) and its 30 static weights, the writer of the heap weight array
# 0x80179FD0, the negative that 0x800F8174 has no reachable caller (its address
# survives only in an 87-entry code-pointer run that nothing reads), the
# magic-damage jump table, the BATTLE.BIN palette gap, and W_HEADER.BIN's
# LNK\x02 symbol framing.
"$PYTHON" "$KIT/tests/test_battle_remainder.py" | tail -1 || fail "battle remainder tests failed"
# Per-level growth, derived: the 78 x 0x50 record at gs+0x294 seeded from the
# SLUS default game-state block (0x80017544 copies 0x1D60 bytes), the level-up
# routine 0x800E9CC4 checked from source bytes, the complete (level, growth)
# input range for the two 48-word gain tables, the seven draws per level,
# stat saturation, the 1000-EXP threshold and the level-99 cap.
"$PYTHON" "$KIT/tests/test_growth_rules.py" | tail -1 || fail "growth rule tests failed"
# The per-battle EXP AWARD, the last underived battle rule: 0x800E9744 writes the
# pool the victory sequence reads, as max(5, sum_j XP[clamp(enemy_level-char_level,
# -14,15)] / party_count), doubled for record+0x4C == 0x16. The table at 0x8016BDC8
# is 30 static words (1..10000); the corpus's "turn-order weight" values were the
# same words shifted by 14 entries, which is what made the tail look non-monotone.
# The gate checks the routine's source words and independently verifies the
# front-loaded-then-floor curve over synthetic inputs.
"$PYTHON" "$KIT/tests/test_exp_award.py" | tail -1 || fail "exp award tests failed"
step "Step 1r2: battle asset decode + embedded sprite containers"
"$PYTHON" "$KIT/tests/test_battle_bin.py" | tail -1 || fail "battle bin tests failed"
"$PYTHON" "$KIT/tests/test_unite_reaction_assets.py" || fail "shared Unite impact export checks failed"
"$PYTHON" "$KIT/tests/test_actor_color.py" || fail "actor RGB source, compiler and merge checks failed"
"$PYTHON" "$KIT/tests/test_commander_source.py" || fail "Commander decision, target and callback source checks failed"
"$PYTHON" "$KIT/tests/test_enemy_orders.py" || fail "Commander actor export and shared-player witness checks failed"
"$PYTHON" "$KIT/tests/test_enemy_rabbit.py" || fail "Rabbit ordinary source and return-hop references failed"
"$PYTHON" "$KIT/tests/test_unite_linked_controllers.py" || fail "linked Unite controller checks failed"
"$PYTHON" "$KIT/tests/test_unite_couple_review.py" || fail "Couple export and source art checks failed"
"$PYTHON" "$KIT/tests/test_battle_decode_source.py" || fail "battle decode source tests failed"
"$PYTHON" "$KIT/tests/test_computed_clut_sites.py" || fail "computed CLUT site tests failed"
"$PYTHON" "$KIT/tests/test_atlas_pool.py" | tail -1 || fail "atlas pool tests failed"
"$PYTHON" "$KIT/tests/test_enemy_sprites.py" | tail -1 || fail "enemy sprite tests failed"
"$PYTHON" "$KIT/tests/test_battle_mock.py" | tail -1 || fail "battle mock tests failed"
# The standard battle's initial world placement: MAIN party writer 0x800DEBE8 and
# enemy writer 0x800DEE44. The producer is kit/tools/battle_placement.py; the test
# re-derives every encounter with plain byte arithmetic and both disc containers.
"$PYTHON" "$KIT/tests/test_battle_placement.py" | tail -1 || fail "battle placement tests failed"
# The WAR mode's labelled data module: WAR1.BIN's NUL-delimited string + pointer
# table at its exact offsets, and the fact that the overlays carry no symbols.
"$PYTHON" "$KIT/tests/test_war_strings.py" | tail -1 || fail "war string tests failed"
# The WAR mode's game text: the non-ASCII character table (cross-checked against
# dialogue_found.txt with a second decoder), the 36x25 unit roster, the 108x50
# leader lines, the 108x44 records, the per-battle boss attack names, and the
# fact that WAR1.BIN carries none of it.
"$PYTHON" "$KIT/tests/test_war_text.py" | tail -1 || fail "war text tests failed"
# The WAR mode's portrait bank: located from the palette bank (no guessed
# offsets), 108-113 blocks per file, every block a [u32 size][LZSS] container
# that decodes to exactly 4096 bytes (64x64 8bpp) with full consumption.
"$PYTHON" "$KIT/tests/test_war_graphics.py" | tail -1 || fail "war graphics tests failed"
# The dialogue portrait collection (DATA/03_SHIRO/DATA/FACE_*.BIN): 27 files ->
# 16384 B pages of four 64x64 portraits, all byte-identical to war planes
# 0..107, plus the 108-entry STONE name table and the 0x4B40 permutation.
"$PYTHON" "$KIT/tests/test_face_portraits.py" | tail -1 || fail "face portrait tests failed"
# Historical embedded duel tables (their IC/SKY render assignment was rejected).
# The separate IC trace pins the normal 32-entry writer and polygon consumer;
# visual acceptance remains user-gated.
"$PYTHON" "$KIT/tests/test_ikki_palettes.py" | tail -1 || fail "ikki palette tests failed"
"$PYTHON" "$KIT/tests/test_ikki_clut_trace.py" || fail "IC draw CLUT trace failed"
"$PYTHON" "$KIT/tests/test_ikki_animations.py" || fail "IC animation sequence/timing failed"
"$PYTHON" "$KIT/tests/test_ikki_rules.py" || fail "IKKI semantic duel rules failed"
# The SKY/BT backdrop DRAW: the two POLY_FT4 quad builders, their GetClut
# (vtable +0x8C -> +0x0E) and GetTpage (+0x6C -> +0x16) halfwords, the recovered
# coordinate tables in all three overlays, and the bounded negative that no
# upload site in these overlays writes the slots the draw samples.
"$PYTHON" "$KIT/tests/test_ikki_sky_bt_clut.py" || fail "SKY/BT draw CLUT trace failed"
# Four open art questions, closed from instructions and bytes: BATTLE.BIN's
# descriptor -> VRAM upload path and its d-table count convention (decided by the
# d-table's own allocation, not by the byte's value); the 04_PLAY piece-record
# walker at 0x800E211C (reached through the animation object's +0x30 field, which
# is why a lui sweep could not see it); the per-duel BT/SKY load groups read from
# the overlays' own data words; and what the 1,019 page-shaped containers depict.
# Every container is re-decoded here and its `used` compared against its declared
# comp_len, so a partial decode cannot pass.
"$PYTHON" "$KIT/tests/test_q_art.py" | tail -1 || fail "q_art (BATTLE.BIN / 04_PLAY pieces / duel groups / page containers) failed"
# The WAR mode's map and UI resources: the 16-byte descriptor system
# (dims, id, block array, clut pointer), 6 sprite atlases + 1 terrain grid +
# 2 map groups per overlay, every block a 16384-byte LZSS page.
"$PYTHON" "$KIT/tests/test_war_map.py" | tail -1 || fail "war map tests failed"
# MAIN.EXE's long-tail data tables: the item and equipment tables located by
# their fixed-stride NUL-terminated names (the largest gap the coverage report
# names).  Stride, counts, prices and the class/index bytes are all pinned.
"$PYTHON" "$KIT/tests/test_main_tables.py" | tail -1 || fail "main table tests failed"
# 04_PLAY piece geometry: the derived rectangle, its shuffled-tile null, and the
# three refuted alternative readings (masked / pitch12 / lowbyte).
"$PYTHON" "$KIT/tests/test_play_sprite_geometry.py" | tail -1 || fail "04_PLAY geometry tests failed"
# The `[u16 a][u16 b][u32 magic]` section record: ONE 0x18-byte header, TWO
# pointer conventions.  1,345 records in 177 overlays classify exhaustively as
# 226 container-relative (156 in the 78 04_PLAY files, 70 in 35 whole 04_PLAY
# containers embedded in 19 area overlays) and 1,119 absolute (82 files at
# 0x80010000, 17 at 0x80080000, the base confirmed by c_table adjacency rather
# than by a vote).  Every cited reader/relocator instruction word is re-read
# from MAIN.EXE's headerless image.
"$PYTHON" "$KIT/tests/test_section_records.py" | tail -1 || fail "section record tests failed"
# The overlay/area table class: encounter structs validated against the area
# `selectors` pointer arrays, plus the disproof of the contiguous-0x18-stride
# reading and the unsound DATA/TABLE heuristic.
"$PYTHON" "$KIT/tests/test_area_encounter_tables.py" | tail -1 || fail "area table tests failed"
# The WORLD MAP draw transform: the S header as a tile field (count/pal_count
# bytes, three pointer tables, the 64 palette selectors per atlas), the
# world->cell transform at 0x8014CEB4 with its div/mfhi modulo, the
# compare-and-subtract column wrap, the 20x15 cell window, and the two region
# records whose camera leaves the 120-row plane.  Every cited instruction word
# is re-read from MAIN.EXE's headerless image.
"$PYTHON" "$KIT/tests/test_world_map_render.py" | tail -1 || fail "world map draw transform tests failed"
# STATE_OF_KNOWLEDGE + the per-class state pages are generated from the fact
# registry, so the current-state answer can never drift from the recorded claims.
# The STATE pages are DERIVED from the registry, so the build REGENERATES them
# rather than demanding a committed copy.  The old --verify-only form made the
# build fail whenever any contributor added rows without also committing the
# regenerated pages -- which, with several agents appending extract_*.jsonl, was
# every time.  Regenerating is the sync guarantee; --verify remains available for
# a read-only check.
"$PYTHON" "$KIT/tools/corpus_state.py" >/dev/null || fail "state page generation failed"
"$PYTHON" "$KIT/tools/corpus_state.py" --verify | tail -1 || fail "state pages are out of sync with the registry"
"$PYTHON" "$KIT/tests/test_registry_reconciliation.py" || fail "registry reconciliation loses a source question"

# Corpus link integrity: every kit/docs reference and every [[wikilink]] must
# resolve.  ~1,050 inbound path references (936 registry `source` fields, 76 in
# tools/tests) are the provenance chain, and a stale pointer is a trap.
"$PYTHON" "$KIT/tests/test_corpus_links.py" | tail -1 || fail "corpus link check failed"

# Which `*_DATA.BIN` each world-map module loads, and that A and Z are both live slots.
"$PYTHON" "$KIT/tests/test_area_data_select.py" | tail -1 || fail "area data selection"

# Sector forms, pinned: `.8` files are Form 1 Data, and the disc's only Form 2 files
# are the two XA audio streams. Sector framing does not distinguish raw
# SPU audio from other Form1 data; test_dot8_audio.py proves the consumer.
"$PYTHON" "$KIT/tests/test_sector_forms.py" | tail -1 || fail "sector-form invariant broken"

# The 03_SHIRO art that is uploaded but had no located consumer, pinned by
# consumption path rather than by value range: the STONE page bank's RECT table
# has 18 entries (the loader's own `slti` bound), those pages are sampled by the
# overlay's own composite at 0x80081334 (one POLY_FT4 per 20-byte record of the
# page table at 0x80084D6C, and an 8-bit u that reaches 0xFF crosses into the
# next page column), the tablet quad's page coordinates are GetTpage call-site
# literals at 0x800833D8 (0x0099 = 8 bpp, x base 9, y base 1), the +0x780 field
# is a display-list head that is written back, and PAPER_*/YUGE_00/MIZU_00/HANA/
# CURIO_0 are reached through the load-group directory installed at ctx+0x14B8
# with index bounds equal to the group lengths (13 and 4).
"$PYTHON" "$KIT/tests/test_q_stone.py" | tail -1 || fail "q_stone ownership/draw invariants broken"

# Historical .8 framing and separate area-table instruction measurements.
# The positive CD→SPU decoder/consumer proof is test_dot8_audio.py below;
# the24→16 area transformer and party byte14 indices concern other buffers.
"$PYTHON" "$KIT/tests/test_q_dot8.py" | tail -1 || fail "q_dot8 record-format invariants broken"


# The manual/: the closed-ended description of the game.  Its three appendices are
# DERIVED -- A and C from the pages' own address citations, B from registry rows whose
# evidence is "open" -- so the build REGENERATES them, for the same reason the STATE
# pages are regenerated: a verify-only form fails whenever a contributor writes a page
# without also committing the appendices.
"$PYTHON" "$KIT/tools/generate_item_ledger.py" --verify || fail "item identity generation is stale"
"$PYTHON" "$KIT/tests/test_item_ledger_generation.py" || fail "item identity generation checks failed"
"$PYTHON" "$KIT/tools/manual_appendix.py" >/dev/null || fail "manual appendix generation failed"
"$PYTHON" "$KIT/tools/manual_appendix.py" --verify | tail -1 || fail "manual appendices out of sync"
# The link graph, and the rule that makes the contents a manifest: a link to a page
# that is neither written nor named in the table of contents is a failure.  --strict
# additionally requires the whole manifest to be written; the manual is complete as of
# 2026-10-07 (16 sections + 3 generated appendices), so the gate is now strict and a
# missing page fails the build.
"$PYTHON" "$KIT/tests/test_manual_links.py" --strict | tail -1 || fail "manual link graph check failed"

# The per-character stat template: SLUS_002.92 image 0x33274, 78 x 0x50,
# keyed by character id (the same 78 ids as the 04_PLAY sprite set).
"$PYTHON" "$KIT/tests/test_character_table.py" | tail -1 || fail "character table tests failed"
# The 04_PLAY walk-cycle anchor, derived from the atlas pixels: S2 is
# bottom-anchored in 78/78 with a <=2 px foot spread, S1 in only 9/78.
"$PYTHON" "$KIT/tests/test_play_cycle.py" | tail -1 || fail "play cycle tests failed"
# Area page banks: the .BIN overlays carry [u32 len][LZSS] page banks, found by a
# null-calibrated scan. 66 pages across 4 files, 0 in the shuffled null.
"$PYTHON" "$KIT/tests/test_area_page_banks.py" | tail -1 || fail "area page bank tests failed"
# The resource-group directory: dir[15] = {VC61, VB5A21, VB5B31}, the data
# companions of the code overlays VC6/VB5A2/VB5B3, loaded via gs[0x1bc4]+0x10.
"$PYTHON" "$KIT/tests/test_resource_groups.py" | tail -1 || fail "resource group tests failed"
# The texture-upload cluster: 8/9 members are called; 0x800C3BF0 (32x128) has
# zero references of any form and zero address literals anywhere on the disc.
"$PYTHON" "$KIT/tests/test_texture_upload_cluster.py" | tail -1 || fail "texture upload cluster tests failed"
# The 03_SHIRO / 12_IKKI content-page family: 133 files share one container
# ([u32 filesize-4][LZSS] -> exactly 16384 B), and the 0x8016B358 load-group
# directory is their ownership.  Also pins the STONE 0x4B40 permutation negative.
"$PYTHON" "$KIT/tests/test_shiro_pages.py" | tail -1 || fail "shiro pages tests failed"
# The 03_SHIRO pixel long tail: BATH is 24 128x128 8bpp pages tiling a 384x256
# sheet (file i -> RECT i of the table at 0x80085884; palette 0x8008D114 +
# bank*0x200); the 18 STONE_nn pages are zero-padded variable-size textures with
# no raster structure (a null-calibrated negative), the tablet's text and its
# state -> portrait-index table are overlay data, and the 0x8016B358 groups are
# read by BOOKS.BIN (PAPER + CURIO_0) and BATH.BIN (YUGE/MIZU/HANA/CURIO_0).
"$PYTHON" "$KIT/tests/test_shiro_pixel_tail.py" | tail -1 || fail "shiro pixel tail tests failed"
# MAIN's item-class tables: weapons (16 x 0x58 with 3 tier names), runes
# (31 x 0x24), unite attacks (26 x 0x24), consumables (5 x 0x24), plus the
# recorded negatives for monsters / shops / recipes / growth.
"$PYTHON" "$KIT/tests/test_main_item_tables.py" | tail -1 || fail "main item table tests failed"
# The item-id space and everything the menu and battle screens index by it: the
# 181-word pointer array at 0x80167658 bounds a 179-record table (ids 1..179),
# its four equipment classes, the 65 x 0x58 weapon table, the blacksmith's 79
# weapon ids and its sharpen rows, the 31 rune records and their four spell ids
# into the 33-entry spell-name table, and the 32 unite attacks at 0x8016CD0C
# named by the 33-word array at 0x8016D18C.
"$PYTHON" "$KIT/tests/test_item_tables.py" | tail -1 || fail "item table tests failed"
# Three residual questions closed from the instruction that consumes the field,
# not from the values: character record +0x4C is the character's rune number
# (0x8016A0E0[+0x4C], 0 = none) and 0x16 is the Fortune Rune, so the doubled
# experience award is that rune's effect; a unite attack's +0x18 is the member
# count with the member character ids at +0x1A (0x800F9210 / 0x800F9238), while
# +0x16 is a u16 flag field and +0x19 the unite id; and the resource table at
# 0x80164E68 is 71 rows whose +0x04/+0x06 are two u16 fields -- a rate the loader
# scales by ((v << 12) / 0xAC44) and a wrap sector it rewinds the read cursor to
# -- with +0x0B addressed by no instruction anywhere in the image.
"$PYTHON" "$KIT/tests/test_q_residue.py" | tail -1 || fail "q_residue tests failed"
# The menu system as a state machine: ONE state byte (*(0x8017BE20)+0x4E0) with
# an exhaustive 7-writer set, the selector 0x80132F60 and its builder arms, the
# frame-handler slot table 0x8017DA90, the START open / generic close, the
# AZUKARI load base 0x80080000, and the resolved withdraw item-give half
# (char_item_insert 0x800CA38C via game-state vtable slot +0x174).
# MAIN's top-level mode word, routes, local transition guards, and install targets.
"$PYTHON" "$KIT/tests/test_mode_map.py" || fail "mode map tests failed"
"$PYTHON" "$KIT/tests/test_menu_flow.py" | tail -1 || fail "menu flow tests failed"
"$PYTHON" "$KIT/tests/test_inn_export.py" || fail "inn semantic export tests failed"
"$PYTHON" "$KIT/tests/test_village_export.py" || fail "village semantic export tests failed"
"$PYTHON" "$KIT/tests/test_shop_export.py" || fail "shop semantic export tests failed"
"$PYTHON" "$KIT/tests/test_consumables.py" || fail "consumable source tests failed"
"$PYTHON" "$KIT/tests/test_battle_items.py" || fail "battle item source tests failed"
"$PYTHON" "$KIT/tests/test_dragon_seal_incense.py" || fail "Dragon seal incense static source tests failed"
"$PYTHON" "$KIT/tests/test_sacrificial_buddha.py" || fail "Sacrificial Buddha static source tests failed"
"$PYTHON" "$KIT/tests/test_battle_revival_art.py" || fail "revival actor art and independent VRAM tests failed"
"$PYTHON" "$KIT/tests/test_double_beat_sequence.py" || fail "Double-Beat static source and sequence motion tests failed"
"$PYTHON" "$KIT/tests/test_physical_critical.py" || fail "critical dispatch, source impact art and white-palette tests failed"
"$PYTHON" "$KIT/tests/test_physical_dodge.py" || fail "party miss clocks and source dodge geometry tests failed"
"$PYTHON" "$KIT/tests/test_counter_capabilities.py" || fail "counter weapon and enemy capability source checks failed"
"$PYTHON" "$KIT/tests/test_parry_capabilities.py" || fail "parry attacker weapon capability source checks failed"
"$PYTHON" "$KIT/tests/test_counter_actor_export.py" || fail "counter actor batch and independent source checks failed"
"$PYTHON" "$KIT/tests/test_strong_arm_export.py" || fail "Strong Arm source coordination checks failed"
"$PYTHON" "$KIT/tests/test_c_archer_program.py" || fail "C archer source program checks failed"
"$PYTHON" "$KIT/tests/test_world_c_actor_export.py" || fail "source C actor formation, raster and reproducibility checks failed"
"$PYTHON" "$KIT/tests/test_area_a_actor_export.py" || fail "source A actor catalogue, raster, drops and reproducibility checks failed"
"$PYTHON" "$KIT/tests/test_later_enemy_export.py" || fail "later enemy catalogue, source animation extents, art and reproducibility checks failed"
"$PYTHON" "$KIT/tests/test_battle_sleep_lifecycle.py" || fail "sleep acquisition, source reset and cure checks failed"
"$PYTHON" "$KIT/tests/test_battle_status_art.py" || fail "party status symbol source, pixels and body attachment checks failed"
"$PYTHON" "$KIT/tests/test_battle_item_actor_art.py" || fail "item actor clips, timing and independent raster checks failed"
"$PYTHON" "$KIT/tests/test_enemy_magic_export.py" || fail "Kobold magic source, graphic clocks and resistance export checks failed"
"$PYTHON" "$KIT/tests/test_physical_rune_export.py" || fail "physical-rune batch programs and independent source checks failed"
"$PYTHON" "$KIT/tests/test_physical_callbacks.py" || fail "physical-rune shared callback source and Q12 references failed"
"$PYTHON" "$KIT/tests/test_physical_controller.py" || fail "physical-rune source controller clocks and mailbox join failed"
"$PYTHON" "$TOOLS/export_physical_runes.py" --out "$OUT_PHYSICAL" || fail "physical-rune candidate export failed"
"$PYTHON" "$KIT/tests/test_battle_trial_export.py" || fail "battle trial export tests failed"
"$PYTHON" "$KIT/tests/test_demo_batch_export.py" || fail "demo batch export tests failed"
"$PYTHON" "$KIT/tests/test_journey_export.py" || fail "connected episode export tests failed"
"$PYTHON" "$KIT/tests/test_battle_range.py" || fail "battle weapon-range tests failed"
# Three state structures read out of the instruction stream: the shop object's
# 12-state page driver over the table at 0x800C0F24 (bounded at 11, so
# 0x800C0F54 opens the NEXT table); VA9's two independent byte-stream
# dispatchers 0x80013850 and 0x80012EA4 with separate contexts [0x800340A4] and
# [0x8003409C]; and gs+0x30 (16-bit area index from the table at 0x80171C2C),
# gs+0x34 (recruit tier, 108 flags at gs+0x1AF4, thresholds 25/45/90) and the
# negative on gs+0x70.  The mode writer indexes 0x8016F3AF, not 0x8017F3AF --
# the low half of `addiu $at,$at,-0xC51` is sign-extended.
"$PYTHON" "$KIT/tests/test_q_structure.py" | tail -1 || fail "q_structure tests failed"
# VC61.BIN: the one unexplained file -- characterised as a data module stored
# pre-relocated for base 0x80080000 (== VC6's end), not code, not audio.
"$PYTHON" "$KIT/tests/test_vc61_module.py" | tail -1 || fail "vc61 module tests failed"
# The overlay population: 344 DATA/**.BIN files, derived three ways (the ISO
# listing and the byte-identical master file tables at SLUS 0x8004500C and MAIN
# 0x80163D64), every one Form 1; 133 whole-file LZSS pages plus 886
# pointer-addressed pages = 1,019 x 16,384 B; 1,345 [u16 a][u16 b][u32 magic
# 0x8101..0x8107] section records in 177 overlays (99 outside DATA/04_PLAY); and
# 10 files no engine table claims. Replaces the registry's "~102 data overlays",
# which is a residue of an inventory class column that disagrees with the jr $ra
# test on 82 of the 344 files.
"$PYTHON" "$KIT/tests/test_data_overlays.py" | tail -1 || fail "overlay population tests failed"
# The 04_PLAY sprite DESTINATION traced to the quad emitter: the rect's
# bottom-right corner at the projected position, at instruction level.
"$PYTHON" "$KIT/tests/test_sprite_dest_trace.py" | tail -1 || fail "sprite destination tests failed"
"$PYTHON" "$KIT/tests/test_vram_residency.py" | tail -1 || fail "vram residency tests failed"
"$PYTHON" "$KIT/tests/test_dot8_is_audio.py" | tail -1 || fail "dot8-is-audio tests failed"
"$PYTHON" "$KIT/tests/test_dot8_audio.py" || fail "static dot8 SPU stream tests failed"
"$PYTHON" "$KIT/tests/test_engine_trig.py" | tail -1 || fail "engine trig tests failed"
"$PYTHON" "$KIT/tests/test_psx_exe_bases.py" | tail -1 || fail "psx exe base tests failed"
# The memory-card save block and the dialogue control codes. Card: f @0x800CA2BC
# is a frame-counter delta (not a hash), and the 0x284 header's constant content
# (SC, the Shift-JIS title, the icon palette/plane) is built from literals at
# 0x801713B0/0x80171418/0x801713F4.  Text: 0x80/0x81 occur 0 times in all 10,173
# strings, 0xFF only as a 0x05 pause operand, and all 253 recovered tables are
# index-contiguous 0..max with no pointer/address mismatch.
"$PYTHON" "$KIT/tests/test_memcard_text_tail.py" || fail "memcard/text tail tests failed"
# The event/area script VM: the 82-entry dispatch table @0x80171718, the
# per-opcode effect table, and the 30 EVIDENCE claim records (488 machine
# checks). The handler addresses are re-derived from the image, every declared
# global read/write/call of every opcode is checked against the disassembly, and
# every claim backing a closed opcode (struct field, consumer routine, constant
# store, raw instruction word) is re-derived from the image, so a wrong claim in
# the effect data fails the build.
step "Step 1s: event-VM opcode dispatch and effect semantics"
"$PYTHON" "$KIT/tools/event_vm_semantics.py" --verify | tail -1 || fail "event vm semantics claims do not re-derive"
"$PYTHON" "$KIT/tests/test_event_vm_semantics.py" | tail -1 || fail "event vm semantics tests failed"
"$PYTHON" "$KIT/tests/test_event_operand_lengths.py" | tail -1 || fail "event operand boundary tests failed"
"$PYTHON" "$KIT/tests/test_script_gap_context.py" | tail -1 || fail "script gap source-context tests failed"
"$PYTHON" "$KIT/tests/test_event_script_reachability.py" | tail -1 || fail "script reachability tests failed"
"$PYTHON" "$KIT/tests/test_script_loader_sources.py" | tail -1 || fail "script loader-source census tests failed"
"$PYTHON" "$KIT/tests/test_script_callback_cursors.py" | tail -1 || fail "script callback cursor tests failed"
"$PYTHON" "$KIT/tests/test_script_immediate_callbacks.py" | tail -1 || fail "immediate script callback tests failed"

# ---------------- Step 1i: validate the tracked scanner record set ----------------
# gs_recs.json is a TRACKED artifact, so the build validates it rather than
# trusting it: no recorded game-state access may have a clobbering load (or a
# call-clobbered volatile register) as its base. Regenerating it is a separate
# deliberate act (`kit/tools/gs_scan.py`), not part of the build.
step "Step 1i: scanner record invariants (tools/audit_gs_records.py)"
# Both record sets are TRACKED artifacts, so the build validates them rather
# than trusting them: no recorded access may have a clobbering, call-clobbered
# or reloaded base. Regenerating them is a deliberate act (`gs_scan.py`,
# `scan_structptr.py`), not part of the build. The tool detects the format.
"$PYTHON" "$TOOLS/audit_gs_records.py" "$KIT/work/gs_recs.json" \
    || fail "gs_recs.json contains stale records (see the breakdown above)"
"$PYTHON" "$TOOLS/audit_gs_records.py" "$KIT/work/structptr_recs.json" \
    || fail "structptr_recs.json contains stale records (see the breakdown above)"

# ---------------- Step 2: sprite dump (fresh output dir) ----------------
step "Step 2: sprite dump -> $OUT_SPRITES"
safe_wipe "$OUT_SPRITES" "frames.json" "manifest.json" "*.png"
"$PYTHON" "$TOOLS/dump_sprites.py" --out "$OUT_SPRITES" "$SRC_04PLAY"/*.BIN \
    || fail "dump_sprites.py failed"
n_dirs="$(find "$OUT_SPRITES" -mindepth 1 -maxdepth 1 -type d | wc -l)"
n_frames_json="$(find "$OUT_SPRITES" -name frames.json | wc -l)"
n_png="$(find "$OUT_SPRITES" -name '*.png' | wc -l)"
echo "dirs=$n_dirs frames.json=$n_frames_json pngs=$n_png"
[ "$n_dirs" -eq 78 ] || fail "expected 78 file dirs, got $n_dirs"
[ "$n_frames_json" -eq 78 ] || fail "expected 78 frames.json, got $n_frames_json"
[ "$n_png" -eq 1884 ] || fail "expected 1884 piece PNGs, got $n_png"

# ---------------- Step 3: contact sheets (fresh output dir) ----------------
step "Step 3: contact sheets -> $OUT_CONTACTS"
safe_wipe "$OUT_CONTACTS" "*.png"
"$PYTHON" "$TOOLS/make_contacts.py" --sprites "$OUT_SPRITES" \
    --names "$NAMES_JSON" --out "$OUT_CONTACTS" \
    || fail "make_contacts.py failed"
n_contacts="$(find "$OUT_CONTACTS" -name '*.png' | wc -l)"
echo "contact sheets=$n_contacts"
[ "$n_contacts" -eq 78 ] || fail "expected 78 contact sheets, got $n_contacts"

# ---------------- Step 4: area CLUT registry ----------------
step "Step 4: area CLUT registry -> $OUT_ATLAS/area_cluts.json"
safe_wipe "$OUT_ATLAS" "area_cluts.json" "*.png"
"$PYTHON" "$TOOLS/build_area_cluts.py" --data "$SRC_DATA" --lba "$LBA_JSON" \
    --out "$OUT_ATLAS" || fail "build_area_cluts.py failed"
n_cluts="$("$PYTHON" -c "import json; print(json.load(open('$OUT_ATLAS/area_cluts.json'))['count'])")"
echo "cluts=$n_cluts"
[ "$n_cluts" -eq 26 ] || fail "expected 26 CLUTs, got $n_cluts"

# ---------------- Step 4c: fresh candidate SCENES (isolated output) --------
# Full scene composition (both maps + scenery + NPCs) is generated fresh on every
# build into $OUT_SCENE. It deliberately does NOT write kit/work/area_tiles (the
# reviewed tree) or kit/work/assets_zig (the staging tree): those are user-gated.
# Step 4b still inventories the existing reviewed tree; this step produces new
# candidates that a human reviews before anything is promoted.
step "Step 4c: candidate area scenes -> $OUT_SCENE"
rm -rf "$OUT_SCENE"; mkdir -p "$OUT_SCENE"
"$PYTHON" "$TOOLS/fix_palettes.py" 02B --scene --outdir "$OUT_SCENE" \
    --log "$OUT_SCENE/scene.log" || fail "candidate scene generation failed"
n_scene="$(find "$OUT_SCENE" -name '*.png' | wc -l | tr -d ' ')"
echo "candidate scene PNGs: $n_scene"
[ "$n_scene" -gt 0 ] || fail "candidate scene generation wrote no PNGs"

# ---------------- Step 4b: area render status manifest ----------------
# The area room renders under kit/work/area_tiles had no status record at all
# until 2026-10-04. This inventories the tree, merges any per-room sidecars the
# producers wrote, and INTEGRITY-validates the result: a missing render, a hash
# mismatch, a conflicting room status or a dangling reference fails the build.
#
# Unattributed and stale outputs are REPORTED, not fatal: the tree predates the
# sidecars, so most of it cannot be attributed to a run, and failing on that
# would make the gate unusable. Use `--strict` deliberately to demand a fully
# attributed tree. The point of this step is that the gap is now visible on
# every build instead of being invisible.
AREA_TILES="$KIT/work/area_tiles"
AREA_MAN="$KIT/work/build/area_render_manifest.json"
if [ -d "$AREA_TILES" ]; then
    step "Step 4b: area render status manifest"
    mkdir -p "$(dirname "$AREA_MAN")"
    "$PYTHON" "$TOOLS/area_render_manifest.py" build --tree "$AREA_TILES" \
        --out "$AREA_MAN" || fail "area_render_manifest.py build failed"
    "$PYTHON" "$TOOLS/area_render_manifest.py" validate --manifest "$AREA_MAN" \
        || fail "area render manifest failed integrity validation"
else
    step "Step 4b: area render status manifest (SKIPPED: no $AREA_TILES)"
fi

# ---------------- Step 5: package export + manifest validation ----------------
# The exporter reads the bootstrapped sources (SUIKODEN_BINOV) and the curated
# tree read-only (SUIKODEN_CURATED); it writes only under OUT_PKG. A run that
# records an error exits non-zero, so a failed export cannot mint a package.
step "Step 5: package export -> $OUT_PKG"
rm -rf "$OUT_PKG"
SUIKODEN_BINOV="$SRC_ROOT" SUIKODEN_CURATED="$CURATED" \
    "$PYTHON" "$TOOLS/export_assets.py" --out "$OUT_PKG" \
    || fail "export_assets.py failed (see manifest.failed.json under $OUT_PKG)"
[ -f "$OUT_PKG/manifest.json" ] || fail "exporter wrote no manifest.json"
[ ! -f "$OUT_PKG/manifest.failed.json" ] || fail "exporter wrote manifest.failed.json"
step "Step 5b: exporter CLI-contract tests"
"$PYTHON" "$KIT/tests/test_export_manifest.py" >/dev/null \
    || fail "export manifest tests failed"
echo "ok   test_export_manifest.py"

# ---------------- Final verification ----------------
step "Final verification"
"$PYTHON" - "$OUT_SPRITES" "$OUT_CONTACTS" "$OUT_ATLAS" "$OUT_PKG" <<'EOF' || fail "final verification failed"
import json, sys, glob, os
spr, con, atl, pkg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
m = json.load(open(os.path.join(spr, "manifest.json")))
assert m["summary"] == {"files": 78, "ok": 78, "errors": 0, "frames": 1884}, m["summary"]
assert len(glob.glob(os.path.join(spr, "*", "frames.json"))) == 78
assert len(glob.glob(os.path.join(con, "*.png"))) == 78
cl = json.load(open(os.path.join(atl, "area_cluts.json")))
assert cl["count"] == 26 and len(cl["entries"]) == 26, cl["count"]
assert cl["distinct_cluts"] == 1
assert len(glob.glob(os.path.join(atl, "cluts", "*.png"))) == 26
print("manifest:", m["summary"])
print("contacts: 78 pngs")
print("area_cluts: 26 entries, 1 distinct pattern, 26 swatches")
# Package: the manifest must describe the files that are actually there.
pm = json.load(open(os.path.join(pkg, "manifest.json")))
assert not pm.get("errors"), pm.get("errors")
v = pm.get("validation") or {}
assert v.get("ok"), "manifest validation failed: %s" % (v.get("problems"),)
missing = []
for a in pm.get("assets", []):
    for rel in a.get("files", []) or []:
        p = os.path.join(pkg, rel)
        if not os.path.exists(p):
            missing.append(rel)
assert not missing, "manifest references missing files: %s" % missing[:5]
print("package: %d assets, %d omissions, 0 errors, no dangling references"
      % (len(pm.get("assets", [])), len(pm.get("omissions", []) or [])))
EOF

echo
echo "REBUILD OK: all steps green, all counts verified."
