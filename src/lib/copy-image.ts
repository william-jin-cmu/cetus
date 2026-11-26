/** Put an image (by URL — asset://, data:, blob:, http) on the system
 *  clipboard as PNG, the one image type the async clipboard reliably accepts.
 *  Non-PNG sources (JPEG, WebP, SVG, …) are re-encoded through a canvas. */
export async function copyImageToClipboard(url: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const blob = await response.blob();
  const png = blob.type === "image/png" ? blob : await toPng(blob);
  await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
}

async function toPng(blob: Blob): Promise<Blob> {
  // An <img> decodes every format the webview can display, including SVG
  // (createImageBitmap rejects SVG blobs). Object URLs keep the canvas
  // untainted, so toBlob is allowed.
  const objectUrl = URL.createObjectURL(blob);
  try {
    const img = new Image();
    img.src = objectUrl;
    await img.decode();
    const canvas = document.createElement("canvas");
    canvas.width = img.naturalWidth || 1;
    canvas.height = img.naturalHeight || 1;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("canvas unavailable");
    ctx.drawImage(img, 0, 0);
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (b) => (b ? resolve(b) : reject(new Error("encode failed"))),
        "image/png",
      ),
    );
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}
