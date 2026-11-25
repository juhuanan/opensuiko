//! Logical modes that can own the ordinary input stream.  This is not a
//! platform loop: the running loop tells the recovery layer when it changes
//! mode, and the recovery layer releases the previous mode's input lease.

pub const Mode = enum {
    title,
    opening,
    field,
    menu,
    battle,
    dialogue,
    ending,
};
