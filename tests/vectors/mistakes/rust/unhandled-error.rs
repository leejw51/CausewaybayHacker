// E0277 on a Result — `?` in a `fn main()` that returns `()`.
use std::fs;

fn main() {
    let text = fs::read_to_string("nope.txt")?;
    println!("{}", text);
}
