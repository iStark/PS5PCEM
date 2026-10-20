// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stop capturing replay dependencies when consecutive draws never reuse
//! them. Periodic paired probes detect when the workload becomes reusable.
//! Declining capture only selects full resource preparation for that draw.
pub const Admission = struct {
    remaining: u8 = 32,
    cooldown: u8 = 0,

    pub fn wantsCapture(self: *const Admission) bool {
        return self.cooldown == 0 and self.remaining != 0;
    }

    pub fn miss(self: *Admission) bool {
        if (self.cooldown != 0) {
            self.cooldown -= 1;
            return false;
        }
        if (self.remaining != 0) {
            self.remaining -= 1;
            return true;
        }
        self.cooldown = 127;
        self.remaining = 2;
        return false;
    }

    pub fn hit(self: *Admission) void {
        self.* = .{};
    }
};

test "streaming misses bound capture work and retain paired recovery probes" {
    const std = @import("std");
    var admission = Admission{};
    for (0..32) |_| {
        try std.testing.expect(admission.wantsCapture());
        try std.testing.expect(admission.miss());
    }
    for (0..5) |_| {
        for (0..128) |_| {
            try std.testing.expect(!admission.wantsCapture());
            try std.testing.expect(!admission.miss());
        }
        try std.testing.expect(admission.wantsCapture());
        try std.testing.expect(admission.miss());
        try std.testing.expect(admission.miss());
    }
    // A successful replay restores normal admission immediately.
    admission.hit();
    for (0..32) |_| try std.testing.expect(admission.miss());
    try std.testing.expect(!admission.miss());
    admission.hit();
    try std.testing.expect(admission.miss());
}
