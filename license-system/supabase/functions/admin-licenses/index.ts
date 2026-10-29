import { createClient, type User } from "npm:@supabase/supabase-js@2";

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

async function hashKey(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value.toUpperCase()));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const allowedDays = [7, 30, 90, 365];
const allowedActivations = [1, 2, 3, 5, 10];
const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function generateLicenseKey(): string {
  // Sixteen random characters from a 32-character alphabet provides an 80-bit key.
  const random = crypto.getRandomValues(new Uint8Array(16));
  const chunks: string[] = [];
  for (let i = 0; i < random.length; i += 4) {
    chunks.push(Array.from(random.slice(i, i + 4), (b) => alphabet[b % alphabet.length]).join(""));
  }
  return "ISHA-" + chunks.join("-");
}

function validDays(value: unknown): number | null | undefined {
  if (value === "lifetime" || value === null) return null;
  const days = Number(value);
  return allowedDays.includes(days) ? days : undefined;
}

function validActivationCount(value: unknown): number | undefined {
  const count = Number(value);
  return allowedActivations.includes(count) ? count : undefined;
}

function expiresAfter(days: number | null): string | null {
  if (days === null) return null;
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
}

async function getAuthorizedAdmin(request: Request, client: ReturnType<typeof createClient>): Promise<User | null> {
  const authHeader = request.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) return null;

  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user || !data.user.email) return null;

  const allowlist = (Deno.env.get("ADMIN_EMAILS") ?? "")
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);

  if (!allowlist.includes(data.user.email.toLowerCase())) return null;
  return data.user;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply(405, { ok: false, message: "Use POST." });

  try {
    const url = Deno.env.get("SUPABASE_URL");
    if (!url) throw new Error("SUPABASE_URL is missing.");
    const admin = createClient(url, serviceKey(), {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const user = await getAuthorizedAdmin(request, admin);
    if (!user) {
      return reply(403, { ok: false, message: "Admin access denied. Sign in with an allowlisted admin email." });
    }

    let body: Record<string, unknown>;
    try {
      body = await request.json();
    } catch {
      return reply(400, { ok: false, message: "Request body must be valid JSON." });
    }

    const action = body.action;

    if (action === "create") {
      const label = typeof body.label === "string" ? body.label.trim().slice(0, 100) : "";
      const days = validDays(body.expiresInDays);
      const maxActivations = validActivationCount(body.maxActivations);
      if (days === undefined) return reply(400, { ok: false, message: "Choose 7, 30, 90, 365 days, or lifetime." });
      if (maxActivations === undefined) return reply(400, { ok: false, message: "Unsupported activation limit." });

      const key = generateLicenseKey();
      const keyHash = await hashKey(key);
      const { data, error } = await admin.from("isha_licenses").insert({
        key_hash: keyHash,
        key_prefix: key.split("-").slice(0, 2).join("-"),
        label,
        status: "active",
        expires_at: expiresAfter(days),
        max_activations: maxActivations,
        created_by: user.id,
      }).select("id, key_prefix, label, status, expires_at, max_activations, created_at, last_used_at").single();

      if (error) {
        console.error("License creation failed:", error.message);
        return reply(500, { ok: false, message: "Could not create license. Check the database migration." });
      }
      // Return the plaintext key only once; only its SHA-256 hash is stored.
      return reply(200, { ok: true, key, license: { ...data, activation_count: 0 } });
    }

    if (action === "list") {
      const { data: licenses, error } = await admin.from("isha_licenses")
        .select("id, key_prefix, label, status, expires_at, max_activations, created_at, last_used_at")
        .order("created_at", { ascending: false })
        .limit(250);
      if (error) {
        console.error("License list failed:", error.message);
        return reply(500, { ok: false, message: "Could not load licenses." });
      }

      const { data: activations, error: activationError } = await admin.from("isha_license_activations")
        .select("license_id");
      if (activationError) {
        console.error("Activation count query failed:", activationError.message);
        return reply(500, { ok: false, message: "Could not load activation counts." });
      }

      const counts = new Map<string, number>();
      for (const activation of activations ?? []) {
        counts.set(activation.license_id, (counts.get(activation.license_id) ?? 0) + 1);
      }
      return reply(200, {
        ok: true,
        licenses: (licenses ?? []).map((license) => ({
          ...license,
          activation_count: counts.get(license.id) ?? 0,
        })),
      });
    }

    if (action === "revoke") {
      const id = typeof body.id === "string" ? body.id : "";
      if (!id) return reply(400, { ok: false, message: "License id is required." });
      const { data, error } = await admin.from("isha_licenses")
        .update({ status: "revoked" })
        .eq("id", id)
        .select("id, key_prefix, status")
        .maybeSingle();
      if (error) return reply(500, { ok: false, message: "Could not revoke license." });
      if (!data) return reply(404, { ok: false, message: "License not found." });
      return reply(200, { ok: true, license: data, message: "License revoked." });
    }

    if (action === "renew") {
      const id = typeof body.id === "string" ? body.id : "";
      const days = validDays(body.days);
      if (!id) return reply(400, { ok: false, message: "License id is required." });
      if (days === undefined) return reply(400, { ok: false, message: "Choose 7, 30, 90, 365 days, or lifetime." });

      const { data, error } = await admin.from("isha_licenses")
        .update({ status: "active", expires_at: expiresAfter(days) })
        .eq("id", id)
        .select("id, key_prefix, status, expires_at")
        .maybeSingle();
      if (error) return reply(500, { ok: false, message: "Could not renew license." });
      if (!data) return reply(404, { ok: false, message: "License not found." });
      return reply(200, { ok: true, license: data, message: "License renewed." });
    }

    return reply(400, { ok: false, message: "Unknown admin action." });
  } catch (error) {
    console.error("Admin license service error:", error instanceof Error ? error.message : "unknown");
    return reply(500, { ok: false, message: "The admin license service is not configured correctly." });
  }
});
