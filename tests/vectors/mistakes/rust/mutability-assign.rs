// E0594 — assigning through a shared reference.
fn main() {
    let n = 1;
    let r = &n;
    *r = 2;
    println!("{}", n);
}
