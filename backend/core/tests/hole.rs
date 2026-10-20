//! The program a picked quest shows (SPEC §0): its solution with the right
//! choice cut out and `____` where it stood.

use cwbhacker_core::content::{hole_program, HOLE};

const SOLUTION: &str = "func main() {\n\tn := read()\n\tif n > 0 {\n\t\tfmt.Println(n)\n\t}\n}\n";

#[test]
fn one_line_is_cut_at_its_own_indent() {
    let got = hole_program(SOLUTION, "n := read()").unwrap();
    assert_eq!(got, format!("func main() {{\n\t{HOLE}\n\tif n > 0 {{\n\t\tfmt.Println(n)\n\t}}\n}}\n"));
}

#[test]
fn several_lines_written_at_the_margin_find_the_indented_run() {
    let got = hole_program(SOLUTION, "\nif n > 0 {\n\tfmt.Println(n)\n}\n").unwrap();
    assert_eq!(got, format!("func main() {{\n\tn := read()\n\t{HOLE}\n}}\n"));
}

#[test]
fn a_choice_that_is_not_there_or_is_there_twice_has_no_program() {
    assert!(hole_program(SOLUTION, "n := read2()").is_none());
    assert!(hole_program("x()\nx()\n", "x()").is_none());
    assert!(hole_program(SOLUTION, "   ").is_none());
}
