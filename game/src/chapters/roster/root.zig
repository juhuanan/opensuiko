//! Public surface: the static data and the campaign-scale ownership
//! ledger.  Consumers should import `root.zig`, not the private files.
pub const catalogue = @import("catalogue.zig");
pub const progression = @import("progression.zig");

pub const Asset = catalogue.Asset;
pub const Loaded = catalogue.Loaded;
pub const open = catalogue.open;
pub const validate = catalogue.validate;
pub const profile = catalogue.profile;
pub const identity = catalogue.identity;
pub const guest = catalogue.guest;
pub const equipment = catalogue.equipment;
pub const rune = catalogue.rune;
pub const blocker = catalogue.blocker;
pub const magicCapacity = catalogue.magicCapacity;

pub const Bindings = progression.Bindings;
pub const Ledger = progression.Ledger;
pub const Progress = progression.Progress;
pub const RetainedItem = progression.RetainedItem;
pub const Role = progression.Role;
pub const Receipt = progression.Receipt;
pub const Kind = progression.Kind;
pub const WeaponPiece = progression.WeaponPiece;
pub const DepartureKind = progression.DepartureKind;
pub const max_members = progression.max_members;
pub const max_active = progression.max_active;
pub const max_state_bytes = progression.max_state_bytes;
pub const state_schema = catalogue.state_schema;
