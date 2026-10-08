export type Json = Record<string, unknown>;
export type Environment = { url: string; publishableKey: string; serviceKey: string };
export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export class ApiError extends Error {
  constructor(public code: string, public status = 400, public retryable = false) {
    super(code);
  }
}

export function environment(): Environment {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const publishableKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new ApiError("SERVER_CONFIGURATION", 503);
  }
  if (
    (!["https:", "http:"].includes(parsed.protocol)) ||
    (parsed.protocol === "http:" && !["localhost", "127.0.0.1", "kong"].includes(parsed.hostname)) || !publishableKey ||
    !serviceKey
  ) throw new ApiError("SERVER_CONFIGURATION", 503);
  return { url: url.replace(/\/$/, ""), publishableKey, serviceKey };
}

export async function boundedBytes(response: Response | Request, limit: number): Promise<Uint8Array> {
  const length = response.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > limit)) throw new ApiError("SIZE_LIMIT", 413);
  const reader = response.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) throw new ApiError("SIZE_LIMIT", 413);
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

export async function jsonBody(request: Request): Promise<Json> {
  const raw = await boundedBytes(request, 4096);
  try {
    const result = JSON.parse(new TextDecoder().decode(raw));
    if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error();
    return result;
  } catch {
    throw new ApiError("INVALID_INPUT");
  }
}

export function uuid(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
  ) throw new ApiError("INVALID_INPUT");
  return value;
}

export async function authenticated(
  request: Request,
  env: Environment,
  requestFetch: Fetch,
): Promise<{ id: string; authorization: string }> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.length > 8192) {
    throw new ApiError("AUTH_REQUIRED", 401, true);
  }
  const response = await requestFetch(env.url + "/auth/v1/user", {
    headers: { apikey: env.publishableKey, authorization },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new ApiError("AUTH_REQUIRED", response.status >= 500 ? 503 : 401, true);
  const user = JSON.parse(new TextDecoder().decode(await boundedBytes(response, 32768)));
  return { id: uuid(user.id), authorization };
}

export async function serviceRpc(name: string, p: Json, env: Environment, requestFetch: Fetch): Promise<unknown> {
  const response = await requestFetch(env.url + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: env.serviceKey, authorization: "Bearer " + env.serviceKey, "content-type": "application/json" },
    body: JSON.stringify({ p }),
    signal: AbortSignal.timeout(10000),
  });
  const raw = await boundedBytes(response, 65536);
  if (response.status >= 500) throw new ApiError("FILE_NOT_READY", 503, true);
  const result = JSON.parse(new TextDecoder().decode(raw));
  if (!response.ok) {
    const code = typeof result?.message === "string" && /^[A-Z_]{3,50}$/.test(result.message)
      ? result.message
      : "ACCESS_REVOKED";
    throw new ApiError(
      code,
      code === "RATE_LIMITED" ? 429 : ["HASH_MISMATCH", "FILE_NOT_READY"].includes(code) ? 409 : 403,
      ["RATE_LIMITED", "HASH_MISMATCH", "FILE_NOT_READY", "AUTH_REQUIRED"].includes(code),
    );
  }
  return result;
}

export async function sha256(bytes: Uint8Array): Promise<string> {
  const source = bytes.buffer instanceof ArrayBuffer
    ? new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    : new Uint8Array(bytes);
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", source))].map((v) => v.toString(16).padStart(2, "0"))
    .join("");
}

export function errorResponse(error: unknown): Response {
  const value = error instanceof ApiError ? error : error instanceof TypeError ||
      (error instanceof DOMException && ["AbortError", "TimeoutError"].includes(error.name))
    ? new ApiError("FILE_NOT_READY", 503, true)
    : new ApiError("VALIDATION_FAILED", 400);
  const messageKeys: Record<string, string> = {
    HASH_MISMATCH: "download.failure",
    FILE_NOT_READY: "download.missing",
    INVALID_PAGE: "download.failure",
    RATE_LIMITED: "download.retry",
    INVALID_KEY: "key.unknown",
    STALE_CONTROLLER: "notes.leaseLost",
    REVISION_CONFLICT: "notes.conflict",
    SESSION_ENDED: "live.ended",
    STALE_CALL: "live.staleTap",
    IDEMPOTENCY_CONFLICT: "live.staleTap",
  };
  return Response.json({
    code: value.code,
    message_key: messageKeys[value.code] ?? "permission.denied",
    retryable: value.retryable,
    correlation_id: crypto.randomUUID(),
    details: {},
  }, { status: value.status, headers: value.status === 429 ? { "Retry-After": "60" } : {} });
}
