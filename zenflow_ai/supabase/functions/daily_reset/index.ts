import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

serve(async (req) => {
  try {
    // Initialize Supabase Client
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get "yesterday" date string (since this runs at midnight)
    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    const yesterdayStr = yesterday.toISOString().split("T")[0];

    // Fetch active weekly splits
    const { data: splits, error: fetchError } = await supabase
      .from("weekly_splits")
      .select("*")
      .lte("start_date", yesterdayStr)
      .gte("end_date", yesterdayStr);

    if (fetchError) {
      throw fetchError;
    }

    let updatedCount = 0;

    for (const split of splits || []) {
      // Check if a workout log exists for yesterday
      const { data: logs, error: logError } = await supabase
        .from("workout_logs")
        .select("id")
        .eq("split_id", split.id)
        .eq("workout_date", yesterdayStr);

      if (logError) {
        console.error(`Error fetching logs for split ${split.id}`, logError);
        continue;
      }

      const didWorkout = logs && logs.length > 0;

      if (!didWorkout) {
        // User skipped yesterday's workout.
        // We push the end_date forward by 1 day and update status_tracking
        const newEndDate = new Date(split.end_date);
        newEndDate.setDate(newEndDate.getDate() + 1);

        const newStatusTracking = [...(split.status_tracking || [])];
        // Insert a 'skipped' marker for yesterday to push the schedule
        newStatusTracking.push({
          skipped_date: yesterdayStr,
          status: "skipped",
          note: "Midnight reset pushed split forward"
        });

        const { error: updateError } = await supabase
          .from("weekly_splits")
          .update({
            end_date: newEndDate.toISOString().split("T")[0],
            status_tracking: newStatusTracking
          })
          .eq("id", split.id);

        if (!updateError) {
          updatedCount++;
        }
      }
    }

    return new Response(JSON.stringify({ success: true, updated_splits: updatedCount }), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});
