// LifeManga: 服务端代理 GPT-5-mini 编剧本
// 1. 验证用户身份
// 2. 扣除 credits
// 3. 调用 OpenAI /v1/chat/completions
// 4. 返回 JSON 剧本

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_ORG_ID = Deno.env.get("OPENAI_ORG_ID");

interface StoryParams {
  images: string[];
  styleName: string;
  panelCount?: number;
  userHint?: string;
  scriptModel?: string;
  isColor?: boolean;
}

function base64ToDataUrl(base64: string): string {
  if (base64.startsWith("data:")) return base64;
  return `data:image/jpeg;base64,${base64}`;
}

function buildSystemPrompt(styleName: string, isColor: boolean, panelCount: number): string {
  return `You are a manga scriptwriter. Look at the user's reference photo(s) and write a ${panelCount}-panel manga story script.

Output strict JSON with this structure:
{
  "title": "string",
  "synopsis": "string",
  "panels": [
    {
      "description": "string (visual description for the artist, in English)",
      "dialogue": "string (short Chinese line, ≤ 12 chars)",
      "dialogueJa": "string (short Japanese line, ≤ 8 kana)",
      "narration": "string (optional Chinese narration)",
      "narrationJa": "string (optional Japanese narration)",
      "sfx": "string (optional sound effect)"
    }
  ]
}

Rules:
- Title and synopsis in Chinese.
- Descriptions in English so the image model can render them.
- Each panel must be a distinct cinematic moment.
- Keep dialogue natural and short (manga speech bubble size).
- The story should fit the "${styleName}" manga style.
- Color mode: ${isColor ? "full color" : "black and white ink"}.
- Do not include any explanation outside the JSON.`;
}

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (req, ctx) => {
    try {
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      const params: StoryParams = await req.json();
      if (!params.images || params.images.length === 0) {
        return Response.json(
          { error: "Bad request: at least one image required" },
          { status: 400 },
        );
      }

      const panelCount = Math.max(2, Math.min(params.panelCount ?? 6, 9));
      const cost = 1; // 编剧固定 1 credit

      // 扣费
      const { data: deductOk, error: deductErr } = await ctx.supabaseAdmin.rpc(
        "deduct_credits",
        {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "generate-story:script",
          p_metadata: { panel_count: panelCount, style: params.styleName },
        },
      );

      if (deductErr) {
        return Response.json(
          { error: "Failed to deduct credits", details: deductErr.message },
          { status: 500 },
        );
      }

      if (!deductOk) {
        return Response.json(
          { error: "Insufficient credits", required: cost },
          { status: 402 },
        );
      }

      // 记录任务
      const { data: job, error: jobErr } = await ctx.supabaseAdmin
        .from("generation_jobs")
        .insert({
          user_id: user.id,
          status: "running",
          cost_credits: cost,
          kind: "story_script",
          style: params.styleName,
          prompt: params.userHint?.slice(0, 500),
        })
        .select("id")
        .single();

      if (jobErr) console.error("insert job error:", jobErr);

      const model = params.scriptModel?.startsWith("gpt-5")
        ? params.scriptModel
        : "gpt-5.4-mini";

      const messages = [
        {
          role: "system" as const,
          content: buildSystemPrompt(
            params.styleName,
            params.isColor ?? false,
            panelCount,
          ),
        },
        {
          role: "user" as const,
          content: [
            {
              type: "text" as const,
              text: params.userHint?.trim()
                ? `User hint: ${params.userHint.trim()}`
                : "Write a manga story based on these photos.",
            },
            ...params.images.map((b64) => ({
              type: "image_url" as const,
              image_url: { url: base64ToDataUrl(b64) },
            })),
          ],
        },
      ];

      const headers: Record<string, string> = {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      };
      if (OPENAI_ORG_ID) headers["OpenAI-Organization"] = OPENAI_ORG_ID;

      const openaiRes = await fetch(
        "https://api.openai.com/v1/chat/completions",
        {
          method: "POST",
          headers,
          body: JSON.stringify({
            model,
            messages,
            response_format: { type: "json_object" },
            max_tokens: 2048,
          }),
        },
      );

      const openaiJson = await openaiRes.json();

      if (!openaiRes.ok) {
        await ctx.supabaseAdmin.rpc("add_credits", {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "refund:generate-story-failed",
          p_metadata: { status: openaiRes.status, body: openaiJson },
        });

        await ctx.supabaseAdmin
          .from("generation_jobs")
          .update({
            status: "failed",
            error_code: `OPENAI_${openaiRes.status}`,
            updated_at: new Date().toISOString(),
          })
          .eq("id", job?.id ?? "00000000-0000-0000-0000-000000000000");

        return Response.json(
          {
            error: "OpenAI request failed",
            status: openaiRes.status,
            body: openaiJson,
          },
          { status: 502 },
        );
      }

      const content = (openaiJson.choices?.[0]?.message?.content as string) ??
        "";
      let script: Record<string, unknown>;
      try {
        script = JSON.parse(content);
      } catch {
        return Response.json(
          { error: "Failed to parse OpenAI response as JSON", raw: content },
          { status: 500 },
        );
      }

      if (job) {
        await ctx.supabaseAdmin
          .from("generation_jobs")
          .update({
            status: "done",
            result_urls: { script },
            updated_at: new Date().toISOString(),
          })
          .eq("id", job.id);
      }

      return Response.json({
        success: true,
        script,
        cost,
        job_id: job?.id,
      });
    } catch (err) {
      console.error("generate-story error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
