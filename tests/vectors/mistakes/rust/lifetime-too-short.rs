// E0597 — the borrowed value does not live long enough.
fn main() {
    let outer;
    {
        let inner = String::from("causewaybay");
        outer = &inner;
    }
    println!("{}", outer);
}
