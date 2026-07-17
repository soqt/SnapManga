// Shared helper: call SuperToken image API and upload results to Supabase Storage.
// The returned URLs are public Supabase Storage URLs, so the iOS client stays unchanged.

const DEFAULT_SUPERTOKEN_IMAGE_BASE_URL = "https://api.supertoken.cc/image-wrapper/v1";
const DEFAULT_GENERATED_MIME_TYPE = "image/png";
const BUCKET_NAME = "generated-images";

export interface SuperTokenImageInput {
  prompt: string;
  n: number;
  size?: string;
  quality?: string;
  images: { blob: Blob; filename: string }[];
}

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.length === 0) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

function parseModelList(value: string | undefined): string[] {
  const models = value
    ?.split(",")
    .map((m) => m.trim())
    .filter(Boolean) ?? [];
  return models.length > 0 ? [...new Set(models)] : ["gpt-image-2-count"];
}

function normalizeImageMimeType(value: string | null | undefined): string {
  const mimeType = value?.split(";", 1)[0]?.trim().toLowerCase();
  if (
    mimeType === "image/jpeg" || mimeType === "image/png" || mimeType === "image/webp"
  ) {
    return mimeType;
  }
  return DEFAULT_GENERATED_MIME_TYPE;
}

function parseBase64Image(value: string): { bytes: Uint8Array; mimeType: string } | null {
  const trimmed = value.trim();
  if (!trimmed) return null;

  const dataUrlMatch = trimmed.match(/^data:([^;,]+);base64,(.+)$/is);
  if (dataUrlMatch) {
    const [, mimeType, base64] = dataUrlMatch;
    return { bytes: base64ToBytes(base64.trim()), mimeType: normalizeImageMimeType(mimeType) };
  }

  return { bytes: base64ToBytes(trimmed), mimeType: DEFAULT_GENERATED_MIME_TYPE };
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

async function fetchImageBytes(url: string): Promise<{ bytes: Uint8Array; mimeType: string }> {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`failed_to_download_image:${res.status}`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  return { bytes, mimeType: normalizeImageMimeType(res.headers.get("content-type")) };
}

async function ensureBucket(adminClient: any): Promise<void> {
  try {
    await adminClient.storage.createBucket(BUCKET_NAME, { public: true });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (!/already exists/i.test(msg)) {
      console.warn("create bucket warning:", msg);
    }
  }
}

async function uploadResult(
  adminClient: any,
  userId: string,
  image: { bytes: Uint8Array; mimeType: string },
): Promise<string> {
  await ensureBucket(adminClient);

  const ext = image.mimeType === "image/jpeg" ? "jpg" : "png";
  const path = `${userId}/${crypto.randomUUID()}.${ext}`;

  const { error: uploadError } = await adminClient.storage
    .from(BUCKET_NAME)
    .upload(path, image.bytes, {
      contentType: image.mimeType,
      upsert: false,
    });

  if (uploadError) {
    throw new Error(`storage_upload_failed:${uploadError.message}`);
  }

  const { data: publicUrlData } = adminClient.storage
    .from(BUCKET_NAME)
    .getPublicUrl(path);

  return publicUrlData.publicUrl as string;
}

async function parseImagesFromOpenAIShape(
  response: Response,
): Promise<{ bytes: Uint8Array; mimeType: string }[]> {
  if (!response.ok) {
    const raw = await response.text().catch(() => "");
    let upstreamMessage: string | undefined;
    try {
      const payload = JSON.parse(raw);
      upstreamMessage =
        payload?.error?.message ?? payload?.message ?? raw.slice(0, 500);
    } catch {
      upstreamMessage = raw.slice(0, 500);
    }
    console.error("SuperToken image provider error:", response.status, upstreamMessage);
    throw new Error(`image_generation_failed:${response.status}:${upstreamMessage}`);
  }

  const payload = await response.json();
  const items = Array.isArray(payload?.data) ? payload.data : [];
  const results: { bytes: Uint8Array; mimeType: string }[] = [];

  for (const item of items) {
    const b64 = item?.b64_json;
    if (typeof b64 === "string") {
      const parsed = parseBase64Image(b64);
      if (parsed) {
        results.push(parsed);
        continue;
      }
    }

    const url = item?.url;
    if (typeof url === "string" && url.trim().length > 0) {
      results.push(await fetchImageBytes(url));
      continue;
    }
  }

  if (results.length === 0) {
    console.error("SuperToken returned no image payload:", JSON.stringify(payload).slice(0, 500));
    throw new Error("empty_image");
  }

  return results;
}

/**
 * Call SuperToken /images/edits and return public Supabase Storage URLs.
 * Falls back through SUPERTOKEN_IMAGE_MODELS if a model is unavailable.
 */
export async function generateImagesWithSuperToken(
  adminClient: any,
  userId: string,
  input: SuperTokenImageInput,
): Promise<string[]> {
  const apiKey = requireEnv("SUPERTOKEN_API_KEY");
  const baseUrl =
    Deno.env.get("SUPERTOKEN_IMAGE_BASE_URL") ?? DEFAULT_SUPERTOKEN_IMAGE_BASE_URL;
  const endpoint = `${baseUrl.replace(/\/+$/, "")}/images/edits`;
  const models = parseModelList(Deno.env.get("SUPERTOKEN_IMAGE_MODELS"));

  let lastUnavailableError: Error | undefined;

  for (const [index, model] of models.entries()) {
    const form = new FormData();
    form.append("model", model);
    form.append("prompt", input.prompt);
    form.append("n", String(Math.max(1, Math.min(input.n, 4))));
    if (input.size) form.append("size", input.size);
    if (input.quality) form.append("quality", input.quality);

    for (const img of input.images) {
      form.append("image[]", img.blob, img.filename);
    }

    const response = await fetch(endpoint, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
    });

    try {
      const images = await parseImagesFromOpenAIShape(response);
      const publicUrls: string[] = [];
      for (const image of images) {
        publicUrls.push(await uploadResult(adminClient, userId, image));
      }
      return publicUrls;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      const isModelUnavailable =
        error.message.startsWith("image_model_unavailable:") ||
        /No available channel for model/i.test(error.message);

      if (isModelUnavailable && index < models.length - 1) {
        lastUnavailableError = error;
        console.warn(`SuperToken model "${model}" unavailable; trying fallback "${models[index + 1]}".`);
        continue;
      }
      throw error;
    }
  }

  throw lastUnavailableError ?? new Error("image_generation_failed");
}
