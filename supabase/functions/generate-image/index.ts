// LifeManga: 服务端代理 OpenAI gpt-image-2 图像生成
// 1. 验证用户身份
// 2. 计算并扣除 credits
// 3. 调用 OpenAI /v1/images/edits
// 4. 返回生成结果 URL

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// OpenAI 配置
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_ORG_ID = Deno.env.get("OPENAI_ORG_ID");

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

// base64 data URL / 纯 base64 转 Uint8Array
function base64ToBytes(base64: string): Uint8Array {
  const clean = base64.replace(/^data:image\/\w+;base64,/, "");
  const bin = atob(clean);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}

function generateBoundary(): string {
  return "----LifeMangaBoundary" + crypto.randomUUID().replace(/-/g, "");
}

async function buildMultipartBody(
  params: GenerateParams,
  boundary: string,
): Promise<Uint8Array> {
  const encoder = new TextEncoder();
  const chunks: Uint8Array[] = [];

  const addField = (name: string, value: string) => {
    chunks.push(
      encoder.encode(
        `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`,
      ),
    );
  };

  const prompt = buildCombinedPrompt(params);
  addField("prompt", prompt);
  addField("model", "gpt-image-2");
  addField("n", String(Math.max(1, Math.min(params.n ?? 1, 4))));
  if (params.size) addField("size", params.size);
  if (params.quality) addField("quality", params.quality);

  // 输入图片
  const allImages: string[] = [];
  allImages.push(...params.images);
  if (params.previousPageImage) allImages.push(params.previousPageImage);
  if (params.characterReferenceImages) {
    allImages.push(...params.characterReferenceImages);
  }

  for (let i = 0; i < allImages.length; i++) {
    const bytes = base64ToBytes(allImages[i]);
    chunks.push(
      encoder.encode(
        `--${boundary}\r\nContent-Disposition: form-data; name="image[]"; filename="image_${i}.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`,
      ),
    );
    chunks.push(bytes);
    chunks.push(encoder.encode("\r\n"));
  }

  chunks.push(encoder.encode(`--${boundary}--\r\n`));

  // 合并
  let totalLength = 0;
  for (const c of chunks) totalLength += c.length;
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const c of chunks) {
    result.set(c, offset);
    offset += c.length;
  }
  return result;
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

      // 4. 原子扣费（使用 admin 客户端绕过 RLS）
      const { data: deductOk, error: deductErr } = await ctx.supabaseAdmin.rpc(
        "deduct_credits",
        {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: `generate-image:${params.storyScript ? "story" : "simple"}`,
          p_metadata: {
            n: params.n,
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

      // 6. 调用 OpenAI
      const boundary = generateBoundary();
      const body = await buildMultipartBody(params, boundary);

      const headers: Record<string, string> = {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": `multipart/form-data; boundary=${boundary}`,
      };
      if (OPENAI_ORG_ID) headers["OpenAI-Organization"] = OPENAI_ORG_ID;

      const openaiRes = await fetch("https://api.openai.com/v1/images/edits", {
        method: "POST",
        headers,
        body,
      });

      const openaiText = await openaiRes.text();
      let openaiJson: Record<string, unknown> | null = null;
      try {
        openaiJson = JSON.parse(openaiText);
      } catch {
        // 保留原始文本用于错误报告
      }

      if (!openaiRes.ok) {
        // 失败时把 credits 退回去
        await ctx.supabaseAdmin.rpc("add_credits", {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "refund:generate-image-failed",
          p_metadata: { status: openaiRes.status, body: openaiText.slice(0, 500) },
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
            body: openaiText.slice(0, 1000),
          },
          { status: 502 },
        );
      }

      const urls = (openaiJson?.data as Array<{ url?: string }> | undefined)
        ?.map((d) => d.url)
        .filter((u): u is string => !!u) ?? [];

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
