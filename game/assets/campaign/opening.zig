//! Embedded data and digests for canonical opening campaign stages.

pub const canonical_start = struct {
    pub const json = @embedFile("opening/canonical_start.json");
    pub const asset_sha256 = "804625a945030a54c909463df26fd8bc20ee12346490d49b2e0054971d7bedbb";
};

pub const palace_routes = struct {
    pub const manifest_json = @embedFile("opening/palace_routes/vaa_palace_routes.json");
    pub const room0_json = @embedFile("opening/palace_routes/vaa_room0_routes.json");
    pub const room1_json = @embedFile("opening/palace_routes/vaa_room1_routes.json");
    pub const room2_json = @embedFile("opening/palace_routes/vaa_room2_routes.json");
    pub const room10_json = @embedFile("opening/palace_routes/vaa_room10_routes.json");
    pub const manifest_sha256 = "73f48e8cd41af72a1dcc0cc15ba160a1c2c73f1e6fa8db615678d3e40c290fce";
};

pub const destination = struct {
    pub const json = @embedFile("opening/palace_routes/destination.json");
    pub const ground_json = @embedFile("opening/palace_routes/destination_ground.json");
    pub const asset_sha256 = "11d7ba29dd38acd4b768e09fe6bacdc2d0d94c38c062d2503cbe4d14a7238042";
    pub const ground_sha256 = "2ca2f3dc914ab478a9c325039c7e2041c7da732433ef7eef98c997658b1d3658";
};

pub const first_town = struct {
    pub const manifest_json = @embedFile("opening/first_town/va1_town_dialogue.json");
    pub const manifest_sha256 = "9756c3f7a0cc06846e418a3f3f7b4b9211226c91d03e4e652f51a82e91c4190b";
    pub const content_00_json = @embedFile("opening/first_town/va1_room0_dialogue_0.json");
    pub const content_01_json = @embedFile("opening/first_town/va1_room0_dialogue_1.json");
    pub const content_02_json = @embedFile("opening/first_town/va1_room0_dialogue_2.json");
    pub const content_03_json = @embedFile("opening/first_town/va1_room0_dialogue_3.json");
    pub const content_04_json = @embedFile("opening/first_town/va1_room0_dialogue_4.json");
    pub const content_05_json = @embedFile("opening/first_town/va1_room0_dialogue_5.json");
    pub const content_06_json = @embedFile("opening/first_town/va1_room0_dialogue_6.json");
    pub const content_07_json = @embedFile("opening/first_town/va1_room0_dialogue_7.json");
    pub const content_08_json = @embedFile("opening/first_town/va1_room0_dialogue_8.json");
    pub const content_09_json = @embedFile("opening/first_town/va1_room1_dialogue_0.json");
    pub const content_10_json = @embedFile("opening/first_town/va1_room1_dialogue_1.json");
    pub const content_11_json = @embedFile("opening/first_town/va1_room1_dialogue_2.json");
    pub const content_12_json = @embedFile("opening/first_town/va1_room1_dialogue_3.json");
    pub const content_13_json = @embedFile("opening/first_town/va1_room1_dialogue_4.json");
    pub const content_14_json = @embedFile("opening/first_town/va1_room1_dialogue_5.json");
    pub const content_15_json = @embedFile("opening/first_town/va1_room1_dialogue_6.json");
    pub const content_16_json = @embedFile("opening/first_town/va1_room2_dialogue_0.json");
    pub const content_17_json = @embedFile("opening/first_town/va1_room2_dialogue_1.json");
    pub const content_18_json = @embedFile("opening/first_town/va1_room2_dialogue_2.json");
    pub const content_19_json = @embedFile("opening/first_town/va1_room2_dialogue_3.json");
    pub const content_20_json = @embedFile("opening/first_town/va1_room2_dialogue_4.json");
    pub const content_21_json = @embedFile("opening/first_town/va1_room3_dialogue_0.json");
    pub const content_22_json = @embedFile("opening/first_town/va1_room3_dialogue_1.json");
    pub const content_23_json = @embedFile("opening/first_town/va1_room3_dialogue_2.json");
    pub const content_24_json = @embedFile("opening/first_town/va1_room4_dialogue_0.json");
    pub const content_25_json = @embedFile("opening/first_town/va1_room5_dialogue_0.json");
    pub const content_26_json = @embedFile("opening/first_town/va1_room6_dialogue_0.json");
    pub const content_27_json = @embedFile("opening/first_town/va1_room6_dialogue_1.json");
    pub const content_28_json = @embedFile("opening/first_town/va1_room7_dialogue_0.json");
    pub const content_29_json = @embedFile("opening/first_town/va1_room7_dialogue_1.json");
    pub const content_30_json = @embedFile("opening/first_town/va1_room8_dialogue_0.json");
    pub const content_31_json = @embedFile("opening/first_town/va1_room9_dialogue_0.json");
    pub const content_32_json = @embedFile("opening/first_town/va1_room9_dialogue_1.json");
    pub const content_33_json = @embedFile("opening/first_town/va1_room9_dialogue_2.json");
    pub const content_34_json = @embedFile("opening/first_town/va1_room9_dialogue_3.json");
    pub const content_35_json = @embedFile("opening/first_town/va1_room9_dialogue_4.json");
    pub const content_36_json = @embedFile("opening/first_town/va1_room10_dialogue_0.json");
    pub const content_37_json = @embedFile("opening/first_town/va1_room11_dialogue_0.json");
    pub const content_38_json = @embedFile("opening/first_town/va1_room13_dialogue_0.json");
    pub const content_39_json = @embedFile("opening/first_town/va1_room14_dialogue_0.json");
    pub const content_40_json = @embedFile("opening/first_town/va1_room15_dialogue_0.json");
    pub const content_41_json = @embedFile("opening/first_town/va1_room16_dialogue_0.json");
    pub const content_42_json = @embedFile("opening/first_town/va1_room17_dialogue_0.json");
    pub const content_json = [_][]const u8{
        content_00_json,
        content_01_json,
        content_02_json,
        content_03_json,
        content_04_json,
        content_05_json,
        content_06_json,
        content_07_json,
        content_08_json,
        content_09_json,
        content_10_json,
        content_11_json,
        content_12_json,
        content_13_json,
        content_14_json,
        content_15_json,
        content_16_json,
        content_17_json,
        content_18_json,
        content_19_json,
        content_20_json,
        content_21_json,
        content_22_json,
        content_23_json,
        content_24_json,
        content_25_json,
        content_26_json,
        content_27_json,
        content_28_json,
        content_29_json,
        content_30_json,
        content_31_json,
        content_32_json,
        content_33_json,
        content_34_json,
        content_35_json,
        content_36_json,
        content_37_json,
        content_38_json,
        content_39_json,
        content_40_json,
        content_41_json,
        content_42_json,
    };
};

pub const native_slots = struct {
    pub const slots_json = @embedFile("opening/first_town/native_slots.json");
    pub const slots_sha256 = "581f051751065fe61a5512f18fc32c9a8a005638cbe5f4707d1b3472c3e0a6a0";
};

pub const dungeon = struct {
    pub const json = @embedFile("opening/dungeon/vaa_entry.json");
    pub const programs_json = @embedFile("opening/dungeon/programs.json");
    pub const asset_sha256 = "b118cabd8b7f685c9e089caecfe90ca4022612d21216bbc7072bd52c94df453b";
    pub const programs_sha256 = "11eb70cc47ed5a1c2e2dc45ae00be53e4f01b1d2b2cef2a731f9ed66a59b2673";
};

pub const battles = struct {
    pub const json = @embedFile("opening/opening_battles.json");
    pub const asset_sha256 = "56d2e2c5ba882cce23abb5b9883285ec8b1f5d2f1d5a1bc61cc2da7ec2c638e1";
};

pub const party_setup = struct {
    pub const json = @embedFile("opening/party_setup/party_operations.json");
    pub const asset_sha256 = "eefd4fb120b400aea73a9d2056fd37647073e7da175ea2fdccca9c120d487164";
    pub const entry = struct {
        pub const json = @embedFile("opening/party_setup/entry_resources.json");
        pub const asset_sha256 = "7ae802773855273267cc8e2da18780345148fb7ea4a571371f167637788f8c9c";
    };
};

pub const save_policy = struct {
    pub const json = @embedFile("opening/save_policy.json");
    pub const asset_sha256 = "ef65f7dea99b56ef2baefc280476549038b2427b5b4817f32e3c5413a4227cf5";
};

pub const ledger = struct {
    pub const json = @embedFile("opening/ledger.json");
    pub const schema = "suikoden-opening-ledger/1";
    pub const revision = "opening.1";
    pub const ledger_sha256 = "98259dbcdb1c8c90dad1b210dc4f265ed3de99b5b6a1f4fd7f2905f37d4b1098";
};
