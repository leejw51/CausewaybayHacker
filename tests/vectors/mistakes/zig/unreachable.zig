// A branch the lane model said could not happen.
const std = @import("std");
pub fn main() void {
    var lane: i32 = 0;
    lane += 3;
    if (lane == 3) unreachable;
    std.debug.print("{d}\n", .{lane});
}
