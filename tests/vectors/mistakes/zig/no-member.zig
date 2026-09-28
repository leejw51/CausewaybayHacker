// A field the struct does not have.
const std = @import("std");
const Booth = struct { lane: i32 };
pub fn main() void {
    const b = Booth{ .lane = 3 };
    std.debug.print("{d}\n", .{b.lanes});
}
