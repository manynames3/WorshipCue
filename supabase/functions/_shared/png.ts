import { ApiError, boundedBytes, type Json } from "./security.ts";

const signature = [137, 80, 78, 71, 13, 10, 26, 10];
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 255] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

export async function validatePNG(bytes: Uint8Array): Promise<Json> {
  if (bytes.length < 57 || bytes.length > 2097152 || !signature.every((v, i) => bytes[i] === v)) {
    throw new ApiError("INVALID_PREVIEW");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 8, width = 0, height = 0, ended = false, dataEnded = false, chunks = 0;
  const imageData: Uint8Array[] = [];
  while (offset + 12 <= bytes.length) {
    const length = view.getUint32(offset), start = offset + 8, end = start + length;
    if (end + 4 > bytes.length || ++chunks > 1000) throw new ApiError("INVALID_PREVIEW");
    const kind = new TextDecoder().decode(bytes.subarray(offset + 4, start));
    if (!/^[A-Za-z]{4}$/.test(kind) || crc32(bytes.subarray(offset + 4, end)) !== view.getUint32(end)) {
      throw new ApiError("INVALID_PREVIEW");
    }
    if (kind === "IHDR") {
      if (offset !== 8 || length !== 13) throw new ApiError("INVALID_PREVIEW");
      width = view.getUint32(start);
      height = view.getUint32(start + 4);
      if (
        !width || !height || width > 8192 || height > 8192 || width * height > 16777216 ||
        bytes[start + 8] !== 8 || bytes[start + 9] !== 6 || bytes[start + 10] !== 0 || bytes[start + 11] !== 0 ||
        bytes[start + 12] !== 0
      ) throw new ApiError("INVALID_PREVIEW");
    } else if (kind === "IDAT") {
      if (!width || dataEnded) throw new ApiError("INVALID_PREVIEW");
      imageData.push(bytes.subarray(start, end));
    } else if (kind === "IEND") {
      if (length !== 0 || !imageData.length || end + 4 !== bytes.length) throw new ApiError("INVALID_PREVIEW");
      ended = true;
    } else {
      if (kind === "acTL" || (kind[0] === kind[0].toUpperCase() && kind !== "PLTE")) {
        throw new ApiError("INVALID_PREVIEW");
      }
      if (imageData.length) dataEnded = true;
    }
    offset = end + 4;
  }
  if (!ended || offset !== bytes.length) throw new ApiError("INVALID_PREVIEW");
  const compressed = new Uint8Array(imageData.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of imageData) {
    compressed.set(part, at);
    at += part.length;
  }
  const expected = height * (1 + width * 4);
  let decoded: Uint8Array;
  try {
    decoded = await boundedBytes(
      new Response(new Blob([compressed]).stream().pipeThrough(new DecompressionStream("deflate"))),
      expected,
    );
  } catch {
    throw new ApiError("INVALID_PREVIEW");
  }
  if (decoded.length !== expected) throw new ApiError("INVALID_PREVIEW");
  for (let row = 0; row < height; row++) if (decoded[row * (1 + width * 4)] > 4) throw new ApiError("INVALID_PREVIEW");
  return { kind: "png-rgba", width, height };
}
