// No base case.
function depth(n: number): number {
  return depth(n + 1) + 1;
}
console.log(depth(0));
