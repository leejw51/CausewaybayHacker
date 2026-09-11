// E0106 — a reference in a struct with no lifetime to tie it to.
struct Holder {
    name: &str,
}

fn main() {
    let h = Holder { name: "causewaybay" };
    println!("{}", h.name);
}
