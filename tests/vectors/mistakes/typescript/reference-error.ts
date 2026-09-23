// Called before the const it reads is initialised: tsc cannot see across the call.
function greet(): string {
  return greeting;
}
console.log(greet());
const greeting = "hello";
