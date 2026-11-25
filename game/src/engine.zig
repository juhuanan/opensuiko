//! One game engine facade. The entry point imports this, not the save/runtime
//! internals.
const journey = @import("journey");

pub const State = journey.State;
pub const opening_events = journey.opening_events;
pub const restoreSlotWithSource = journey.restoreSlotWithSource;
pub const saveSlot = journey.saveSlot;
pub const summaries = journey.summaries;
