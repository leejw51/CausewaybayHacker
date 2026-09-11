// E0308 — a &str where an i32 was promised.
fn main() {
    let n: i32 = "42";
    println!("{}", n);
}
