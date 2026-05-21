import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { user_id } = await req.json();

    if (!user_id) {
      throw new Error("Missing user_id");
    }

    // Initialize Supabase Client
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Fetch user health data
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("health_conditions, fitness_goal")
      .eq("user_id", user_id)
      .single();

    if (profileError || !profile) {
      throw new Error(`Profile not found: ${profileError?.message}`);
    }

    const conditions = profile.health_conditions || "";
    const goals = profile.fitness_goal ? [profile.fitness_goal] : [];

    // Prompt for Gemini 1.5 Flash
    const prompt = `
      You are an expert Yoga Instructor. Create a 7-day workout split for a user.
      User Health Conditions: ${conditions || "None"}
      User Goals: ${goals.join(", ") || "General fitness"}
      
      Available Asanas in Registry:
      1. Tadasana (Mountain Pose) - Avoid if: severe headaches, low blood pressure, insomnia.
      2. Adho Mukha Svanasana (Downward Dog) - Avoid if: carpal tunnel, high blood pressure.
      3. Vrikshasana (Tree Pose) - Avoid if: high blood pressure, insomnia, migraine, knee pain.
      4. Virabhadrasana I (Warrior 1) - Avoid if: high blood pressure, heart problems, shoulder injuries.
      5. Virabhadrasana II (Warrior 2) - Avoid if: diarrhea, high blood pressure, neck problems.
      6. Trikonasana (Triangle Pose) - Avoid if: low blood pressure, diarrhea, headache.
      7. Bhujangasana (Cobra Pose) - Avoid if: pregnancy, recent abdominal surgery, carpal tunnel.
      8. Balasana (Child's Pose) - Avoid if: knee injuries, pregnancy, diarrhea.
      9. Paschimottanasana (Seated Forward Bend) - Avoid if: asthma, diarrhea, back injury.
      10. Uttanasana (Standing Forward Bend) - Avoid if: back injury, low blood pressure.

      Rules:
      1. NEVER include an asana if the user has a contraindicating condition.
      2. Output strictly as a JSON array of 7 arrays (one for each day).
      3. Each inner array should contain the string IDs of the asanas (e.g. "tadasana", "balasana").
      4. Each day should have 3-5 asanas. Rest days can be an empty array or just gentle poses like "balasana".

      Respond ONLY with valid JSON.
    `;

    const geminiApiKey = (Deno.env.get("GEMINI_API_KEY") || "").trim();
    if (!geminiApiKey) {
      throw new Error("Missing GEMINI_API_KEY");
    }

    // Default to gemini-3.1-flash-lite, with robust fallbacks
    const primaryModel = (Deno.env.get("GEMINI_MODEL") || "gemini-3.1-flash-lite").trim();
    const fallbackModels = ["gemini-3.1-flash-lite", "gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-flash"];
    const modelsToTry = [...new Set([primaryModel, ...fallbackModels])];

    let geminiRes: Response | null = null;
    let lastError: Error | null = null;
    let usedModel = "";

    for (const model of modelsToTry) {
      try {
        console.log(`Attempting workout generation with model: ${model}`);
        const res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${geminiApiKey}`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              contents: [{ parts: [{ text: prompt }] }],
              generationConfig: { response_mime_type: "application/json" }
            }),
          }
        );

        if (res.ok) {
          geminiRes = res;
          usedModel = model;
          console.log(`Successfully generated workout using model: ${model}`);
          break;
        } else {
          const errorText = await res.text();
          console.warn(`Model ${model} failed with status ${res.status}: ${errorText}`);
          lastError = new Error(`Model ${model} status ${res.status}: ${errorText}`);
        }
      } catch (err) {
        console.warn(`Failed to fetch from model ${model}:`, err);
        lastError = err instanceof Error ? err : new Error(String(err));
      }
    }

    if (!geminiRes) {
      throw new Error(`All Gemini models failed. Last error: ${lastError?.message}`);
    }

    const geminiData = await geminiRes.json();
    let rawText = geminiData.candidates[0].content.parts[0].text;

    // Extract JSON array using regex to prevent parsing errors if Gemini adds conversational text
    const jsonMatch = rawText.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      throw new Error(`Failed to extract JSON from Gemini response: ${rawText}`);
    }
    const splitArray = JSON.parse(jsonMatch[0]);

    const startDate = new Date();
    const endDate = new Date(startDate);
    endDate.setDate(startDate.getDate() + 6);

    const statusTracking = [
      { day: 1, status: "pending" },
      { day: 2, status: "pending" },
      { day: 3, status: "pending" },
      { day: 4, status: "pending" },
      { day: 5, status: "pending" },
      { day: 6, status: "pending" },
      { day: 7, status: "pending" },
    ];

    // Insert into weekly_splits
    const { data: splitResult, error: splitInsertError } = await supabase
      .from("weekly_splits")
      .insert({
        user_id: user_id,
        start_date: startDate.toISOString().split("T")[0],
        end_date: endDate.toISOString().split("T")[0],
        status_tracking: statusTracking,
        split_data: splitArray,
      })
      .select()
      .single();

    if (splitInsertError) {
      throw new Error(`Failed to save split: ${splitInsertError.message}`);
    }

    return new Response(JSON.stringify({ success: true, split: splitResult }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
