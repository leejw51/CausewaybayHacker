// A field the interface never promised.
interface Screen {
  id: number;
}
const s: Screen = { id: 7 };
console.log(s.name);
