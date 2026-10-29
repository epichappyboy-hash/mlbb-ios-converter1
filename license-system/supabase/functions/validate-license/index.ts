import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function reply(status: number, payload: Record<string, unknown>): Response {
  return new Response(JSON.stringify(payload), { status, headers: corsHeaders });
}

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const singular = Deno.env.get("SUPABASE_SECRET_KEY");
  if (singular) return singular;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (typeof keys.default === "string") return keys.default;
    const first = Object.values(keys).find((value) => typeof value === "string");
    if (typeof first === "string") return first;
  } catch {
    // Report a generic configuration problem below.
  }
  throw new Error("No Supabase server secret is configured.");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value.trim().toUpperCase()),
  );
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply(405, { ok: false, message: "Use POST for license validation." });

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return reply(400, { ok: false, message: "Request body must be valid JSON." });
  }

  const licenseKey = typeof body.license_key === "string" ? body.license_key.trim().toUpperCase() : "";
  const deviceId = typeof body.device_id === "string" ? body.device_id.trim() : "";
  const deviceName = typeof body.device_name === "string" ? body.device_name.trim().slice(0, 80) : "iOS device";

  if (licenseKey.length < 12 || licenseKey.length > 100) {
    return reply(400, { ok: false, message: "Enter a valid license key." });
  }
  if (deviceId.length < 8 || deviceId.length > 128) {
    return reply(400, { ok: false, message: "This device could not be identified. Restart the app and try again." });
  }

  try {
    const url = Deno.env.get("SUPABASE_URL");
    if (!url) throw new Error("SUPABASE_URL is missing.");
    const admin = createClient(url, serviceKey(), {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const keyHash = await sha256Hex(licenseKey);
    const { data, error } = await admin.rpc("verify_isha_license", {
      p_key_hash: keyHash,
      p_device_id: deviceId,
      p_device_name: deviceName || "iOS device",
    });

    if (error) {
      console.error("License validation database error:", error.message);
      return reply(500, { ok: false, message: "The license service is temporarily unavailable." });
    }

    const result = Array.isArray(data) ? data[0] : data;
    if (!result || typeof result.ok !== "boolean") {
      return reply(500, { ok: false, message: "The license service returned an invalid result." });
    }

    return reply(result.ok ? 200 : 403, {
      ok: result.ok,
      message: result.message,
      expires_at: result.expires_at ?? null,
    });
  } catch (error) {
    console.error("License validation configuration error:", error instanceof Error ? error.message : "unknown");
    return reply(500, { ok: false, message: "The license service is not configured correctly." });
  }
});
