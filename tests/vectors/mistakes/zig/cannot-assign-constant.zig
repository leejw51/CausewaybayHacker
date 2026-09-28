// A toll that was `const` and then paid again.
const std = @import("std");
pub fn main() void {
    const paid: i32 = 1;
    paid = 2;
    std.debug.print("{d}\n", .{paid});
}
