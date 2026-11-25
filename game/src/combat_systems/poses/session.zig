//! One admitted actor presentation action.
//!
//! A session starts only from a `supported` binding in the family catalogue.
//! Begin selects the binding's first frame and records it as emitted; `advance`
//! walks the source durations and reports a new frame exactly once; a settle
//! state keeps the last pose with zero remaining ticks.  A blocked family, an
//! unknown actor, a missing resource, a stale content identity or a tampered
//! capture is a typed refusal: nothing here fans out to a fallback pose, a zero
//! delay or a silent success.
//!
//! `capture`/`restore` are the restart seam.  The capture carries the actor id,
//! the family, the content sha256, the flattened (animation, pose, duration)
//! frames, the cursor, the elapsed ticks inside the current frame and the number
//! of frames already emitted.  Restoring into a freshly parsed catalogue
//! revalidates the binding and the frame list, refuses a different content
//! identity and resumes without replaying an emitted frame -- so a capture taken
//! after the first draw request but before the action's motion settled, and a
//! capture taken after the final frame settled, both survive a restart.

const std = @import("std");
const family = @import("family.zig");

pub const MAX_FRAMES = 64;

pub const FrameRef = struct {
    animation: u16,
    pose: u16,
    ticks: u16,
};

pub const Emission = struct {
    frame: u16,
    animation: u16,
    pose: u16,
    ticks: u16,
};

pub const Draw = struct {
    frame: u16,
    animation: u16,
    pose: u16,
    anchor_x: u16,
    anchor_y: u16,
    ticks: u16,
    elapsed: u16,
    remaining: u16,
};

pub const Capture = struct {
    actor_id: [32]u8 = @splat(0),
    actor_id_len: u8 = 0,
    family: family.Family = .idle,
    content_sha256: [64]u8 = @splat(0),
    frames: [MAX_FRAMES]FrameRef = @splat(.{ .animation = 0, .pose = 0, .ticks = 0 }),
    frame_count: u16 = 0,
    cursor: u16 = 0,
    elapsed: u16 = 0,
    emitted: u16 = 0,
    settled: bool = false,
};

pub const Session = struct {
    catalogue: *const family.Catalogue,
    actor_index: u32,
    family_id: family.Family,
    content_sha256: [64]u8,
    frames: [MAX_FRAMES]FrameRef = @splat(.{ .animation = 0, .pose = 0, .ticks = 0 }),
    frame_count: u16 = 0,
    cursor: u16 = 0,
    elapsed: u16 = 0,
    emitted: u16 = 0,
    settled: bool = false,

    /// Admit one source family for one actor.  A blocked binding is
    /// `error.UnsupportedFamily`; the caller can read its reason through
    /// `family.Catalogue.bindingFor`.
    pub fn begin(catalogue: *const family.Catalogue, actor_id: []const u8, family_id: family.Family) !Session {
        return beginChecked(catalogue, actor_id, family_id);
    }

    /// Same as `begin`, but the request is pinned to the content identity the
    /// caller admitted.  A different identity is a stale request.
    pub fn beginAt(catalogue: *const family.Catalogue, actor_id: []const u8, family_id: family.Family, expected_content_sha256: []const u8) !Session {
        if (expected_content_sha256.len != 64) return error.InvalidContentIdentity;
        const current = catalogue.contentSha();
        if (current.len != 64 or !std.mem.eql(u8, current, expected_content_sha256)) return error.StaleContent;
        return beginChecked(catalogue, actor_id, family_id);
    }

    fn beginChecked(catalogue: *const family.Catalogue, actor_id: []const u8, family_id: family.Family) !Session {
        if (actor_id.len == 0 or actor_id.len > 32) return error.InvalidActorId;
        const index = catalogue.actorIndex(actor_id) orelse return error.UnknownActor;
        const actor = &catalogue.packet().actors[index];
        const binding_row = actor.binding(family_id) orelse return error.MissingBinding;
        if (binding_row.state == .blocked) return error.UnsupportedFamily;
        var session = Session{
            .catalogue = catalogue,
            .actor_index = @intCast(index),
            .family_id = family_id,
            .content_sha256 = undefined,
        };
        const sha = catalogue.contentSha();
        if (sha.len != 64) return error.InvalidContentIdentity;
        @memcpy(session.content_sha256[0..], sha);
        if (binding_row.static_pose) {
            if (binding_row.animations.len != 0) return error.InvalidBinding;
            session.settled = true;
            return session;
        }
        if (binding_row.animations.len == 0) return error.InvalidBinding;
        for (binding_row.animations) |animation_index| {
            const animation = actor.animation(animation_index) orelse return error.MissingPose;
            if (!animation.resolved) return error.EmptyAnimation;
            if (animation.frames.len == 0) return error.EmptyAnimation;
            for (animation.frames) |frame| {
                if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidDuration;
                const pose = actor.pose(frame.pose) orelse return error.MissingPose;
                if (pose.pieces.len == 0) return error.EmptyPose;
                if (pose.anchor_x > 255 or pose.anchor_y > 255) return error.InvalidAnchor;
                for (pose.pieces) |piece| {
                    if (actor.palette(piece.palette) == null) return error.MissingPalette;
                    if (actor.page(piece.page) == null) return error.MissingPage;
                    if (piece.outside_samples != 0) return error.NonResidentPiece;
                }
                if (session.frame_count == MAX_FRAMES) return error.TooManyFrames;
                session.frames[session.frame_count] = .{
                    .animation = animation.index,
                    .pose = frame.pose,
                    .ticks = frame.ticks,
                };
                session.frame_count += 1;
            }
        }
        if (session.frame_count == 0) return error.EmptyAnimation;
        // The first frame is selected and its draw request emitted by begin.
        session.cursor = 0;
        session.elapsed = 0;
        session.emitted = 1;
        session.settled = false;
        return session;
    }

    pub fn actorId(self: *const Session) []const u8 {
        return self.catalogue.packet().actors[self.actor_index].id;
    }

    pub fn familyId(self: *const Session) family.Family {
        return self.family_id;
    }

    pub fn contentSha(self: *const Session) []const u8 {
        return self.content_sha256[0..];
    }

    pub fn frameCount(self: *const Session) u16 {
        return self.frame_count;
    }

    pub fn emittedFrames(self: *const Session) u16 {
        return self.emitted;
    }

    pub fn isSettled(self: *const Session) bool {
        return self.settled;
    }

    pub fn currentPose(self: *const Session) ?u16 {
        if (self.frame_count == 0) return null;
        const index: usize = if (self.settled) self.frame_count - 1 else self.cursor;
        return self.frames[index].pose;
    }

    /// The draw state of the current frame.  Idempotent: the caller may ask
    /// again after a restart without advancing or re-emitting.
    pub fn draw(self: *const Session) ?Draw {
        if (self.frame_count == 0) return null;
        const index: usize = if (self.settled) self.frame_count - 1 else self.cursor;
        const frame = self.frames[index];
        const pose = self.catalogue.packet().actors[self.actor_index].pose(frame.pose) orelse return null;
        const elapsed: u16 = if (self.settled) frame.ticks else self.elapsed;
        return .{
            .frame = @intCast(index),
            .animation = frame.animation,
            .pose = frame.pose,
            .anchor_x = pose.anchor_x,
            .anchor_y = pose.anchor_y,
            .ticks = frame.ticks,
            .elapsed = elapsed,
            .remaining = frame.ticks - elapsed,
        };
    }

    /// Consume source ticks.  Returns the last frame started by this call (its
    /// draw is now current); a settle consumes no new frame and returns null.
    /// Extra ticks after a settle are discarded and do not re-emit anything.
    pub fn advance(self: *Session, ticks: u16) ?Emission {
        if (self.settled or self.frame_count == 0) return null;
        var remaining: u32 = ticks;
        var last: ?Emission = null;
        while (remaining > 0 and !self.settled) {
            const frame = self.frames[self.cursor];
            const left: u32 = frame.ticks - self.elapsed;
            if (remaining < left) {
                self.elapsed += @intCast(remaining);
                remaining = 0;
            } else {
                remaining -= left;
                self.cursor += 1;
                self.elapsed = 0;
                if (self.cursor >= self.frame_count) {
                    self.settled = true;
                } else {
                    self.emitted += 1;
                    const next = self.frames[self.cursor];
                    last = .{
                        .frame = self.cursor,
                        .animation = next.animation,
                        .pose = next.pose,
                        .ticks = next.ticks,
                    };
                }
            }
        }
        return last;
    }

    pub fn capture(self: *const Session) Capture {
        var result = Capture{};
        const id = self.actorId();
        @memcpy(result.actor_id[0..id.len], id);
        result.actor_id_len = @intCast(id.len);
        result.family = self.family_id;
        result.content_sha256 = self.content_sha256;
        @memcpy(result.frames[0..self.frame_count], self.frames[0..self.frame_count]);
        result.frame_count = self.frame_count;
        result.cursor = self.cursor;
        result.elapsed = self.elapsed;
        result.emitted = self.emitted;
        result.settled = self.settled;
        return result;
    }

    /// Resume a capture against the current content.  The binding and the frame
    /// list are re-derived and compared, so a tampered or substituted capture is
    /// refused instead of being played.
    pub fn restore(catalogue: *const family.Catalogue, cap: Capture) !Session {
        const current = catalogue.contentSha();
        if (current.len != 64 or !std.mem.eql(u8, current, cap.content_sha256[0..])) {
            return error.StaleCapture;
        }
        if (cap.actor_id_len == 0 or cap.actor_id_len > 32) return error.InvalidCapture;
        const id = cap.actor_id[0..cap.actor_id_len];
        var session = beginChecked(catalogue, id, cap.family) catch |err| switch (err) {
            error.UnsupportedFamily => return error.UnsupportedFamily,
            error.UnknownActor => return error.InvalidCapture,
            else => return err,
        };
        if (session.frame_count != cap.frame_count) return error.InvalidCapture;
        for (session.frames[0..session.frame_count], cap.frames[0..cap.frame_count]) |expected, actual| {
            if (!std.meta.eql(expected, actual)) return error.InvalidCapture;
        }
        if (session.frame_count == 0) {
            if (!cap.settled or cap.emitted != 0 or cap.cursor != 0 or cap.elapsed != 0) {
                return error.InvalidCapture;
            }
        } else if (cap.settled) {
            if (cap.cursor != cap.frame_count or cap.emitted != cap.frame_count or cap.elapsed != 0) {
                return error.InvalidCapture;
            }
        } else {
            if (cap.cursor >= cap.frame_count or cap.emitted != cap.cursor + 1) return error.InvalidCapture;
            if (cap.elapsed >= session.frames[cap.cursor].ticks) return error.InvalidCapture;
        }
        session.cursor = cap.cursor;
        session.elapsed = cap.elapsed;
        session.emitted = cap.emitted;
        session.settled = cap.settled;
        return session;
    }
};
