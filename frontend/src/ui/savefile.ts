/**
 * Put files where the person is: on anything touched — a phone, and an iPad
 * just as much — into the share sheet (iPadOS has no downloads folder anybody
 * looks in); anywhere else, into the downloads folder. Says which it did,
 * because the two are different sentences on screen.
 *
 * Both need the browser's user activation, and the caller has to have kept
 * it: the activation a tap grants lasts about five seconds, and a finger's
 * comes from its `pointerup`, which is where the scene fires these buttons.
 */
export interface SavedFile {
  bytes: Uint8Array;
  name: string;
  type: string;
}

export async function saveFiles(
  files: readonly SavedFile[],
  touch: boolean,
): Promise<"shared" | "saved"> {
  const blobs = files.map((f) => new File([f.bytes as BlobPart], f.name, { type: f.type }));
  if (touch && typeof navigator.share === "function") {
    try {
      if (navigator.canShare?.({ files: blobs })) {
        await navigator.share({ files: blobs });
        return "shared";
      }
    } catch (e) {
      // A dismissed sheet is a choice, not a failure; anything else falls
      // through to the download, which works everywhere.
      if ((e as { name?: string }).name === "AbortError") return "shared";
    }
  }
  for (const file of blobs) {
    const url = URL.createObjectURL(file);
    const a = document.createElement("a");
    a.href = url;
    a.download = file.name;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
  return "saved";
}
