//! Source-backed 8-entry sprite/text upload block for event opcode 0x06.
//!
//! MAIN.EXE `sprite_upload_block_load` @0x8013C238 reads a count byte followed
//! by three bytes per live slot (type, parameter, enable), fills the remaining
//! slots with type 0xFF / enable 0, and sets the shared 4-frame upload countdown
//! at 0x801716B8. The block is consumed by the sprite batch updater; this model
//! owns only the source load/fill/countdown contract.
const std = @import("std");

pub const slots = 8;
pub const initial_countdown: u8 = 4;
pub const empty_type: u8 = 0xFF;

pub const Entry = struct {
    kind: u8 = empty_type,
    parameter: u8 = 0,
    enable: u8 = 0,
};

pub const Block = struct {
    entries: [slots]Entry = @splat(.{}),
    countdown: u8 = initial_countdown,

    pub fn load(bytes: []const u8) !Block {
        if (bytes.len == 0) return error.MissingSpriteUploadCount;
        const count = bytes[0];
        if (count > slots) return error.TooManySpriteUploads;
        const expected = 1 + 3 * @as(usize, count);
        if (bytes.len != expected) return error.InvalidSpriteUploadLength;
        var block: Block = .{};
        for (0..count) |index| {
            const base = 1 + 3 * index;
            block.entries[index] = .{
                .kind = bytes[base],
                .parameter = bytes[base + 1],
                .enable = bytes[base + 2],
            };
        }
        return block;
    }

    pub fn tick(self: *Block) bool {
        if (self.countdown == 0) return false;
        self.countdown -= 1;
        return true;
    }
};
