// The third lane of a two-lane plaza, at runtime: Debug's bounds check.
const std = @import("std");
pub fn main() void {
    const lanes = [_]i32{ 1, 2 };
    var i: usize = 0;
    i += 2;
    std.debug.print("{d}\n", .{lanes[i]});
}
