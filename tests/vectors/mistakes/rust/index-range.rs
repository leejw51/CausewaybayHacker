// Compiles and runs. Panics at run time: index out of bounds.
fn main() {
    let v = vec![1, 2, 3];
    let i = "5".parse::<usize>().unwrap();
    println!("{}", v[i]);
}
