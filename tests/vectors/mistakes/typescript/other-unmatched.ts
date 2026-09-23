// Two bodies for one function: a real tsc error that is in no row of the table.
function show(): number {
  return 1;
}
function show(): number {
  return 2;
}
console.log(show());
