// A call that can fail, and nobody said `try`.
const std = @import("std");
fn count(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, s, 10);
}
pub fn main() void {
    count("12");
}
