// LifeManga: 获取当前用户 credits 余额

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (_req, ctx) => {
    try {
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      const { data, error } = await ctx.supabaseAdmin
        .from("profiles")
        .select("purchased_credits, subscription_credits, subscription_tier, total_generated")
        .eq("id", user.id)
        .single();

      if (error) {
        return Response.json(
          { error: "Failed to fetch credits", details: error.message },
          { status: 500 },
        );
      }

      const purchased = data?.purchased_credits ?? 0;
      const subscription = data?.subscription_credits ?? 0;

      return Response.json({
        total: purchased + subscription,
        purchased,
        subscription,
        tier: data?.subscription_tier ?? "free",
        total_generated: data?.total_generated ?? 0,
      });
    } catch (err) {
      console.error("get-credits error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
