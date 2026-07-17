// LifeManga: 服务端代理角色设定稿 / 动作合集生成

import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_ORG_ID = Deno.env.get("OPENAI_ORG_ID");

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

function generateBoundary(): string {
  return "----LifeMangaBoundary" + crypto.randomUUID().replace(/-/g, "");
}

function buildCharacterSheetPrompt(params: CharacterParams): string {
  const name = params.name;
  const bio = params.bio?.trim();
  const artStyle = params.artStyle ?? "Modern Japanese anime/manga character illustration style";

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

async function buildMultipartBody(
  params: CharacterParams,
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

  const prompt = params.mode === "sheet"
    ? buildCharacterSheetPrompt(params)
    : buildPoseSheetPrompt(params);

  addField("prompt", prompt);
  addField("model", "gpt-image-2");
  addField("n", "1");
  if (params.size) addField("size", params.size);
  if (params.quality) addField("quality", params.quality);

  const bytes = base64ToBytes(params.sourceImage);
  chunks.push(
    encoder.encode(
      `--${boundary}\r\nContent-Disposition: form-data; name="image[]"; filename="source.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`,
    ),
  );
  chunks.push(bytes);
  chunks.push(encoder.encode("\r\n"));
  chunks.push(encoder.encode(`--${boundary}--\r\n`));

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
        // ignore
      }

      if (!openaiRes.ok) {
        await ctx.supabaseAdmin.rpc("add_credits", {
          p_user_id: user.id,
          p_amount: cost,
          p_reason: "refund:generate-character-failed",
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
