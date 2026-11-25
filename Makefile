PYTHON ?= .venv/bin/python
ZIG ?= $(if $(wildcard kit/work/cache/toolchains/zig-*-0.17.0/zig),$(abspath $(firstword $(wildcard kit/work/cache/toolchains/zig-*-0.17.0/zig))),zig)
# Zig build caches. These grow to many GB across builds, so they live on the
# external SSD when it is mounted. Without it we fall back to the in-repo paths
# so builds still work with the drive unplugged. Both stay overridable from the
# environment.
ZIG_SSD_ROOT := $(if $(wildcard /Volumes/SSD),/Volumes/SSD/suikoden-cache,)
ifeq ($(ZIG_SSD_ROOT),)
export ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/kit/work/cache/zig
ZIG_LOCAL_CACHE_DIR ?= $(CURDIR)/game/.zig-cache
else
export ZIG_GLOBAL_CACHE_DIR ?= $(ZIG_SSD_ROOT)/global
ZIG_LOCAL_CACHE_DIR ?= $(ZIG_SSD_ROOT)/cache
endif

.PHONY: help fmt-check prepare build test test-game test-kit test-duels duel-assets test-room room-assets restore-room inn-data shop-data battle-assets test-battles demo-assets test-demos journey-assets test-journey run-journey canonical-assets run-canonical opening-audio check bundle-macos assets
help:
	@echo "make test-duels Export and check every source-backed duel without windows"
	@echo "make fmt-check Check Zig source formatting without changing files"
	@echo "make test-world  Source and headless world/field/battle/session checks; no windows"
	@echo "make test-world-pixels  Export candidates, build and verify CPU pixels; no windows"
	@echo "make test-world-replay  Check supplied-checkpoint native replay without windows"
	@echo "make test-journey  Check the connected forest episode without opening windows"
	@echo "make run-journey   Export and launch the canonical palace package"
	@echo "make check         Export canonical package and run campaign/doc gates without windows"
	@echo "make canonical-assets  Export canonical package artifacts under kit/work/build/canonical"
	@echo "make opening-audio     Export opening audio tracks under kit/work/build/opening/audio"
	@echo "make bundle-macos      Build and bundle the macOS application"
	@echo "make world-art         Export world map tile and layer metadata"
	@echo "make world-data        Export world map travel rules and encounters"
	@echo "make world-battle-art  Export world map battle backdrop art"
	@echo "make test-game         Run Zig game tests only"
	@echo "make test-kit          Run Python kit unit tests only"
	@echo "make prepare   Restore ignored compatibility paths after checkout"
	@echo "make build     Compile the Zig + raylib game (suikoden-journey)"
	@echo "make test-demos Check demo exports and all headless walkthroughs"
	@echo "make test-battles Check trial source data and headless combat"
	@echo "make room-assets  Export first-room candidates (no promotion)"
	@echo "make restore-room Restore the exact package already reviewed by the user"
	@echo "make test-room Check native collision/export gates and play through the candidate"
	@echo "make shop-data Regenerate tracked consumable/shop rules"
	@echo "make inn-data  Regenerate tracked semantic inn rules from the private disc"
	@echo "make test      Run game behavior and kit compatibility gates"
	@echo "make assets    Full private-disc candidate rebuild (no promotion)"

fmt-check:
	$(ZIG) fmt --check game/build.zig game/build.zig.zon game/src game/tests game/assets

prepare:
	$(PYTHON) kit/tools/prepare_layout.py

build:
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" $(ZIG_BUILD_ARGS)

duel-assets: prepare
	$(PYTHON) kit/tools/export_duels.py

test-duels: duel-assets
	$(PYTHON) kit/tests/test_ikki_rules.py
	$(PYTHON) kit/tests/test_ikki_animations.py
	$(PYTHON) kit/tests/test_ikki_clut_trace.py
	$(PYTHON) kit/tests/test_duel_embedded_residency.py
	$(PYTHON) kit/tests/test_duel_presentation.py
	$(PYTHON) kit/tests/test_mode_map.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test --summary all

battle-assets: prepare
	$(PYTHON) kit/tools/regress.py
	$(PYTHON) kit/tools/export_battle_trial.py

test-battles: battle-assets
	$(PYTHON) kit/tests/test_battle_trial_export.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test

journey-assets: prepare
	$(PYTHON) kit/tools/regress.py
	$(PYTHON) kit/tools/export_journey.py
	$(PYTHON) kit/tools/export_world_battle.py --region c-actors

run-journey: canonical-assets
	cd game && ./zig-out/bin/suikoden-journey "$(CURDIR)/kit/work/build/canonical"

opening-audio:
	$(PYTHON) kit/tools/export_opening_audio.py

canonical-assets: opening-audio
	cd game && $(ZIG) build build-journey --cache-dir "$(ZIG_LOCAL_CACHE_DIR)"
	rm -rf kit/work/build/canonical
	mkdir -p kit/work/build/canonical/battle kit/work/build/canonical/party
	cp game/assets/party_session/catalogue.json kit/work/build/canonical/party/
	cp game/assets/magic_actions/ownership_bindings.json kit/work/build/canonical/party/
	mkdir -p kit/work/build/canonical/audio
	cp kit/work/build/opening/audio/audio.json kit/work/build/opening/audio/*.wav kit/work/build/canonical/audio/
	$(PYTHON) kit/tools/export_battle_audio.py --out kit/work/build/canonical/audio
	$(PYTHON) kit/tools/export_defeat_audio.py --out kit/work/build/canonical/audio
	$(PYTHON) kit/tools/export_region_bgm.py kit/work/build/canonical/audio
	cd game && ./zig-out/bin/suikoden-journey --export-opening ../kit/work/build/opening/scene.json ../kit/work/build/canonical
	$(PYTHON) kit/tools/compose_canonical_art.py
	$(PYTHON) kit/tools/export_duel_presentation.py kit/work/build/canonical/duel
	cp kit/work/build/journey/battle/* kit/work/build/canonical/battle/
	$(PYTHON) kit/tools/export_opening_profiles.py
	$(PYTHON) kit/tools/export_opening_field_package.py
	$(PYTHON) kit/tools/room_battle_package.py kit/work/build/canonical \
		game/assets/campaign/opening/field_events.json $(wildcard game/assets/campaign/opening/field_rooms/field_events.json)
	$(PYTHON) kit/tools/check_journey_package.py kit/work/build/canonical --canonical
	if [ -d game/assets/campaign/opening/field_rooms ] || [ -f game/assets/campaign/opening/field_events.json ]; then game/zig-out/bin/suikoden-journey --check-content "$(CURDIR)/kit/work/build/canonical"; fi

run-canonical: run-journey

test-journey: journey-assets
	$(PYTHON) kit/tests/test_preparation.py
	$(PYTHON) kit/tests/test_rune_preparation.py
	$(PYTHON) kit/tests/test_magic_expansion.py
	$(PYTHON) kit/tests/test_poison_rules.py
	$(PYTHON) kit/tests/test_front_promotion.py
	$(PYTHON) kit/tests/test_passive_runes_port.py
	$(PYTHON) kit/tests/test_balloon_departure.py
	$(PYTHON) kit/tests/test_enemy_policies.py
	$(PYTHON) kit/tests/test_spell_effect_sources.py
	$(PYTHON) kit/tests/test_spell_effect_entries.py
	$(PYTHON) kit/tests/test_battle_effect_vertices.py
	$(PYTHON) kit/tests/test_battle_drops.py
	$(PYTHON) kit/tests/test_spell_scene_source.py
	$(PYTHON) kit/tests/test_spell_scene_objects.py
	$(PYTHON) kit/tests/test_spell_scene_columns.py
	$(PYTHON) kit/tests/test_spell_scene_wind.py
	$(PYTHON) kit/tests/test_spell_scene_export.py
	$(PYTHON) kit/tests/test_battle_audio.py
	$(PYTHON) kit/tests/test_guardian_rule.py
	$(PYTHON) kit/tests/test_spell_effect_sweep.py
	$(PYTHON) kit/tests/test_counter_capabilities.py
	$(PYTHON) kit/tests/test_parry_capabilities.py
	$(PYTHON) kit/tests/test_counter_actor_export.py
	$(PYTHON) kit/tests/test_strong_arm_export.py
	$(PYTHON) kit/tests/test_c_archer_program.py
	$(PYTHON) kit/tests/test_world_c_actor_export.py
	$(PYTHON) kit/tests/test_battle_sleep_lifecycle.py
	$(PYTHON) kit/tests/test_battle_status_art.py
	$(PYTHON) kit/tests/test_battle_item_actor_art.py
	$(PYTHON) kit/tests/test_enemy_magic_export.py
	$(PYTHON) kit/tests/test_physical_runes_port.py
	$(PYTHON) kit/tests/test_storage_port.py
	$(PYTHON) kit/tests/test_appraisal_port.py
	$(PYTHON) kit/tests/test_journey_battle.py
	$(PYTHON) kit/tests/test_journey_export.py
	$(PYTHON) kit/tests/test_enemy_rewards.py
	$(PYTHON) kit/tests/test_talisman_unite.py
	$(PYTHON) kit/tests/test_first_room_export.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test

demo-assets: prepare
	$(PYTHON) kit/tools/regress.py
	$(PYTHON) kit/tools/export_demo_batch.py

test-demos: demo-assets
	$(PYTHON) kit/tests/test_demo_batch_export.py
	$(PYTHON) kit/tests/test_character_record_fields.py
	$(PYTHON) kit/tests/test_battle_range.py
	$(PYTHON) kit/tests/test_battle_exit.py
	$(PYTHON) kit/tests/test_talisman_unite.py
	$(PYTHON) kit/tests/test_battle_trial_export.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test

room-assets: prepare
	$(PYTHON) kit/tools/regress.py
	$(PYTHON) kit/tools/export_first_room.py

restore-room:
	$(PYTHON) kit/tools/export_first_room.py --restore-reviewed

inn-data: prepare
	$(PYTHON) kit/tools/export_inn.py

shop-data: prepare
	$(PYTHON) kit/tools/export_shop.py

test-room: room-assets
	$(PYTHON) kit/tests/test_first_room_export.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test

test: test-game test-kit test-world

.PHONY: check
check: canonical-assets
	git diff --check
	$(PYTHON) kit/tools/generate_item_ledger.py --verify
	$(PYTHON) kit/tests/test_item_ledger_generation.py
	$(PYTHON) -m py_compile kit/tools/check_journey_package.py kit/tools/compose_canonical_art.py kit/tools/export_opening_profiles.py kit/tools/export_opening_field_package.py kit/tools/export_va2_battle.py kit/tests/test_check_journey_package.py kit/tests/test_canonical_tools.py kit/tests/test_campaign_docs.py kit/tests/test_campaign_evidence.py kit/tests/test_opening_field_package.py kit/tests/test_runtime_boundaries.py kit/tests/test_startup_diagnostics.py kit/tools/event_vm_semantics.py kit/tools/event_vm_effects.py kit/tools/event_vm_evidence.py
	$(PYTHON) kit/tests/test_check_journey_package.py
	$(PYTHON) kit/tests/test_canonical_tools.py
	$(PYTHON) kit/tests/test_campaign_docs.py
	$(PYTHON) kit/tests/test_campaign_evidence.py
	$(PYTHON) kit/tests/test_opening_field_package.py
	$(PYTHON) kit/tests/test_battle_camera_sites.py
	$(PYTHON) kit/tests/test_battle_actor_camera_scripts.py
	$(PYTHON) kit/tests/test_battle_spell_names.py
	$(PYTHON) kit/tests/test_spell_effect_sources.py
	$(PYTHON) kit/tests/test_spell_effect_entries.py
	$(PYTHON) kit/tests/test_battle_effect_vertices.py
	$(PYTHON) kit/tests/test_battle_drops.py
	$(PYTHON) kit/tests/test_spell_scene_source.py
	$(PYTHON) kit/tests/test_spell_scene_objects.py
	$(PYTHON) kit/tests/test_spell_scene_columns.py
	$(PYTHON) kit/tests/test_spell_scene_wind.py
	$(PYTHON) kit/tests/test_spell_scene_export.py
	$(PYTHON) kit/tests/test_battle_audio.py
	$(PYTHON) kit/tests/test_guardian_rule.py
	$(PYTHON) kit/tests/test_spell_effect_sweep.py
	$(PYTHON) kit/tests/test_battle_camera_ownership.py
	$(PYTHON) kit/tests/test_battle_camera_setup_table.py
	$(PYTHON) kit/tests/test_battle_camera_site_table.py
	$(PYTHON) kit/tests/test_battle_camera_consumer_scan.py
	$(PYTHON) kit/tests/test_battle_unite_camera.py
	$(PYTHON) kit/tests/test_runtime_boundaries.py kit/tests/test_startup_diagnostics.py kit/tools/event_vm_semantics.py kit/tools/event_vm_effects.py kit/tools/event_vm_evidence.py
	! grep -n '/Users/' kit/tools/check_journey_package.py kit/tools/compose_canonical_art.py kit/tools/export_opening_profiles.py kit/tools/export_opening_field_package.py kit/tools/export_va2_battle.py kit/tests/test_opening_field_package.py
	$(ZIG) fmt --check game/build.zig game/build.zig.zon game/src game/tests game/assets
	cd game && $(ZIG) build test test-world test-settings test-zon-data test-hq-launch test-hq-session test-campaign build-journey --cache-dir "$(ZIG_LOCAL_CACHE_DIR)"
	$(PYTHON) kit/tests/test_startup_diagnostics.py
	$(PYTHON) kit/tools/check_journey_package.py kit/work/build/canonical --canonical

test-game: fmt-check
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test --summary all

test-kit: prepare
	$(PYTHON) kit/tests/test_prepare_layout.py
	$(PYTHON) kit/tests/test_bundle_macos.py
	$(PYTHON) kit/tests/test_campaign_coverage.py
	$(PYTHON) kit/tests/test_maas_recruitment.py
	$(PYTHON) kit/tests/test_canonical_start.py
	$(PYTHON) kit/tests/test_opening_events.py
	$(PYTHON) kit/tests/test_opening_audience.py
	$(PYTHON) kit/tests/test_event_runtime_sources.py
	$(PYTHON) kit/tests/test_scene_population.py
	$(PYTHON) -B kit/tests/test_vb6_room0_population.py
	$(PYTHON) kit/tests/test_field_initializers.py
	$(PYTHON) kit/tests/test_field_party_queue.py
	$(PYTHON) kit/tests/test_field_dialogue.py
	$(PYTHON) -B kit/tests/test_field_actor_resources.py
	$(PYTHON) -B kit/tests/test_field_ordinary_track.py
	$(PYTHON) -B kit/tests/test_field_overlap.py
	$(PYTHON) -B kit/tests/test_field_scene_contexts.py
	$(PYTHON) -B kit/tests/test_vaa_field_dialogue.py
	$(PYTHON) kit/tests/test_opening_audio.py
	$(PYTHON) kit/tools/check_port_plan.py
	$(PYTHON) kit/tests/test_check_port_plan.py
	$(PYTHON) kit/tools/regress.py
	$(PYTHON) kit/tests/test_psx_vram.py
	$(PYTHON) kit/tests/test_iso_extract.py
	$(PYTHON) kit/tests/test_ikki_rules.py
	$(PYTHON) kit/tests/test_battle_picker.py
	$(PYTHON) kit/tests/test_port_battle_picker.py
	$(PYTHON) kit/tests/test_inn_export.py
	$(PYTHON) kit/tests/test_village_export.py
	$(PYTHON) kit/tests/test_shop_export.py
	$(PYTHON) kit/tests/test_consumables.py
	$(PYTHON) kit/tests/test_battle_items.py
	$(PYTHON) kit/tests/test_preparation.py
	$(PYTHON) kit/tests/test_rune_preparation.py
	$(PYTHON) kit/tests/test_magic_expansion.py
	$(PYTHON) kit/tests/test_poison_rules.py
	$(PYTHON) kit/tests/test_front_promotion.py
	$(PYTHON) kit/tests/test_passive_runes_port.py
	$(PYTHON) kit/tests/test_balloon_departure.py
	$(PYTHON) kit/tests/test_enemy_policies.py
	$(PYTHON) kit/tests/test_spell_effect_sources.py
	$(PYTHON) kit/tests/test_spell_effect_entries.py
	$(PYTHON) kit/tests/test_battle_effect_vertices.py
	$(PYTHON) kit/tests/test_battle_drops.py
	$(PYTHON) kit/tests/test_spell_scene_source.py
	$(PYTHON) kit/tests/test_spell_scene_objects.py
	$(PYTHON) kit/tests/test_spell_scene_columns.py
	$(PYTHON) kit/tests/test_spell_scene_wind.py
	$(PYTHON) kit/tests/test_spell_scene_export.py
	$(PYTHON) kit/tests/test_battle_audio.py
	$(PYTHON) kit/tests/test_guardian_rule.py
	$(PYTHON) kit/tests/test_spell_effect_sweep.py
	$(PYTHON) kit/tests/test_counter_capabilities.py
	$(PYTHON) kit/tests/test_parry_capabilities.py
	$(PYTHON) kit/tests/test_counter_actor_export.py
	$(PYTHON) kit/tests/test_strong_arm_export.py
	$(PYTHON) kit/tests/test_c_archer_program.py
	$(PYTHON) kit/tests/test_world_c_actor_export.py
	$(PYTHON) kit/tests/test_battle_sleep_lifecycle.py
	$(PYTHON) kit/tests/test_battle_status_art.py
	$(PYTHON) kit/tests/test_battle_item_actor_art.py
	$(PYTHON) kit/tests/test_enemy_magic_export.py
	$(PYTHON) kit/tests/test_physical_runes_port.py
	$(PYTHON) kit/tests/test_storage_port.py
	$(PYTHON) kit/tests/test_appraisal_port.py
	$(PYTHON) kit/tests/test_battle_trial_export.py
	$(PYTHON) kit/tests/test_demo_batch_export.py
	$(PYTHON) kit/tests/test_battle_range.py
	$(PYTHON) kit/tests/test_battle_exit.py
	$(PYTHON) kit/tests/test_battle_bribe.py
	$(PYTHON) kit/tests/test_battle_free_will_static.py
	$(PYTHON) kit/tests/test_world_b_party.py
	$(PYTHON) kit/tests/test_talisman_unite.py
	$(PYTHON) kit/tests/test_journey_battle.py
	$(PYTHON) kit/tests/test_journey_export.py
	$(PYTHON) kit/tests/test_export_manifest.py
	$(PYTHON) kit/tests/test_corpus_links.py
	$(PYTHON) kit/tests/test_registry_reconciliation.py
	$(PYTHON) kit/tools/corpus_state.py --verify
	$(PYTHON) kit/tools/manual_appendix.py --verify
	$(PYTHON) kit/tests/test_manual_links.py --strict

assets: prepare
	PYTHON=$(PYTHON) bash kit/tools/rebuild_assets.sh

bundle-macos: build journey-assets
	$(PYTHON) kit/tools/bundle_macos.py

.PHONY: test-world world-data world-battle-art
world-battle-art: prepare
	$(PYTHON) kit/tools/export_world_battle.py

world-data: prepare
	$(PYTHON) kit/tools/export_world_travel.py
	$(PYTHON) kit/tools/export_scripted_travel.py

test-world: prepare
	$(PYTHON) kit/tools/export_scripted_travel.py --check
	$(PYTHON) kit/tests/test_world_travel.py
	$(PYTHON) kit/tests/test_world_art.py
	$(PYTHON) kit/tests/test_world_battle_art.py
	$(PYTHON) kit/tests/test_world_c_battle_art.py
	cd game && $(ZIG) build --cache-dir "$(ZIG_LOCAL_CACHE_DIR)" test-world --summary all

.PHONY: world-art
world-art: prepare
	$(PYTHON) kit/tools/export_world_art.py --metadata
	$(PYTHON) kit/tools/compose_canonical_art.py --crossing-rooms kit/work/build/review/initial_island

.PHONY: test-world-pixels
test-world-pixels: world-art world-battle-art
	$(MAKE) build
	$(PYTHON) kit/tests/test_world_art.py --check-runtime
	$(PYTHON) kit/tests/test_world_battle_art.py --check-runtime

.PHONY: test-world-replay
test-world-replay:
	$(PYTHON) kit/tests/test_world_replay.py
