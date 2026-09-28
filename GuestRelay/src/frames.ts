// Host socket framing: type u8 | session u32 BE | payload.

export const OPEN = 0x01;
export const DATA = 0x02;
export const CLOSE = 0x03;

export type FrameType = typeof OPEN | typeof DATA | typeof CLOSE;

export const HEADER_BYTES = 5;
/** The longest reason a WebSocket close frame can carry. */
export const MAX_CLOSE_REASON_BYTES = 123;

export interface Frame {
  type: FrameType;
  session: number;
  payload: Uint8Array;
}

export function encodeFrame(type: FrameType, session: number, payload?: ArrayBuffer): ArrayBuffer {
  const bytes = new Uint8Array(HEADER_BYTES + (payload?.byteLength ?? 0));
  const view = new DataView(bytes.buffer);
  view.setUint8(0, type);
  view.setUint32(1, session, false);
  if (payload !== undefined) bytes.set(new Uint8Array(payload), HEADER_BYTES);
  return bytes.buffer;
}

/** Returns null for a frame that is too short or has an unknown type. */
export function parseFrame(message: ArrayBuffer): Frame | null {
  if (message.byteLength < HEADER_BYTES) return null;
  const view = new DataView(message);
  const type = view.getUint8(0);
  if (type !== OPEN && type !== DATA && type !== CLOSE) return null;
  return { type, session: view.getUint32(1, false), payload: new Uint8Array(message, HEADER_BYTES) };
}

/** The CLOSE payload as a WebSocket close reason; empty unless it is valid UTF-8 of at most 123 bytes. */
export function closeReason(payload: Uint8Array): string {
  if (payload.byteLength > MAX_CLOSE_REASON_BYTES) return "";
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(payload);
  } catch {
    return "";
  }
}
