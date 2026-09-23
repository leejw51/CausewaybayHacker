// The type says there is a screen; at runtime the list is empty.
interface Screen {
  id: number;
}
const screens: Screen[] = [];
console.log(screens[0].id);
