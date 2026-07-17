// LifeManga: 服务端代理角色设定稿 / 动作合集生成（使用 SuperToken 网关）

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import {
  generateImagesWithSuperToken,
  SuperTokenImageInput,
} from "../_shared/supertokenImage.ts";

interface CharacterParams {
  mode: "sheet" | "pose_sheet";
  sourceImage: string; // base64
  name: string;
  bio?: string;
  artStyle?: string; // 用于 sheet 模式
  stylePrompt?: string; // 用于 pose_sheet 模式
  poses?: Array<{ label: string; prompt: string }>;
  size?: string;
  quality?: string;
  isColor?: boolean;
}

function calculateCost(params: CharacterParams): number {
  if (params.mode === "pose_sheet") return 3;
  return 2; // 设定稿
}

function base64ToBytes(base64: string): Uint8Array {
  const clean = base64.replace(/^data:image\/\w+;base64,/, "");
  const bin = atob(clean);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}

function buildCharacterSheetPrompt(params: CharacterParams): string {
  const name = params.name;
  const bio = params.bio?.trim();
  const artStyle = params.artStyle ??
    "Modern Japanese anime/manga character illustration style";

  return `Stylize the adult person in the reference photo into a polished character illustration.

Composition (single image, white background):
• Center: full-body or 3/4 body portrait, natural pose, signature outfit.
• Top-right: 4 small head sketches with different expressions (smile / thoughtful / laugh / calm).
• Right side: 1 signature accessory (glasses/watch/scarf etc fitting the bio) as a small callout with bilingual caption (中文 / English), thin arrow pointing to the spot on the character.
• Bottom: 3 small life-style items (journal / phone / coffee / bag etc fitting the bio), each with a tiny bilingual caption (中文 / English).

Character: ${name}.${bio ? ` ${bio}.` : ""}

Art style: ${artStyle}

Rules: ADULT character (not a child). Modest clothing. White background. Match face/hair/build from photo. Same person in all expressions. Real legible Chinese characters.`;
}

function buildPoseSheetPrompt(params: CharacterParams): string {
  const name = params.name;
  const bio = params.bio?.trim();
  const poses = params.poses ?? [];
  const style = params.stylePrompt ?? "";

  return `Create a single character pose sheet illustration on plain white background — show the SAME adult character drawn ${poses.length} times in different poses, all arranged on ONE page.

Character: ${name}.${bio ? ` ${bio}.` : ""}

Show the character in these ${poses.length} poses:
${poses.map((p, i) => `${i + 1}. ${p.label} — ${p.prompt}`).join("\n")}

Layout: white background, balanced grid (e.g. 3 columns × needed rows). Each pose has a small bilingual caption below it (中文 / English).

Art style:
${style}

Rules: ADULT character (not a child). Modest clothing. Plain white background. Match face/hair/build from reference photo. Same person in ALL poses. Real legible Chinese characters.`;
}

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (req, ctx) => {
    try {
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      const params: CharacterParams = await req.json();
      if (!params.sourceImage) {
        return Response.json(
          { error: "Bad request: sourceImage required" },
          { status: 400 },
        );
      }

      const cost = calculateCost(params);

      const { data: deductOk, error: deductErr } = await ctx.supabaseAdmin.rpc(
        "deduct_credits",
        {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: `generate-character:${params.mode}`,
          p_metadata: { mode: params.mode, name: params.name },
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

      const { data: job, error: jobErr } = await ctx.supabaseAdmin
        .from("generation_jobs")
        .insert({
          user_id: user.id,
          status: "running",
          cost_credits: cost,
          kind: params.mode === "sheet" ? "character_sheet" : "pose_sheet",
          style: params.mode,
          prompt: params.name,
        })
        .select("id")
        .single();

      if (jobErr) console.error("insert job error:", jobErr);

      const prompt = params.mode === "sheet"
        ? buildCharacterSheetPrompt(params)
        : buildPoseSheetPrompt(params);

      const imageInput: SuperTokenImageInput = {
        prompt,
        n: 1,
        size: params.size,
        quality: params.quality,
        images: [{
          blob: new Blob([base64ToBytes(params.sourceImage).buffer], {
            type: "image/jpeg",
          }),
          filename: "source.jpg",
        }],
      };

      let urls: string[];
      try {
        urls = await generateImagesWithSuperToken(
          ctx.supabaseAdmin,
          user.id,
          imageInput,
        );
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error("generate-character provider error:", err);

        await ctx.supabaseAdmin.rpc("add_credits", {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "refund:generate-character-failed",
          p_metadata: { error: message.slice(0, 500) },
        });

        await ctx.supabaseAdmin
          .from("generation_jobs")
          .update({
            status: "failed",
            error_code: "IMAGE_PROVIDER_FAILED",
            updated_at: new Date().toISOString(),
          })
          .eq("id", job?.id ?? "00000000-0000-0000-0000-000000000000");

        return Response.json(
          { error: "Image generation failed", details: message },
          { status: 502 },
        );
      }

      if (job) {
        await ctx.supabaseAdmin
          .from("generation_jobs")
          .update({
            status: "done",
            result_urls: urls,
            updated_at: new Date().toISOString(),
          })
          .eq("id", job.id);
      }

      return Response.json({
        success: true,
        urls,
        cost,
        job_id: job?.id,
      });
    } catch (err) {
      console.error("generate-character error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
