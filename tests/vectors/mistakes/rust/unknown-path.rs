// E0433 — a path whose crate or module does not exist.
fn main() {
    let v = nowhere::thing();
    println!("{:?}", v);
}
