// @ts-nocheck — Deno runtime types are not available in VS Code without deno.json config.
// This file runs correctly on Supabase Edge Functions (Deno runtime).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// ── Full pose catalogue ───────────────────────────────────────────────────────
// Each entry: id, category, difficulty, default duration (seconds), contraindication keywords.
// The local catalogue is used ONLY for safety filtering before Gemini sees the list.
const POSE_CATALOGUE = [
  // Warm-up
  { id: "sukhasana",               category: "warmup",      difficulty: "beginner",     duration: 60,  avoid: [] },
  { id: "marjaryasana_bitilasana", category: "warmup",      difficulty: "beginner",     duration: 45,  avoid: ["wrist injury"] },
  // Standing
  { id: "tadasana",                category: "standing",    difficulty: "beginner",     duration: 30,  avoid: ["severe headaches", "low blood pressure", "insomnia"] },
  { id: "uttanasana",              category: "standing",    difficulty: "beginner",     duration: 45,  avoid: ["back injury", "lower back pain", "low blood pressure"] },
  { id: "prasarita_padottanasana", category: "standing",    difficulty: "beginner",     duration: 45,  avoid: ["lower back pain", "back injury"] },
  { id: "trikonasana",             category: "standing",    difficulty: "intermediate", duration: 45,  avoid: ["low blood pressure", "diarrhea", "headache"] },
  { id: "parsvakonasana",          category: "standing",    difficulty: "intermediate", duration: 45,  avoid: ["high blood pressure", "neck problems"] },
  { id: "virabhadrasana_i",        category: "standing",    difficulty: "intermediate", duration: 45,  avoid: ["high blood pressure", "heart problems", "shoulder injuries"] },
  { id: "virabhadrasana_ii",       category: "standing",    difficulty: "intermediate", duration: 45,  avoid: ["diarrhea", "high blood pressure", "neck problems"] },
  // Balance
  { id: "vrikshasana",             category: "balance",     difficulty: "beginner",     duration: 45,  avoid: ["high blood pressure", "insomnia", "migraine", "knee pain", "knee injuries"] },
  { id: "garudasana",              category: "balance",     difficulty: "intermediate", duration: 45,  avoid: ["knee pain", "knee injuries"] },
  { id: "virabhadrasana_iii",      category: "balance",     difficulty: "advanced",     duration: 30,  avoid: ["high blood pressure", "leg injury"] },
  { id: "ardha_chandrasana",       category: "balance",     difficulty: "advanced",     duration: 45,  avoid: ["low blood pressure", "headache", "diarrhea"] },
  { id: "natarajasana",            category: "balance",     difficulty: "advanced",     duration: 45,  avoid: ["low blood pressure", "back injury", "lower back pain"] },
  // Strength
  { id: "phalakasana",             category: "strength",    difficulty: "intermediate", duration: 30,  avoid: ["carpal tunnel syndrome", "wrist injury", "shoulder injury"] },
  { id: "utkatasana",              category: "strength",    difficulty: "intermediate", duration: 30,  avoid: ["knee pain", "knee injuries", "low blood pressure", "headache"] },
  { id: "navasana",                category: "strength",    difficulty: "intermediate", duration: 30,  avoid: ["low blood pressure", "diarrhea", "headache", "pregnancy", "neck injury"] },
  { id: "setu_bandhasana",         category: "strength",    difficulty: "beginner",     duration: 45,  avoid: ["neck injury", "shoulder injury"] },
  { id: "shalabhasana",            category: "strength",    difficulty: "beginner",     duration: 30,  avoid: ["pregnancy", "back injury"] },
  // Flexibility
  { id: "adho_mukha_svanasana",    category: "flexibility", difficulty: "beginner",     duration: 45,  avoid: ["carpal tunnel syndrome", "high blood pressure", "late pregnancy"] },
  { id: "bhujangasana",            category: "flexibility", difficulty: "beginner",     duration: 30,  avoid: ["pregnancy", "recent abdominal surgery", "carpal tunnel syndrome", "back pain", "lower back pain"] },
  { id: "anjaneyasana",            category: "flexibility", difficulty: "beginner",     duration: 45,  avoid: ["knee pain", "knee injuries"] },
  { id: "paschimottanasana",       category: "flexibility", difficulty: "beginner",     duration: 60,  avoid: ["asthma", "diarrhea", "back injury", "lower back pain"] },
  { id: "baddha_konasana",         category: "flexibility", difficulty: "beginner",     duration: 60,  avoid: ["groin injury", "knee injury", "knee pain"] },
  { id: "gomukhasana",             category: "flexibility", difficulty: "intermediate", duration: 60,  avoid: ["knee pain", "knee injuries", "hip injury"] },
  { id: "dhanurasana",             category: "flexibility", difficulty: "intermediate", duration: 30,  avoid: ["back injury", "lower back pain", "neck injury", "pregnancy", "high blood pressure"] },
  { id: "ustrasana",               category: "flexibility", difficulty: "intermediate", duration: 30,  avoid: ["high blood pressure", "low blood pressure", "migraine", "back injury", "lower back pain", "neck injury"] },
  // Relaxation
  { id: "balasana",                category: "relaxation",  difficulty: "beginner",     duration: 60,  avoid: ["knee injuries", "knee pain", "pregnancy", "diarrhea"] },
  { id: "supta_matsyendrasana",    category: "relaxation",  difficulty: "beginner",     duration: 60,  avoid: ["hip replacement", "spinal disc issues"] },
  { id: "ananda_balasana",         category: "relaxation",  difficulty: "beginner",     duration: 60,  avoid: ["pregnancy", "knee injury"] },
  { id: "viparita_karani",         category: "relaxation",  difficulty: "beginner",     duration: 90,  avoid: ["glaucoma", "high blood pressure", "menstruation"] },
  { id: "savasana",                category: "relaxation",  difficulty: "beginner",     duration: 90,  avoid: [] },
];

// ── Normalise condition strings for matching ──────────────────────────────────
function normaliseCondition(s: string): string {
  return s.toLowerCase().trim()
    .replace(/\s+/g, " ")
    .replace(/\bback pain\b/g, "lower back pain")
    .replace(/\bhypertension\b/g, "high blood pressure")
    .replace(/\barthritis\b/g, "knee pain")
    .replace(/\bobesity\b/g, "obesity");
}

// ── Filter poses that are safe for this user ──────────────────────────────────
function getSafePoses(conditionsRaw: string, weightKg: number, age: number) {
  const userConditions = conditionsRaw
    .split(",")
    .map(normaliseCondition)
    .filter(Boolean);

  const isHeavy = weightKg > 80;
  const isSenior = age >= 60;

  return POSE_CATALOGUE.filter((pose) => {
    for (const avoid of pose.avoid) {
      if (userConditions.some((c) => c.includes(avoid) || avoid.includes(c))) {
        return false;
      }
    }
    if (isHeavy && pose.difficulty === "advanced") return false;
    if (isHeavy && ["utkatasana", "navasana", "dhanurasana"].includes(pose.id)) return false;
    if (isSenior && pose.difficulty === "advanced") return false;
    return true;
  });
}

// ── Duration targets by time budget ──────────────────────────────────────────
// Each pose holds for `duration` seconds + ~15s rest between poses.
// We target filling 90% of the session time.
function calcTargetPoses(dailyMinutes: number): { count: number; avgDuration: number } {
  const totalSeconds = dailyMinutes * 60 * 0.90;
  // Average pose+rest cycle. Shorter sessions use shorter holds.
  let avgPoseDuration: number;
  if (dailyMinutes <= 15)      avgPoseDuration = 25; // 25s hold + 15s rest = 40s/pose
  else if (dailyMinutes <= 25) avgPoseDuration = 35; // 35s hold + 15s rest = 50s/pose
  else if (dailyMinutes <= 40) avgPoseDuration = 45; // 45s hold + 15s rest = 60s/pose
  else if (dailyMinutes <= 55) avgPoseDuration = 55; // 55s hold + 15s rest = 70s/pose
  else                         avgPoseDuration = 65; // 65s hold + 15s rest = 80s/pose

  const cycleSeconds = avgPoseDuration + 15;
  const count = Math.max(4, Math.min(35, Math.round(totalSeconds / cycleSeconds)));
  return { count, avgDuration: avgPoseDuration };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { user_id } = await req.json();
    if (!user_id) throw new Error("Missing user_id");

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ── Fetch user profile ────────────────────────────────────────────────
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("health_conditions, fitness_goal, weight_kg, height_cm, age, daily_minutes_available")
      .eq("user_id", user_id)
      .single();

    if (profileError || !profile) {
      throw new Error(`Profile not found: ${profileError?.message}`);
    }

    const conditionsRaw: string = profile.health_conditions || "";
    const goal: string = profile.fitness_goal || "General Fitness";
    const weightKg: number = profile.weight_kg ?? 70;
    const heightCm: number = profile.height_cm ?? 170;
    const age: number = profile.age ?? 30;
    const dailyMinutes: number = profile.daily_minutes_available ?? 30;

    // ── Step 1: Safety filter (local, deterministic) ──────────────────────
    // We filter unsafe poses BEFORE sending to Gemini so it cannot accidentally
    // include contraindicated poses regardless of how it interprets the prompt.
    const safePoses = getSafePoses(conditionsRaw, weightKg, age);

    if (safePoses.length < 4) {
      throw new Error("Not enough safe poses for this user's health profile. Please review health conditions.");
    }

    // ── Step 2: Calculate duration targets ────────────────────────────────
    const { count: targetPosesPerDay, avgDuration } = calcTargetPoses(dailyMinutes);

    // ── Step 3: Build safe pose list for Gemini ───────────────────────────
    const safePoseList = safePoses
      .map((p) => `  - ${p.id} (${p.category}, ${p.difficulty}, default ${p.duration}s)`)
      .join("\n");

    const safeIds = safePoses.map((p) => p.id);

    // ── Step 4: Build Gemini prompt ───────────────────────────────────────
    const prompt = `
You are a certified Yoga Instructor and Wellness AI creating a personalised 7-day yoga programme.

USER PROFILE:
- Age: ${age} years
- Weight: ${weightKg} kg
- Height: ${heightCm} cm
- Health Conditions: ${conditionsRaw || "None"}
- Fitness Goal: ${goal}
- Daily Time Available: ${dailyMinutes} minutes per session

SESSION TIMING REQUIREMENTS (CRITICAL — you must follow these exactly):
- Each daily session must fill approximately ${dailyMinutes} minutes of practice time.
- Target ${targetPosesPerDay} poses per active day (Days 1, 2, 3, 5, 6).
- Each pose should be held for approximately ${avgDuration} seconds (you may vary ±15s based on difficulty).
- There is a ~15 second rest between each pose.
- Total time per session = sum of (pose_duration + 15s rest) ≈ ${dailyMinutes} minutes.
- Days 4 and 7 are rest/recovery days: use only 2–3 gentle relaxation poses.

SAFE POSES FOR THIS USER (pre-filtered for their health conditions — use ONLY these IDs):
${safePoseList}

GOAL-SPECIFIC GUIDANCE:
${goal.toLowerCase().includes("weight") || goal.toLowerCase().includes("fat")
  ? "- Fat Loss: Prioritise active standing sequences, Warriors, Chair, Plank. Keep transitions flowing."
  : goal.toLowerCase().includes("flex")
  ? "- Flexibility: Prioritise forward folds, hip openers, seated stretches. Longer holds (60–90s)."
  : goal.toLowerCase().includes("stress") || goal.toLowerCase().includes("relief")
  ? "- Stress Relief: Prioritise restorative and relaxation poses. Gentle flow. Longer holds."
  : goal.toLowerCase().includes("strength") || goal.toLowerCase().includes("muscle")
  ? "- Strength: Prioritise Plank, Chair, Warrior sequences, Boat. Shorter holds with more reps."
  : "- General Fitness: Balanced mix of standing, flexibility, balance, and relaxation."}

HEALTH CONDITION ADAPTATIONS:
${conditionsRaw
  ? `The user has: ${conditionsRaw}. The safe pose list above already excludes contraindicated poses.
  Additionally:
  - If knee pain: prefer seated and supine poses, avoid deep lunges.
  - If lower back pain: avoid deep forward folds, prefer Cat-Cow and Bridge.
  - If obesity/heavy build: prefer seated, supine, and supported standing poses.
  - If senior (age 60+): prioritise balance, mobility, and joint-safe poses.`
  : "No health restrictions — full pose variety available."}

VARIETY RULES:
- Vary the sequence each day — do not repeat the same daily plan.
- Each active day should follow this structure: warmup → main sequence → relaxation.
- Distribute pose categories across the week (don't cluster all balance poses on one day).

OUTPUT FORMAT (STRICT):
Return ONLY a valid JSON array of 7 arrays. Each inner array contains pose ID strings.
Example format: [["sukhasana","tadasana","balasana"],["sukhasana","virabhadrasana_i","savasana"],...]
- No markdown, no explanation, no code blocks — raw JSON only.
- Every pose ID must be from the safe pose list above.
- Active days must have exactly ${targetPosesPerDay} poses.
- Rest days (day 4 and day 7) must have 2–3 relaxation poses only.
`;

    // ── Step 5: Call Gemini with fallback chain ───────────────────────────
    const geminiApiKey = (Deno.env.get("GEMINI_API_KEY") || "").trim();
    if (!geminiApiKey) throw new Error("Missing GEMINI_API_KEY");

    const primaryModel = (Deno.env.get("GEMINI_MODEL") || "gemini-2.0-flash").trim();
    const fallbackModels = ["gemini-2.0-flash", "gemini-1.5-flash", "gemini-2.5-flash"];
    const modelsToTry = [...new Set([primaryModel, ...fallbackModels])];

    let geminiRes: Response | null = null;
    let lastError: Error | null = null;

    for (const model of modelsToTry) {
      try {
        console.log(`[generate_workout] Trying model: ${model}`);
        const res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${geminiApiKey}`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              contents: [{ parts: [{ text: prompt }] }],
              generationConfig: {
                response_mime_type: "application/json",
                response_schema: {
                  type: "ARRAY",
                  items: {
                    type: "ARRAY",
                    items: {
                      type: "STRING"
                    }
                  }
                },
                temperature: 0.7,
                maxOutputTokens: 8192,
              },
            }),
          }
        );

        if (res.ok) {
          geminiRes = res;
          console.log(`[generate_workout] Success with model: ${model}`);
          break;
        } else {
          const errText = await res.text();
          console.warn(`[generate_workout] Model ${model} failed (${res.status}): ${errText}`);
          lastError = new Error(`Model ${model} HTTP ${res.status}`);
        }
      } catch (err) {
        console.warn(`[generate_workout] Model ${model} threw:`, err);
        lastError = err instanceof Error ? err : new Error(String(err));
      }
    }

    if (!geminiRes) {
      throw new Error(`All Gemini models failed. Last error: ${lastError?.message}`);
    }

    // ── Step 6: Parse and validate Gemini response ────────────────────────
    const geminiData = await geminiRes.json();
    const rawText: string = geminiData?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";

    if (!rawText) {
      throw new Error("Gemini returned an empty response.");
    }

    // Extract JSON array — handles cases where Gemini wraps in markdown or adds text
    const jsonMatch = rawText.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      throw new Error(`Could not extract JSON from Gemini response: ${rawText.slice(0, 200)}`);
    }

    let splitArray: string[][];
    try {
      splitArray = JSON.parse(jsonMatch[0]);
    } catch (e) {
      throw new Error(`Failed to parse Gemini JSON: ${e}`);
    }

    // Validate structure
    if (!Array.isArray(splitArray) || splitArray.length !== 7) {
      throw new Error(`Expected 7-day array, got ${splitArray?.length ?? "invalid"} days.`);
    }

    // ── Step 7: Sanitise — remove any pose IDs Gemini hallucinated ───────
    // This is the safety net: even if Gemini ignores the safe list, we strip bad IDs.
    const sanitised = splitArray.map((day, i) => {
      if (!Array.isArray(day)) return ["balasana"];
      const cleaned = day.filter((id) => typeof id === "string" && safeIds.includes(id));
      // If Gemini returned nothing valid for this day, use a fallback
      if (cleaned.length === 0) {
        return i === 3 || i === 6 ? ["balasana", "savasana"] : ["sukhasana", "tadasana", "balasana"];
      }
      return cleaned;
    });

    // ── Step 8: Save to Supabase ──────────────────────────────────────────
    const startDate = new Date();
    const endDate = new Date(startDate);
    endDate.setDate(startDate.getDate() + 6);

    const statusTracking = Array.from({ length: 7 }, (_, i) => ({
      day: i + 1,
      status: "pending",
    }));

    const { data: splitResult, error: splitInsertError } = await supabase
      .from("weekly_splits")
      .insert({
        user_id,
        start_date: startDate.toISOString().split("T")[0],
        end_date: endDate.toISOString().split("T")[0],
        status_tracking: statusTracking,
        split_data: sanitised,
      })
      .select()
      .single();

    if (splitInsertError) {
      throw new Error(`Failed to save split: ${splitInsertError.message}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        split: splitResult,
        meta: {
          poses_per_active_day: targetPosesPerDay,
          avg_pose_duration_seconds: avgDuration,
          safe_poses_available: safePoses.length,
          daily_minutes: dailyMinutes,
        },
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  } catch (error) {
    console.error("[generate_workout] Error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
    );
  }
});
