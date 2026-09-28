// A fare typed as a number, given the text of one.
const std = @import("std");
pub fn main() void {
    const fare: i32 = "twelve";
    std.debug.print("{d}\n", .{fare});
}
