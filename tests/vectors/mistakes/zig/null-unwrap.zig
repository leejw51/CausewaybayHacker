// A child that is null, unwrapped with `.?` before anyone looked.
const std = @import("std");
pub fn main() void {
    var left: ?i32 = null;
    left = null;
    std.debug.print("{d}\n", .{left.?});
}
