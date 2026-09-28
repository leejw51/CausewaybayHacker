// An axle counter that is a u8, on the two-hundred-and-fifty-sixth axle.
const std = @import("std");
pub fn main() void {
    var axles: u8 = 250;
    var i: u8 = 0;
    while (i < 10) : (i += 1) axles += 1;
    std.debug.print("{d}\n", .{axles});
}
