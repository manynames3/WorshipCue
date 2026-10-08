import { finalizeAsset, redeemInvitation } from "../functions/_shared/handlers.ts";
import { ApiError, boundedBytes, type Environment, type Fetch, sha256 } from "../functions/_shared/security.ts";
import { validatePNG } from "../functions/_shared/png.ts";

const env: Environment = {
  url: "https://synthetic.invalid",
  publishableKey: "synthetic-publishable",
  serviceKey: "synthetic-service",
};
const actor = "00000000-0000-4000-8000-000000000001";
const assetId = "00000000-0000-4000-8000-000000000002";
const request = (body: unknown) =>
  new Request("https://synthetic.invalid/function", {
    method: "POST",
    headers: { authorization: "Bearer synthetic-user-token", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const unusedPDF = () => Promise.reject(new ApiError("PDF_VALIDATOR_NOT_CONFIGURED"));

Deno.test("bounded request and streamed response reject oversize bytes", async () => {
  let failed = false;
  try {
    await boundedBytes(new Response(new Uint8Array(9)), 8);
  } catch {
    failed = true;
  }
  assert(failed);
  failed = false;
  try {
    await boundedBytes(new Response("a", { headers: { "content-length": "10000" } }), 8);
  } catch {
    failed = true;
  }
  assert(failed);
});

Deno.test("managed Auth validates bearer instead of trusting a supplied actor", async () => {
  const mocked: Fetch = (_input, _init) =>
    Promise.resolve(Response.json({ message: "Invalid token" }, { status: 401 }));
  const response = await redeemInvitation(request({ actor_id: actor, token: "a".repeat(64) }), env, mocked);
  assert(response.status === 401 && (await response.json()).code === "AUTH_REQUIRED");
});

Deno.test("invitation service receives authenticated actor and only a token hash", async () => {
  const token = "a".repeat(64);
  let calls = 0;
  const mocked: Fetch = async (input, init) => {
    calls++;
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) return Response.json({ id: actor, is_anonymous: true });
    const body = JSON.parse(String(init?.body));
    assert(body.p.actor_id === actor && !JSON.stringify(body).includes(token));
    if (url.endsWith("/consume_invitation_attempt")) return Response.json({ allowed: true });
    assert(url.endsWith("/redeem_invitation") && body.p.token_hash === await sha256(new TextEncoder().encode(token)));
    return Response.json({ schema_version: 1, role: "guest" });
  };
  const response = await redeemInvitation(request({ token, actor_id: "spoofed" }), env, mocked);
  assert(response.status === 200 && calls === 3);
});

Deno.test("failed invitation attempts commit throttling before token validation", async () => {
  let calls = 0;
  const mocked: Fetch = (input) => {
    calls++;
    return Promise.resolve(
      String(input).endsWith("/auth/v1/user") ? Response.json({ id: actor }) : Response.json({ allowed: false }),
    );
  };
  const response = await redeemInvitation(request({ token: "invalid" }), env, mocked);
  assert(response.status === 429 && calls === 2 && response.headers.get("Retry-After") === "60");
});

function finalizerFetch(
  data: Uint8Array,
  checksum: string,
  options: { wrongOwner?: boolean; corrupt?: boolean } = {},
): { fetch: Fetch; serviceCalls: () => number } {
  let calls = 0;
  const mocked: Fetch = (input, init) => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) return Promise.resolve(Response.json({ id: actor }));
    if (url.includes("/rest/v1/assets?")) {
      return Promise.resolve(Response.json([{
        id: assetId,
        owner_user_id: options.wrongOwner ? assetId : actor,
        type: "native",
        status: "staging",
        storage_key: "synthetic/object.drawing",
        sha256: checksum,
        bytes: data.length,
      }]));
    }
    if (url.includes("/storage/")) {
      return Promise.resolve(new Response(options.corrupt ? new Uint8Array(data.length) : new Uint8Array(data)));
    }
    calls++;
    const body = JSON.parse(String(init?.body));
    assert(body.p.actor_id === actor && body.p.validation.kind === "pencilkit-bounded");
    return Promise.resolve(Response.json({ schema_version: 1, asset_id: assetId, status: "verified" }));
  };
  return { fetch: mocked, serviceCalls: () => calls };
}

Deno.test("asset owner, downloaded bytes and hash are checked before finalization", async () => {
  const data = new TextEncoder().encode("synthetic opaque bounded native archive");
  const hash = await sha256(data), payload = { asset_id: assetId, sha256: hash, expected_bytes: data.length };
  const valid = finalizerFetch(data, hash);
  assert(
    (await finalizeAsset(request(payload), env, unusedPDF, validatePNG, valid.fetch)).status === 200 &&
      valid.serviceCalls() === 1,
  );
  const corrupted = finalizerFetch(data, hash, { corrupt: true });
  const response = await finalizeAsset(request(payload), env, unusedPDF, validatePNG, corrupted.fetch);
  assert(response.status === 409 && (await response.json()).code === "HASH_MISMATCH" && corrupted.serviceCalls() === 0);
  const wrong = finalizerFetch(data, hash, { wrongOwner: true });
  assert(
    (await finalizeAsset(request(payload), env, unusedPDF, validatePNG, wrong.fetch)).status === 403 &&
      wrong.serviceCalls() === 0,
  );
});

Deno.test("PNG validator checks decoded RGBA extent, CRC and complete stream", async () => {
  const png = Uint8Array.from(
    atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="),
    (c) => c.charCodeAt(0),
  );
  const result = await validatePNG(png);
  assert(result.width === 1 && result.height === 1);
  const corrupt = png.slice();
  corrupt[corrupt.length - 1] ^= 1;
  let rejected = false;
  try {
    await validatePNG(corrupt);
  } catch {
    rejected = true;
  }
  assert(rejected);
  rejected = false;
  try {
    await validatePNG(png.subarray(0, png.length - 1));
  } catch {
    rejected = true;
  }
  assert(rejected);
});

Deno.test("error bodies never expose upstream secrets or service details", async () => {
  const mocked: Fetch = (input) =>
    Promise.resolve(
      String(input).endsWith("/auth/v1/user")
        ? Response.json({ id: actor })
        : Response.json({ message: "synthetic-service private-secret", details: "do not return" }, { status: 500 }),
    );
  const response = await redeemInvitation(request({ token: "a".repeat(64) }), env, mocked);
  const body = await response.text();
  assert(response.status === 503 && !body.includes("synthetic-service") && !body.includes("private-secret"));
});
