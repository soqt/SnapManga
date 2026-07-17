// LifeManga: 验证 App Store 内购 receipt 并充值 credits
// 注意：生产环境建议迁移到 App Store Server API v2；这里使用 legacy verifyReceipt 以便快速上线。

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

const APPLE_SHARED_SECRET = Deno.env.get("APPLE_SHARED_SECRET");

interface VerifyParams {
  receipt_data: string;
  product_id: string;
  is_sandbox?: boolean;
}

const CREDITS_BY_PRODUCT: Record<string, number> = {
  "credits_10": 10,
  "credits_60": 60,
  "credits_150": 150,
};

async function verifyWithApple(
  receiptData: string,
  isSandbox: boolean,
): Promise<{ ok: boolean; status: number; payload: Record<string, unknown> }> {
  const url = isSandbox
    ? "https://sandbox.itunes.apple.com/verifyReceipt"
    : "https://buy.itunes.apple.com/verifyReceipt";

  const body: Record<string, string> = {
    "receipt-data": receiptData,
  };
  if (APPLE_SHARED_SECRET) body["password"] = APPLE_SHARED_SECRET;

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const payload = await res.json();
  return { ok: res.ok, status: payload.status as number, payload };
}

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (req, ctx) => {
    try {
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      const params: VerifyParams = await req.json();
      if (!params.receipt_data || !params.product_id) {
        return Response.json(
          { error: "Bad request: receipt_data and product_id required" },
          { status: 400 },
        );
      }

      const creditsToAdd = CREDITS_BY_PRODUCT[params.product_id];
      if (!creditsToAdd) {
        return Response.json(
          { error: "Unknown product_id", product_id: params.product_id },
          { status: 400 },
        );
      }

      // 先按请求的环境验证
      let result = await verifyWithApple(
        params.receipt_data,
        params.is_sandbox ?? false,
      );

      // 21007 = 该 receipt 属于 sandbox，但调用了 production
      if (result.status === 21007) {
        result = await verifyWithApple(params.receipt_data, true);
      }
      // 21008 = 该 receipt 属于 production，但调用了 sandbox
      if (result.status === 21008) {
        result = await verifyWithApple(params.receipt_data, false);
      }

      // status 0 表示成功
      if (result.status !== 0) {
        return Response.json(
          {
            error: "Apple receipt verification failed",
            status: result.status,
          },
          { status: 400 },
        );
      }

      // 查找匹配的 transaction
      const receiptInfo = (result.payload.receipt?.in_app as Array<
        Record<string, unknown>
      >) ?? [];
      const matched = receiptInfo.find((t) =>
        t.product_id === params.product_id
      );

      if (!matched) {
        return Response.json(
          { error: "Product not found in receipt" },
          { status: 400 },
        );
      }

      const transactionId = String(matched.transaction_id ?? "");

      // 幂等：检查是否已处理过该 transaction
      const { data: existing } = await ctx.supabaseAdmin
        .from("credit_transactions")
        .select("id")
        .eq("user_id", user.id)
        .eq("reason", "purchase")
        .contains("metadata", { transaction_id: transactionId })
        .maybeSingle();

      if (existing) {
        return Response.json({
          success: true,
          message: "Transaction already processed",
          credits_added: 0,
        });
      }

      // 充值
      const { error: addErr } = await ctx.supabaseAdmin.rpc("add_credits", {
        p_user_id: user.id,
        p_amount: creditsToAdd,
        p_reason: "purchase",
        p_metadata: {
          product_id: params.product_id,
          transaction_id: transactionId,
          environment: params.is_sandbox ? "sandbox" : "production",
        },
      });

      if (addErr) {
        return Response.json(
          { error: "Failed to add credits", details: addErr.message },
          { status: 500 },
        );
      }

      return Response.json({
        success: true,
        credits_added: creditsToAdd,
        transaction_id: transactionId,
      });
    } catch (err) {
      console.error("verify-purchase error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
