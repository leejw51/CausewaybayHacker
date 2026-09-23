// The feed is cut off mid-array and nothing catches the parse.
const feed: unknown = JSON.parse("{\"screens\": [1, 2");
console.log(feed);
