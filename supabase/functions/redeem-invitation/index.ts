import { redeemInvitation } from "../_shared/handlers.ts";
import { environment, errorResponse } from "../_shared/security.ts";

Deno.serve((request) => {
  try {
    return redeemInvitation(request, environment());
  } catch (error) {
    return errorResponse(error);
  }
});
