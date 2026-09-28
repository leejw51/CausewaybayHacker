// A local that is declared and never read: Zig refuses it outright.
pub fn main() void {
    var count: i32 = 0;
}
