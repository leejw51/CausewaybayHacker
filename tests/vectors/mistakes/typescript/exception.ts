// Thrown and never caught.
function board(id: number): string {
  if (id < 0) throw new Error("no such board: " + id);
  return "board " + id;
}
console.log(board(-1));
