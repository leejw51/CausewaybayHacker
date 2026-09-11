// E0382 — borrow-after-move. The oldest Rust lesson there is.
fn main() {
    let s = String::from("causewaybay");
    let moved = s;
    println!("{} {}", s, moved);
}
