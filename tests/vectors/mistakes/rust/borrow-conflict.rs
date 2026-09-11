// E0499 — two mutable borrows of the same value, both still live.
fn main() {
    let mut v = vec![1, 2, 3];
    let a = &mut v;
    let b = &mut v;
    a.push(4);
    b.push(5);
}
