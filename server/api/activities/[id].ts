import { authorized, json, loadConfig, serverError } from "../../src/config.js";
import { RedisStore } from "../../src/store.js";

/** Forgets an activity the user stopped following, or that ended on the phone. */
export async function DELETE(request: Request): Promise<Response> {
  try {
    const config = loadConfig();
    if (!authorized(request, config.appSecret)) {
      return json(401, { error: "unauthorized" });
    }
    const id = decodeURIComponent(new URL(request.url).pathname.split("/").pop() ?? "");
    if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) {
      return json(400, { error: "activityId" });
    }
    const store = RedisStore.fromEnv();
    const record = await store.get(id);
    if (record) {
      await store.remove([record]);
    }
    return new Response(null, { status: 204 });
  } catch (error) {
    return serverError(error);
  }
}
