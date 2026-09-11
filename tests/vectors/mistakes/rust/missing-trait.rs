// E0277 — `{:?}` needs Debug and this struct does not have it.
struct Point {
    x: i32,
    y: i32,
}

fn main() {
    let p = Point { x: 1, y: 2 };
    println!("{:?}", p);
}
