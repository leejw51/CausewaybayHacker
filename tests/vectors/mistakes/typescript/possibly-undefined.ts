// Map.get can come back empty, and strict says so before the run.
const boards = new Map<string, number>();
const eta = boards.get("tin hau");
console.log(eta.toFixed(1));
