// LifeManga: 删除用户账号及所有云端数据
// 由于 RLS 已配置级联删除，删除 auth.users 行会自动清理 public 下所有数据

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (_req, ctx) => {
    try {
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      // 删除 auth 用户（级联删除 public.profiles/projects/items/characters 等）
      const { error } = await ctx.supabaseAdmin.auth.admin.deleteUser(user.id);

      if (error) {
        return Response.json(
          { error: "Failed to delete account", details: error.message },
          { status: 500 },
        );
      }

      return Response.json({
        success: true,
        message: "Account and all associated data deleted",
      });
    } catch (err) {
      console.error("delete-account error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
