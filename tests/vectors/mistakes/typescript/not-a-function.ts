// A feed parsed as `any` promised a method it does not have.
const feed: any = JSON.parse("{\"screens\": 3}");
console.log(feed.screens.map((n: number) => n + 1));
