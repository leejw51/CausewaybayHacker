// E0384 is in no row of the §7.1 table. It must be stored as `other` with
// the code kept, never dropped.
fn main() {
    let n = 1;
    n = 2;
    println!("{}", n);
}
