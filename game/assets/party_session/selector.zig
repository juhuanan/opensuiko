//! Generated selector layout; coordinates remain draw-environment-relative.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const window_open_cue: u16 = 1281;
pub const transition_updates: u8 = 8;
pub const main: Rect = .{ .x = -64, .y = -20, .w = 128, .h = 36 };
pub const admit_list: Rect = .{ .x = -148, .y = -94, .w = 64, .h = 132 };
pub const admit_details: Rect = .{ .x = -58, .y = -94, .w = 200, .h = 108 };
pub const admit_confirmation: Rect = .{ .x = -148, .y = 78, .w = 192, .h = 24 };
pub const admit_party: Rect = .{ .x = 62, .y = 31, .w = 80, .h = 72 };
pub const admit_full: Rect = .{ .x = -88, .y = -20, .w = 168, .h = 24 };
pub const eject_list: Rect = .{ .x = -140, .y = -94, .w = 64, .h = 72 };
pub const eject_details: Rect = .{ .x = -58, .y = -94, .w = 200, .h = 108 };
pub const eject_confirmation: Rect = .{ .x = -144, .y = 76, .w = 232, .h = 24 };
pub const origin_x: i32 = 160;
pub const origin_y: i32 = 120;
pub const page_separator_pixels = [12][8]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 1, 2, 0 },
    .{ 0, 0, 0, 0, 0, 1, 3, 0 },
    .{ 0, 0, 0, 0, 1, 3, 0, 0 },
    .{ 0, 0, 0, 0, 1, 2, 0, 0 },
    .{ 0, 0, 0, 1, 3, 0, 0, 0 },
    .{ 0, 0, 1, 3, 0, 0, 0, 0 },
    .{ 0, 0, 1, 2, 0, 0, 0, 0 },
    .{ 0, 1, 2, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};
pub const page_separator_colors = [4][3]u8{
    .{ 0, 0, 0 },
    .{ 255, 255, 255 },
    .{ 0, 0, 0 },
    .{ 82, 82, 82 },
};
pub const DetailField = enum { level, attack, armour, max_hp, power, skill, defense, speed, magic, luck };
pub const DetailNumber = struct { field: DetailField, label: []const u8, column: u8, row: u8, width: u8 };
pub const detail_numbers = [_]DetailNumber{
    .{ .field = .level, .label = "LV", .column = 0, .row = 0, .width = 3 },
    .{ .field = .attack, .label = "ATK", .column = 8, .row = 0, .width = 4 },
    .{ .field = .armour, .label = "ARM", .column = 17, .row = 0, .width = 4 },
    .{ .field = .max_hp, .label = "HP", .column = 0, .row = 1, .width = 4 },
    .{ .field = .power, .label = "PWR", .column = 0, .row = 3, .width = 4 },
    .{ .field = .skill, .label = "SKL", .column = 9, .row = 3, .width = 4 },
    .{ .field = .defense, .label = "DEF", .column = 18, .row = 3, .width = 4 },
    .{ .field = .speed, .label = "SPD", .column = 0, .row = 4, .width = 4 },
    .{ .field = .magic, .label = "MGC", .column = 9, .row = 4, .width = 4 },
    .{ .field = .luck, .label = "LUK", .column = 18, .row = 4, .width = 4 },
};
pub const detail_mp_label = "MP";
pub const detail_range_label = "Arms type";
pub const detail_rune_label = "Rune";
pub const Portrait = struct { id: []const u8, admit_plane_sha256: []const u8, eject_plane_sha256: []const u8, palette_sha256: []const u8 };
pub const portraits = [_]Portrait{
    .{ .id = "hero", .admit_plane_sha256 = "3fbd046080521e630522004363720563797e4d24297c0fe095defdc16d52b4d3", .eject_plane_sha256 = "3fbd046080521e630522004363720563797e4d24297c0fe095defdc16d52b4d3", .palette_sha256 = "fd0a240e356c700125c0eb565186a71f818f153936fcb6b8b63d03c7c67e4624" },
    .{ .id = "gremio", .admit_plane_sha256 = "6c723dd86cb909e3904bf9baa031f77fcc9c4245e29bd5ff4cfa0150f75f4850", .eject_plane_sha256 = "6c723dd86cb909e3904bf9baa031f77fcc9c4245e29bd5ff4cfa0150f75f4850", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "pahn", .admit_plane_sha256 = "83bdbd90632d5728218e0a4277675d3ae0448f32e353999a7c901552bf078e73", .eject_plane_sha256 = "83bdbd90632d5728218e0a4277675d3ae0448f32e353999a7c901552bf078e73", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "cleo", .admit_plane_sha256 = "79d5dd0d477307d8ab407fbe7b8e8d9fa2500ca7ec8b97380fe6e7b7e733f72d", .eject_plane_sha256 = "79d5dd0d477307d8ab407fbe7b8e8d9fa2500ca7ec8b97380fe6e7b7e733f72d", .palette_sha256 = "056bbc79786f81671611f2ead9918bedd87f0f33153d6f19536d0c2d566d029b" },
    .{ .id = "viktor", .admit_plane_sha256 = "8d040e5b3c35a229591d702f2f3b581ea8b71d232f60e5068be13093328b11a6", .eject_plane_sha256 = "8d040e5b3c35a229591d702f2f3b581ea8b71d232f60e5068be13093328b11a6", .palette_sha256 = "fd0a240e356c700125c0eb565186a71f818f153936fcb6b8b63d03c7c67e4624" },
    .{ .id = "camille", .admit_plane_sha256 = "84cf4d8418cef98aaa1f9a53d04f34fb98a1619005f4585dc8c88e23b1de5aa6", .eject_plane_sha256 = "84cf4d8418cef98aaa1f9a53d04f34fb98a1619005f4585dc8c88e23b1de5aa6", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "tai_ho", .admit_plane_sha256 = "3c30b51c23bbfc2a9d5df8d62a3a765d5260328e26ddea7bf7875757a9c8191e", .eject_plane_sha256 = "3c30b51c23bbfc2a9d5df8d62a3a765d5260328e26ddea7bf7875757a9c8191e", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "kuromimi", .admit_plane_sha256 = "d785ecd7a9e2178ad4398b1496d08961ae23a85956bc8c0262d61c3dbd988e19", .eject_plane_sha256 = "d785ecd7a9e2178ad4398b1496d08961ae23a85956bc8c0262d61c3dbd988e19", .palette_sha256 = "056bbc79786f81671611f2ead9918bedd87f0f33153d6f19536d0c2d566d029b" },
    .{ .id = "kirkis", .admit_plane_sha256 = "5583d03200beffc120c2983a3ae12b58d645becb23a40b9a3791cd1045e114ea", .eject_plane_sha256 = "5583d03200beffc120c2983a3ae12b58d645becb23a40b9a3791cd1045e114ea", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "valeria", .admit_plane_sha256 = "6d6bd5254bafe2e36d48799cb8b3501a2af8d699d462678495ce91b42812507f", .eject_plane_sha256 = "6d6bd5254bafe2e36d48799cb8b3501a2af8d699d462678495ce91b42812507f", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "eileen", .admit_plane_sha256 = "be67ed43998f25c2c39ce94a44bf919c6b2d69e8f1f00fb8fecf89cb72395378", .eject_plane_sha256 = "be67ed43998f25c2c39ce94a44bf919c6b2d69e8f1f00fb8fecf89cb72395378", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "lorelai", .admit_plane_sha256 = "8dab52c88de5ad1c46c2e32eb74a47003a4600f6db4673a08ff6e41b11fe3ba2", .eject_plane_sha256 = "8dab52c88de5ad1c46c2e32eb74a47003a4600f6db4673a08ff6e41b11fe3ba2", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "stallion", .admit_plane_sha256 = "aa8729c2dda5f8b600f61041b80878224b02e239e4a214d6dd1a9f14e7bc97f9", .eject_plane_sha256 = "aa8729c2dda5f8b600f61041b80878224b02e239e4a214d6dd1a9f14e7bc97f9", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "yam_koo", .admit_plane_sha256 = "3c535cb7e44edf3efc669605432ff5ac09f7e80e5f1374ae40b0c3c5e7ed229b", .eject_plane_sha256 = "3c535cb7e44edf3efc669605432ff5ac09f7e80e5f1374ae40b0c3c5e7ed229b", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "lepant", .admit_plane_sha256 = "a27cd1bc37bf35fa48043f5057a0b75f8cc6986e6503434e1c71bf353075db01", .eject_plane_sha256 = "a27cd1bc37bf35fa48043f5057a0b75f8cc6986e6503434e1c71bf353075db01", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "krin", .admit_plane_sha256 = "9bdc3a6dab845f0d67681b9f5c4ae6eed163fcea1e1f7c8766b653347d936afb", .eject_plane_sha256 = "9bdc3a6dab845f0d67681b9f5c4ae6eed163fcea1e1f7c8766b653347d936afb", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "juppo", .admit_plane_sha256 = "c15d88504c18fb555e69f40ee29df23627346cac0ded3235635e6258101c8ebd", .eject_plane_sha256 = "c15d88504c18fb555e69f40ee29df23627346cac0ded3235635e6258101c8ebd", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "kimberly", .admit_plane_sha256 = "2e10ac103b0598915466c14a482aef0e6bcff3a1d71baddfa1448e3ad102472a", .eject_plane_sha256 = "2e10ac103b0598915466c14a482aef0e6bcff3a1d71baddfa1448e3ad102472a", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "humphrey", .admit_plane_sha256 = "0f5162c2369ef558a206abad3c223e43675ff630095b43211fe6002e3a1c4897", .eject_plane_sha256 = "0f5162c2369ef558a206abad3c223e43675ff630095b43211fe6002e3a1c4897", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "kreutz", .admit_plane_sha256 = "8d78ef717962663b513dcb7d4d0d4f7e11c48eacf39349cda9854b22d790ac43", .eject_plane_sha256 = "8d78ef717962663b513dcb7d4d0d4f7e11c48eacf39349cda9854b22d790ac43", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "mose", .admit_plane_sha256 = "04cf2ad183f7363f580ef2a013167833c88b32ea714e6d7595e522ae008b92be", .eject_plane_sha256 = "04cf2ad183f7363f580ef2a013167833c88b32ea714e6d7595e522ae008b92be", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "sheena", .admit_plane_sha256 = "0592a2b19216b38af35c331b4fecb46b2a3e4fd01eca2b7851a86df22396df03", .eject_plane_sha256 = "0592a2b19216b38af35c331b4fecb46b2a3e4fd01eca2b7851a86df22396df03", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "hix", .admit_plane_sha256 = "6bf75e3ff67fea5c6e2ae0310ab1be76c92053f9a8c2bc9867b96a19047bf1f1", .eject_plane_sha256 = "6bf75e3ff67fea5c6e2ae0310ab1be76c92053f9a8c2bc9867b96a19047bf1f1", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "kai", .admit_plane_sha256 = "1f3e5c270cf4f2053f7174f2a811518549a1643993cff853f38fbac8297a367a", .eject_plane_sha256 = "1f3e5c270cf4f2053f7174f2a811518549a1643993cff853f38fbac8297a367a", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "sydonia", .admit_plane_sha256 = "7c17488c43d0bb0ff07c11c8521668a7398a27ee62364e202de528728b392f86", .eject_plane_sha256 = "7c17488c43d0bb0ff07c11c8521668a7398a27ee62364e202de528728b392f86", .palette_sha256 = "c27b7ac403490ddc332cfcb86e1baaa6baa2f86dd9a137db92a0d405b7e645f4" },
    .{ .id = "fukien", .admit_plane_sha256 = "37499bd849e6b7e62e7815a137fb41ef2ae5ba76d7c8a3e1975140cf2db92b72", .eject_plane_sha256 = "37499bd849e6b7e62e7815a137fb41ef2ae5ba76d7c8a3e1975140cf2db92b72", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "sylvina", .admit_plane_sha256 = "f8ab76150a3819f3876b4b2b8a648ad2c83105fd3e5151d46e59aa053d3cd0a0", .eject_plane_sha256 = "f8ab76150a3819f3876b4b2b8a648ad2c83105fd3e5151d46e59aa053d3cd0a0", .palette_sha256 = "056bbc79786f81671611f2ead9918bedd87f0f33153d6f19536d0c2d566d029b" },
    .{ .id = "gen", .admit_plane_sha256 = "950b2a07003b48cac193a912fa213f5f6539a40b10b32a84a828c864c51f665f", .eject_plane_sha256 = "950b2a07003b48cac193a912fa213f5f6539a40b10b32a84a828c864c51f665f", .palette_sha256 = "c27b7ac403490ddc332cfcb86e1baaa6baa2f86dd9a137db92a0d405b7e645f4" },
    .{ .id = "meg", .admit_plane_sha256 = "49905f99e745b6cbbe23337f4007bbd693bd81ff0c8ebea6227b4efbd2c9147c", .eject_plane_sha256 = "49905f99e745b6cbbe23337f4007bbd693bd81ff0c8ebea6227b4efbd2c9147c", .palette_sha256 = "056bbc79786f81671611f2ead9918bedd87f0f33153d6f19536d0c2d566d029b" },
    .{ .id = "luc", .admit_plane_sha256 = "7acc4945dac21719b419bbb51aa33fcd4756894cfe963a3834a99f8336aa1874", .eject_plane_sha256 = "7acc4945dac21719b419bbb51aa33fcd4756894cfe963a3834a99f8336aa1874", .palette_sha256 = "dc6fbd18a12153169201d61a3a1356740ce40178ad90430686dc25d4c86cbeda" },
    .{ .id = "liukan", .admit_plane_sha256 = "d41b342665c39fd9369d63c68938bfca52ebb8a6648073293aea7c0a6fbfba47", .eject_plane_sha256 = "d41b342665c39fd9369d63c68938bfca52ebb8a6648073293aea7c0a6fbfba47", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "ronnie", .admit_plane_sha256 = "32afb9b10e1f01bf59a1db76092af81923def9699bc056d438de0e39e926fe63", .eject_plane_sha256 = "32afb9b10e1f01bf59a1db76092af81923def9699bc056d438de0e39e926fe63", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "kage", .admit_plane_sha256 = "ed1bceea010ddede01e447d51be6f7dd8070b1000912eb2bdafcfef1582fce0d", .eject_plane_sha256 = "ed1bceea010ddede01e447d51be6f7dd8070b1000912eb2bdafcfef1582fce0d", .palette_sha256 = "dc6fbd18a12153169201d61a3a1356740ce40178ad90430686dc25d4c86cbeda" },
    .{ .id = "fu_su_lu", .admit_plane_sha256 = "abe190ec8e3c82f034d01f11760fdb932fdde6be6ba90ffa5cd1467e6f79f3ad", .eject_plane_sha256 = "abe190ec8e3c82f034d01f11760fdb932fdde6be6ba90ffa5cd1467e6f79f3ad", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "fuma", .admit_plane_sha256 = "f18b0a9a509d3576e7f047d3079ab9e0c9bf3b72756d1535ba8b043d958c38d1", .eject_plane_sha256 = "f18b0a9a509d3576e7f047d3079ab9e0c9bf3b72756d1535ba8b043d958c38d1", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "mina", .admit_plane_sha256 = "ad916851023273a6a74e249f492df98416ef89d3d20e989071150c2a2a03a8c3", .eject_plane_sha256 = "ad916851023273a6a74e249f492df98416ef89d3d20e989071150c2a2a03a8c3", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "blackman", .admit_plane_sha256 = "e29fbcb57a731e00b6d8ebea9769fd08f1c4c7bb2d57024b484e3635cb260ccd", .eject_plane_sha256 = "e29fbcb57a731e00b6d8ebea9769fd08f1c4c7bb2d57024b484e3635cb260ccd", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "kirke", .admit_plane_sha256 = "6b11e338db336be911ee843d5b3f294fdc3ea620718d000bfd3339a6ca4fefb5", .eject_plane_sha256 = "6b11e338db336be911ee843d5b3f294fdc3ea620718d000bfd3339a6ca4fefb5", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "sarah", .admit_plane_sha256 = "3800d539a4ba2f2b6bb80aab9ba8f29d2e628e5837696dc3f1ceada50495f586", .eject_plane_sha256 = "3800d539a4ba2f2b6bb80aab9ba8f29d2e628e5837696dc3f1ceada50495f586", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "antonio", .admit_plane_sha256 = "8270fbc15d11e65b1e8890a06cc7b9173edb49439cb8b122d71c3df4831ef959", .eject_plane_sha256 = "8270fbc15d11e65b1e8890a06cc7b9173edb49439cb8b122d71c3df4831ef959", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "lester", .admit_plane_sha256 = "aea99ea8ec006c2e8dbf9eda6f533be97335cc0a9fc142975438b16f541b0b63", .eject_plane_sha256 = "aea99ea8ec006c2e8dbf9eda6f533be97335cc0a9fc142975438b16f541b0b63", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "clive", .admit_plane_sha256 = "e280149123e55b4aceb6d4de28d89187744651ecaf7946ecf85e8231d6b58c7e", .eject_plane_sha256 = "e280149123e55b4aceb6d4de28d89187744651ecaf7946ecf85e8231d6b58c7e", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "crowley", .admit_plane_sha256 = "657f6d7717e423f5d72da210c85c0afac47d8b3326725d2cb6a2444aa6a46850", .eject_plane_sha256 = "657f6d7717e423f5d72da210c85c0afac47d8b3326725d2cb6a2444aa6a46850", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "flik", .admit_plane_sha256 = "06630280e544b201eaafd4afba9c26edb11788636804a559ce8f443f9d503cc8", .eject_plane_sha256 = "aabdb9ffada266e80deecbe1030c74da8968177a1ea71876063f58cc67daf0c5", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "kasim", .admit_plane_sha256 = "2eb39b2646e449e8a0a5abb3ef65b41ca2fb1e89d86e6b037d3e11fc4777c947", .eject_plane_sha256 = "2eb39b2646e449e8a0a5abb3ef65b41ca2fb1e89d86e6b037d3e11fc4777c947", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "sonya", .admit_plane_sha256 = "90f85fcbe139a726bda4195c7d56ee04a38329368d38b34264caab1bab6fb01a", .eject_plane_sha256 = "90f85fcbe139a726bda4195c7d56ee04a38329368d38b34264caab1bab6fb01a", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "futch", .admit_plane_sha256 = "814c24fa57a2d546b73199d5642ae920c7ac486deb45e2670e78e0e4b5ec6ef9", .eject_plane_sha256 = "814c24fa57a2d546b73199d5642ae920c7ac486deb45e2670e78e0e4b5ec6ef9", .palette_sha256 = "dc6fbd18a12153169201d61a3a1356740ce40178ad90430686dc25d4c86cbeda" },
    .{ .id = "anji", .admit_plane_sha256 = "65310a12392b186f6c322e8ceed1716503c2215393e727324dc7b09c98016193", .eject_plane_sha256 = "65310a12392b186f6c322e8ceed1716503c2215393e727324dc7b09c98016193", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "alen", .admit_plane_sha256 = "4c727979b1cece42e91c29e3c15b4ea5aa6e01461e2eeb7e505d8966bdf7dd7a", .eject_plane_sha256 = "4c727979b1cece42e91c29e3c15b4ea5aa6e01461e2eeb7e505d8966bdf7dd7a", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "varkas", .admit_plane_sha256 = "2e78853af53770fc1508a92630dd6a78dff12fec7ec0d5693b52bec8f2ba2ce1", .eject_plane_sha256 = "2e78853af53770fc1508a92630dd6a78dff12fec7ec0d5693b52bec8f2ba2ce1", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "kamandol", .admit_plane_sha256 = "821fb168a6199cecf932bd53a573d8b73e2831ce799e59a92f52b0380a51f71b", .eject_plane_sha256 = "821fb168a6199cecf932bd53a573d8b73e2831ce799e59a92f52b0380a51f71b", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "eikei", .admit_plane_sha256 = "f0a1ee893ce753cc7270bdb5a7ebb42b345a0766ef3ef4cde177a74a78ab7266", .eject_plane_sha256 = "f0a1ee893ce753cc7270bdb5a7ebb42b345a0766ef3ef4cde177a74a78ab7266", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "gon", .admit_plane_sha256 = "a3cf561f13e1d55d195af2876613fd25dbdacd182b1f7f8c09b4bfdbeeabd37e", .eject_plane_sha256 = "a3cf561f13e1d55d195af2876613fd25dbdacd182b1f7f8c09b4bfdbeeabd37e", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "griffith", .admit_plane_sha256 = "cba672cdff8540505b2d8894e146aa02fba3c80cf8b4443c72dfa69a1a1d21ce", .eject_plane_sha256 = "cba672cdff8540505b2d8894e146aa02fba3c80cf8b4443c72dfa69a1a1d21ce", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "grenseal", .admit_plane_sha256 = "21042cb9863e2b1ca3cfb830b7e32aecbe52cf2f6ddb18bd3706f39f66bc874f", .eject_plane_sha256 = "21042cb9863e2b1ca3cfb830b7e32aecbe52cf2f6ddb18bd3706f39f66bc874f", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "hellion", .admit_plane_sha256 = "dce1bc619e4162763b22055c729d68c5715c7534c272bc59a6f44286eaa2abea", .eject_plane_sha256 = "dce1bc619e4162763b22055c729d68c5715c7534c272bc59a6f44286eaa2abea", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "kasumi", .admit_plane_sha256 = "7d6065072c23f1eb90fe3ea5ab9e5ebf65b093ee1efecac9c2f7eb120f103838", .eject_plane_sha256 = "7d6065072c23f1eb90fe3ea5ab9e5ebf65b093ee1efecac9c2f7eb120f103838", .palette_sha256 = "68b9c10ea5a8d506cf73f899d651597b88436d57e78cd5579b7270e8c240925f" },
    .{ .id = "kessler", .admit_plane_sha256 = "0e34e011cd01a1990f3be06440b9fe5b5d505ad90d419d2638f9a0f0f0451e94", .eject_plane_sha256 = "0e34e011cd01a1990f3be06440b9fe5b5d505ad90d419d2638f9a0f0f0451e94", .palette_sha256 = "056bbc79786f81671611f2ead9918bedd87f0f33153d6f19536d0c2d566d029b" },
    .{ .id = "kanak", .admit_plane_sha256 = "bd102825c7e563a20f0f76d16aa0620c9687294c3aaa4509e154a7f75b8482a1", .eject_plane_sha256 = "bd102825c7e563a20f0f76d16aa0620c9687294c3aaa4509e154a7f75b8482a1", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "kwanda", .admit_plane_sha256 = "fb46424e0fa511198058e937117c98e517f242e18320ccf9282689f649a4523d", .eject_plane_sha256 = "fb46424e0fa511198058e937117c98e517f242e18320ccf9282689f649a4523d", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "leonardo", .admit_plane_sha256 = "f3f4767007abb30560d236ee2d6c3e327f7e2bfec9bf6f3cd47f28554d337370", .eject_plane_sha256 = "f3f4767007abb30560d236ee2d6c3e327f7e2bfec9bf6f3cd47f28554d337370", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "lotte", .admit_plane_sha256 = "715315f4308796a1da97d22d69df37cb52751bf81f34b6e273f17808592a0ae2", .eject_plane_sha256 = "715315f4308796a1da97d22d69df37cb52751bf81f34b6e273f17808592a0ae2", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "rubi", .admit_plane_sha256 = "b96462fc75326ca58f32643c1a55b79225bfd5ccb756dfc0d09f5581230a429e", .eject_plane_sha256 = "b96462fc75326ca58f32643c1a55b79225bfd5ccb756dfc0d09f5581230a429e", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "maas", .admit_plane_sha256 = "7e8a07241045062e8f42ca0ebafb677fc4f7f543562edd7f5a870876f7a53f10", .eject_plane_sha256 = "7e8a07241045062e8f42ca0ebafb677fc4f7f543562edd7f5a870876f7a53f10", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "mace", .admit_plane_sha256 = "5c4c4ac7ba19dca4761ffbc1154c6a47cd360331119b42682263ca35239d7aed", .eject_plane_sha256 = "5c4c4ac7ba19dca4761ffbc1154c6a47cd360331119b42682263ca35239d7aed", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "milich", .admit_plane_sha256 = "aa94f38b1bc6d5f77e3640ce6c1a95c4efa5184fd9b8c66f86b7ca2afc19a8ff", .eject_plane_sha256 = "aa94f38b1bc6d5f77e3640ce6c1a95c4efa5184fd9b8c66f86b7ca2afc19a8ff", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "meese", .admit_plane_sha256 = "092a816a18297f3dc9e130c8d89de0846f98d74626eb3d28574c9bdde7f201be", .eject_plane_sha256 = "092a816a18297f3dc9e130c8d89de0846f98d74626eb3d28574c9bdde7f201be", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "morgan", .admit_plane_sha256 = "fe8da5608e624354e94fb63465c8e6c6577ea073a3fffc05c37afb44658a6df2", .eject_plane_sha256 = "fe8da5608e624354e94fb63465c8e6c6577ea073a3fffc05c37afb44658a6df2", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "milia", .admit_plane_sha256 = "50f69e821efee1c935b89a974f3e7a638d4d4191e89c9e0569f4aeeebe138a84", .eject_plane_sha256 = "50f69e821efee1c935b89a974f3e7a638d4d4191e89c9e0569f4aeeebe138a84", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "moose", .admit_plane_sha256 = "80996f880232492c2af9120f72646786ffdb84a8daaa2d67e42e46dd463cd8f8", .eject_plane_sha256 = "80996f880232492c2af9120f72646786ffdb84a8daaa2d67e42e46dd463cd8f8", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
    .{ .id = "pesmerga", .admit_plane_sha256 = "d958e1ce26fa63df14223c970819994f43d9c76ad3ca68fd4b62ddf903dfad9e", .eject_plane_sha256 = "d958e1ce26fa63df14223c970819994f43d9c76ad3ca68fd4b62ddf903dfad9e", .palette_sha256 = "350cef28a061f5de8f0f5d5ba42e0ff43ab99e29fff072163a7850ad8166faf3" },
    .{ .id = "quincy", .admit_plane_sha256 = "30e869fdc95253a44e2b464593e66772ce9c2b70dc81e26e4af697ee188787be", .eject_plane_sha256 = "30e869fdc95253a44e2b464593e66772ce9c2b70dc81e26e4af697ee188787be", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "sansuke", .admit_plane_sha256 = "db1844e5ad9c2620849ddddffd8dab72cf8467736e0326945cbe46336ca69a1d", .eject_plane_sha256 = "db1844e5ad9c2620849ddddffd8dab72cf8467736e0326945cbe46336ca69a1d", .palette_sha256 = "437813b2dde59b7dfa59866f4cece24a6f89c9be5c8249c9fe93c79723581f3c" },
    .{ .id = "sergei", .admit_plane_sha256 = "e60f13a8ad951254044747f69bd07423075c042611acbdc152a90c20fdc11565", .eject_plane_sha256 = "e60f13a8ad951254044747f69bd07423075c042611acbdc152a90c20fdc11565", .palette_sha256 = "76fdbf259ceae5b3fc6baf3b93dd6b075f22d6a4b8697d00f1e5ac53bc295327" },
    .{ .id = "tengaar", .admit_plane_sha256 = "00023b0a057e63070fe9172298f7184d7d23a182ba8333d89e3e56f5c1175c64", .eject_plane_sha256 = "00023b0a057e63070fe9172298f7184d7d23a182ba8333d89e3e56f5c1175c64", .palette_sha256 = "68b9c10ea5a8d506cf73f899d651597b88436d57e78cd5579b7270e8c240925f" },
    .{ .id = "warren", .admit_plane_sha256 = "b1452747b4b30c37a9a066a95dde073b4d42350ee72f2979031c73f0574bfe95", .eject_plane_sha256 = "b1452747b4b30c37a9a066a95dde073b4d42350ee72f2979031c73f0574bfe95", .palette_sha256 = "6fd6d3890e4c7866b615edb044c9efac604b9bf2b6e4c82d9d2b3e1edfeb838d" },
};
pub const portrait_rect: Rect = .{ .x = -66, .y = 0, .w = 64, .h = 64 };
pub const choices = "Admit to party\nEject from party\nNo change";
pub const admit_prompt = "Add to the party.\nDo not add to the party.";
pub const eject_prompt = "Remove from the party.\nDo not remove from the party.";
pub const full_prompt = "Party Member is full.";
pub const acknowledge_prompt = "[Press the button]";
