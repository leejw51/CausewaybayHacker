// E0596 — `push` wants `&mut self` and the binding is not `mut`.
fn main() {
    let v = vec![1, 2, 3];
    v.push(4);
    println!("{:?}", v);
}
