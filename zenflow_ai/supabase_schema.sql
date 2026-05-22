-- ============================================================
-- ZenFlow AI — Supabase Schema (Production-Ready)
-- Run this in the Supabase SQL Editor to reset and recreate.
-- ============================================================

-- ── 0. Drop existing objects (idempotent) ───────────────────
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();
DROP TABLE IF EXISTS public.workout_logs CASCADE;
DROP TABLE IF EXISTS public.weekly_splits CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;

-- ── 1. Profiles ─────────────────────────────────────────────
-- NOTE: We use `user_id` (not `id`) so the Flutter query
--       `.eq('user_id', user.id)` works out of the box.
CREATE TABLE public.profiles (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id       UUID REFERENCES auth.users (id) ON DELETE CASCADE NOT NULL UNIQUE,
  email         TEXT,
  full_name     TEXT,
  weight_kg     FLOAT,
  height_cm     FLOAT,
  age           INTEGER,
  fitness_goal  TEXT,
  -- Stored as comma-separated string for simple Dart parsing
  health_conditions TEXT DEFAULT '',
  -- How many minutes per day the user can dedicate to yoga
  daily_minutes_available INTEGER DEFAULT 30,
  avatar_url    TEXT,
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- ── 2. Weekly Splits ─────────────────────────────────────────
CREATE TABLE public.weekly_splits (
  id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id        UUID REFERENCES auth.users (id) ON DELETE CASCADE NOT NULL,
  created_at     TIMESTAMPTZ DEFAULT now() NOT NULL,
  start_date     DATE NOT NULL,
  end_date       DATE NOT NULL,
  status_tracking JSONB DEFAULT '{}',
  split_data     JSONB NOT NULL DEFAULT '[]'
);

-- ── 3. Workout Logs ──────────────────────────────────────────
CREATE TABLE public.workout_logs (
  id               UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id          UUID REFERENCES auth.users (id) ON DELETE CASCADE NOT NULL,
  split_id         UUID REFERENCES public.weekly_splits (id) ON DELETE SET NULL,
  workout_date     DATE NOT NULL DEFAULT CURRENT_DATE,
  started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at     TIMESTAMPTZ,
  duration_minutes INTEGER DEFAULT 0,
  calories_burned  INTEGER DEFAULT 0,
  posture_score_avg FLOAT DEFAULT 0.0,
  performance_data JSONB DEFAULT '{}',
  notes            TEXT DEFAULT NULL
);

-- Index for fast per-user dashboard queries
CREATE INDEX idx_workout_logs_user_date
  ON public.workout_logs (user_id, workout_date DESC);

-- ── 4. Enable Row Level Security ─────────────────────────────
ALTER TABLE public.profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_splits  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_logs   ENABLE ROW LEVEL SECURITY;

-- ── 5. RLS Policies — profiles ───────────────────────────────
CREATE POLICY "profiles: select own"
  ON public.profiles FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "profiles: insert own"
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "profiles: update own"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "profiles: delete own"
  ON public.profiles FOR DELETE
  USING (auth.uid() = user_id);

-- ── 6. RLS Policies — weekly_splits ──────────────────────────
CREATE POLICY "splits: select own"
  ON public.weekly_splits FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "splits: insert own"
  ON public.weekly_splits FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "splits: update own"
  ON public.weekly_splits FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "splits: delete own"
  ON public.weekly_splits FOR DELETE
  USING (auth.uid() = user_id);

-- ── 7. RLS Policies — workout_logs ───────────────────────────
CREATE POLICY "logs: select own"
  ON public.workout_logs FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "logs: insert own"
  ON public.workout_logs FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "logs: update own"
  ON public.workout_logs FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "logs: delete own"
  ON public.workout_logs FOR DELETE
  USING (auth.uid() = user_id);

-- ── 8. Trigger: auto-create profile on user sign-up ──────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (user_id, email)
  VALUES (
    new.id,
    new.email           -- populated from auth.users
  )
  ON CONFLICT (user_id) DO NOTHING; -- safe for re-runs
  RETURN new;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE PROCEDURE public.handle_new_user();
