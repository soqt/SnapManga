// LifeManga: 服务端代理图像生成（使用 SuperToken 网关）
// 1. 验证用户身份
// 2. 计算并扣除 credits
// 3. 调用 SuperToken /images/edits
// 4. 将结果上传到 Supabase Storage 并返回公开 URL

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import {
  generateImagesWithSuperToken,
  SuperTokenImageInput,
} from "../_shared/supertokenImage.ts";

// 费用表：每个请求基础费用 = 张数 × 质量倍数 × 模式倍数
function calculateCost(params: GenerateParams): number {
  const qualityMultiplier: Record<string, number> = {
    low: 1,
    medium: 1,
    high: 2,
    auto: 1,
  };
  const modeMultiplier = params.storyScript ? 1.5 : 1;
  const n = Math.max(1, Math.min(params.n ?? 1, 4));
  const q = qualityMultiplier[params.quality ?? "medium"] ?? 1;
  return Math.ceil(n * q * modeMultiplier);
}

interface GenerateParams {
  images: string[]; // base64 数组
  stylePrompt: string;
  userPrompt?: string;
  previousPageImage?: string;
  characterReferenceImages?: string[];
  characterDirective?: string;
  n?: number;
  size?: string;
  quality?: string;
  bubbleTextMode?: string;
  isColor?: boolean;
  storyScript?: Record<string, unknown>;
}

function buildCombinedPrompt(params: GenerateParams): string {
  const parts: string[] = [params.stylePrompt];

  // 气泡文字指令
  parts.push(buildBubbleDirective(params.bubbleTextMode ?? "chinese"));

  // 前一张风格延续
  if (params.previousPageImage) {
    parts.push(`STYLE & STORY CONTINUITY:
The FIRST attached reference image is the PREVIOUS manga page from the same comic.
Treat it as the gold standard for art style, line weight, character designs, costume
details, and overall aesthetic. The new page must look like it could come right after
that page in the same printed book.
If recurring characters appear, KEEP their faces, hair, and outfits identical.
Continue the visual narrative naturally — do not reset the style.`);
  }

  // 角色指令
  if (params.characterDirective) {
    parts.push(params.characterDirective);
  }

  // 故事模式剧本
  if (params.storyScript) {
    const script = params.storyScript;
    parts.push(`STORY SCRIPT TO ILLUSTRATE:
Title: ${script.title ?? ""}
Synopsis: ${script.synopsis ?? ""}
Panels: ${JSON.stringify(script.panels ?? [])}`);
  }

  // 用户补充
  if (params.userPrompt?.trim()) {
    parts.push(`Additional user note: ${params.userPrompt.trim()}`);
  }

  return parts.join("\n\n");
}

function buildBubbleDirective(mode: string): string {
  switch (mode) {
    case "none":
      return `BUBBLE / TEXT INSTRUCTION (override anything else):
Do NOT draw any speech bubbles, caption boxes, or dialogue text on this page.
Pure visual illustration only.`;
    case "empty":
      return `BUBBLE / TEXT INSTRUCTION:
If you draw speech bubbles or caption boxes, leave them COMPLETELY EMPTY —
do NOT write any text inside them.`;
    case "japanese":
      return `BUBBLE / TEXT INSTRUCTION:
If you add speech bubbles, render the dialogue inside them in JAPANESE
(hiragana/katakana, short natural manga-style lines, ≤ 8 kana per bubble).
Do NOT use English. Do NOT use Chinese.`;
    case "english":
      return `BUBBLE / TEXT INSTRUCTION:
If you add speech bubbles, render the dialogue inside them in ENGLISH
(short natural English manga-style lines).`;
    default:
      return `BUBBLE / TEXT INSTRUCTION:
If you add speech bubbles, render the dialogue inside them in SIMPLIFIED
CHINESE (短的中文台词，自然的漫画对话，每个气泡 ≤ 12 字).
Do NOT use English. Do NOT use Japanese kana.`;
  }
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

function base64ImagesToBlobs(images: string[]): { blob: Blob; filename: string }[] {
  return images.map((b64, i) => ({
    blob: new Blob([base64ToBytes(b64).buffer], { type: "image/jpeg" }),
    filename: `image_${i}.jpg`,
  }));
}

export default {
  fetch: withSupabase({ auth: ["publishable"] }, async (req, ctx) => {
    try {
      // 1. 认证
      const user = ctx.user;
      if (!user) {
        return Response.json({ error: "Unauthorized" }, { status: 401 });
      }

      // 2. 解析请求
      const params: GenerateParams = await req.json();
      if (!params.images || params.images.length === 0) {
        return Response.json(
          { error: "Bad request: at least one image required" },
          { status: 400 },
        );
      }
      if (!params.stylePrompt) {
        return Response.json(
          { error: "Bad request: stylePrompt required" },
          { status: 400 },
        );
      }

      // 3. 计算费用
      const cost = calculateCost(params);
      const n = Math.max(1, Math.min(params.n ?? 1, 4));

      // 4. 原子扣费（使用 admin 客户端绕过 RLS）
      const { data: deductOk, error: deductErr } = await ctx.supabaseAdmin.rpc(
        "deduct_credits",
        {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: `generate-image:${params.storyScript ? "story" : "simple"}`,
          p_metadata: {
            n,
            size: params.size,
            quality: params.quality,
            style: params.stylePrompt.slice(0, 100),
          },
        },
      );

      if (deductErr) {
        console.error("deduct_credits error:", deductErr);
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

      // 5. 记录任务 running
      const { data: job, error: jobErr } = await ctx.supabaseAdmin
        .from("generation_jobs")
        .insert({
          user_id: user.id,
          status: "running",
          cost_credits: cost,
          kind: params.storyScript ? "story_render" : "simple_image",
          style: params.stylePrompt.slice(0, 200),
          prompt: buildCombinedPrompt(params).slice(0, 2000),
        })
        .select("id")
        .single();

      if (jobErr) {
        console.error("insert job error:", jobErr);
      }

      // 6. 调用 SuperToken 生成图片
      const allImages: string[] = [
        ...params.images,
        ...(params.previousPageImage ? [params.previousPageImage] : []),
        ...(params.characterReferenceImages ?? []),
      ];

      const imageInput: SuperTokenImageInput = {
        prompt: buildCombinedPrompt(params),
        n,
        size: params.size,
        quality: params.quality,
        images: base64ImagesToBlobs(allImages),
      };

      let urls: string[];
      try {
        urls = await generateImagesWithSuperToken(
          ctx.supabaseAdmin,
          user.id,
          imageInput,
        );
      } catch (err) {
        // 失败时把 credits 退回去
        const message = err instanceof Error ? err.message : String(err);
        console.error("generate-image provider error:", err);

        await ctx.supabaseAdmin.rpc("add_credits", {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "refund:generate-image-failed",
          p_metadata: { error: message.slice(0, 500) },
        });

        await ctx.supabaseAdmin
          .from("generation_jobs")
          .update({
            status: "failed",
            error_code: `IMAGE_PROVIDER_FAILED`,
            updated_at: new Date().toISOString(),
          })
          .eq("id", job?.id ?? "00000000-0000-0000-0000-000000000000");

        return Response.json(
          { error: "Image generation failed", details: message },
          { status: 502 },
        );
      }

      // 7. 更新任务 done
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

      // 增加生成计数
      await ctx.supabaseAdmin.rpc("increment_generated_count", {
        p_user_id: user.id,
      });

      return Response.json({
        success: true,
        urls,
        cost,
        job_id: job?.id,
      });
    } catch (err) {
      console.error("generate-image error:", err);
      const message = err instanceof Error ? err.message : String(err);
      return Response.json(
        { error: "Internal server error", details: message },
        { status: 500 },
      );
    }
  }),
};
