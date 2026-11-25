//! Owned entry point: region-9 boat travel.
//!
//! `data` is the disc-derived catalogue loader; `boat` is the source-fact
//! consumer (board/decline, steering, point dispatch, disembark/cleanup and
//! fresh-process state).  The module is pure and owns no shared file.
pub const data = @import("data.zig");
pub const boat = @import("boat.zig");

pub const schema = data.schema;
pub const Packet = data.Packet;
pub const load = data.load;

pub const Mode = boat.Mode;
pub const WarningStage = boat.WarningStage;
pub const Status = boat.Status;
pub const Facts = boat.Facts;
pub const Probe = boat.Probe;
pub const FieldRequest = boat.FieldRequest;
pub const Cleanup = boat.Cleanup;
pub const Settled = boat.Settled;
pub const Vessel = boat.Vessel;
pub const Session = boat.Session;
pub const Step = boat.Step;
pub const PointProposal = boat.PointProposal;
pub const Choice = boat.Choice;
pub const BoardOutcome = boat.BoardOutcome;
pub const DisembarkResult = boat.DisembarkResult;
pub const Ledger = boat.Ledger;
pub const Checkpoint = boat.Checkpoint;
pub const Fresh = boat.Fresh;

pub const board = boat.board;
pub const probeWater = boat.probeWater;
pub const projectSavedFacing = boat.projectSavedFacing;
pub const restoreSession = boat.restoreSession;
pub const validateAgainst = boat.validateAgainst;
pub const saveFresh = boat.saveFresh;
pub const loadFresh = boat.loadFresh;
