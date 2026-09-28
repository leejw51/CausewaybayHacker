// An optional read as if it were the value.
const std = @import("std");
pub fn main() void {
    const child: ?i32 = null;
    const value: i32 = child;
    std.debug.print("{d}\n", .{value});
}
