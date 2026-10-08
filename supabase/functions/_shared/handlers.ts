import {
  ApiError,
  authenticated,
  boundedBytes,
  type Environment,
  errorResponse,
  type Fetch,
  type Json,
  jsonBody,
  serviceRpc,
  sha256,
  uuid,
} from "./security.ts";

export type PDFValidator = (bytes: Uint8Array) => Promise<Json>;
export type PreviewValidator = (bytes: Uint8Array) => Promise<Json>;

export async function finalizeAsset(
  request: Request,
  env: Environment,
  validatePDF: PDFValidator,
  validatePreview: PreviewValidator,
  requestFetch: Fetch = fetch,
): Promise<Response> {
  try {
    if (request.method !== "POST") throw new ApiError("METHOD_NOT_ALLOWED", 405);
    const user = await authenticated(request, env, requestFetch);
    const input = await jsonBody(request);
    const id = uuid(input.asset_id);
    if (
      typeof input.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(input.sha256) ||
      !Number.isSafeInteger(input.expected_bytes) || (input.expected_bytes as number) <= 0 ||
      (input.expected_bytes as number) > 104857600
    ) throw new ApiError("INVALID_INPUT");
    const metadataResponse = await requestFetch(
      env.url + `/rest/v1/assets?id=eq.${id}&select=id,owner_user_id,type,status,storage_key,sha256,bytes`,
      {
        headers: { apikey: env.publishableKey, authorization: user.authorization },
        signal: AbortSignal.timeout(10000),
      },
    );
    if (!metadataResponse.ok) throw new ApiError("ASSET_NOT_AUTHORIZED", 403);
    const rows = JSON.parse(new TextDecoder().decode(await boundedBytes(metadataResponse, 8192)));
    const asset = Array.isArray(rows) && rows.length === 1 ? rows[0] : null;
    if (
      !asset || asset.owner_user_id !== user.id || asset.sha256 !== input.sha256 ||
      Number(asset.bytes) !== input.expected_bytes
    ) throw new ApiError("ASSET_NOT_AUTHORIZED", 403);
    if (
      !["pdf", "native", "preview"].includes(asset.type) || !["staging", "verified"].includes(asset.status) ||
      (asset.type !== "pdf" && Number(asset.bytes) > 2097152)
    ) throw new ApiError("FILE_NOT_READY", 409, true);
    let validation: Json = {};
    if (asset.status !== "verified") {
      const key = (asset.storage_key as string).split("/").map(encodeURIComponent).join("/");
      const fileResponse = await requestFetch(env.url + "/storage/v1/object/authenticated/worshipcue-private/" + key, {
        headers: { apikey: env.publishableKey, authorization: user.authorization },
        signal: AbortSignal.timeout(30000),
      });
      if (!fileResponse.ok) throw new ApiError("FILE_NOT_READY", 409, true);
      const bytes = await boundedBytes(fileResponse, Number(asset.bytes));
      if (bytes.byteLength !== Number(asset.bytes) || await sha256(bytes) !== input.sha256) {
        throw new ApiError("HASH_MISMATCH", 409, true);
      }
      validation = asset.type === "pdf"
        ? await validatePDF(bytes)
        : asset.type === "preview"
        ? await validatePreview(bytes)
        : { kind: "pencilkit-bounded" };
    }
    const receipt = await serviceRpc(
      "finalize_asset",
      { asset_id: id, actor_id: user.id, sha256: input.sha256, expected_bytes: input.expected_bytes, validation },
      env,
      requestFetch,
    );
    return Response.json(receipt);
  } catch (error) {
    return errorResponse(error);
  }
}

export async function redeemInvitation(
  request: Request,
  env: Environment,
  requestFetch: Fetch = fetch,
): Promise<Response> {
  try {
    if (request.method !== "POST") throw new ApiError("METHOD_NOT_ALLOWED", 405);
    const user = await authenticated(request, env, requestFetch);
    const limit = await serviceRpc("consume_invitation_attempt", { actor_id: user.id }, env, requestFetch) as Json;
    if (limit.allowed !== true) throw new ApiError("RATE_LIMITED", 429, true);
    const input = await jsonBody(request);
    if (
      typeof input.token !== "string" || !/^[0-9a-f]{64}$/.test(input.token) ||
      (input.display_name !== undefined && (typeof input.display_name !== "string" || input.display_name.length > 80))
    ) throw new ApiError("ACCESS_REVOKED", 403);
    const receipt = await serviceRpc(
      "redeem_invitation",
      { actor_id: user.id, token_hash: await sha256(new TextEncoder().encode(input.token)) },
      env,
      requestFetch,
    );
    return Response.json(receipt);
  } catch (error) {
    return errorResponse(error);
  }
}
