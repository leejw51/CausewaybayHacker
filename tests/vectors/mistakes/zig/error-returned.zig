// An error `main` handed back, and nobody caught.
const std = @import("std");
pub fn main() !void {
    const n = try std.fmt.parseInt(i64, "x1", 10);
    std.debug.print("{d}\n", .{n});
}
