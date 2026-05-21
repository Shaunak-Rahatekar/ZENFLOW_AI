-- Profiles table
CREATE TABLE profiles (
  id UUID REFERENCES auth.users NOT NULL PRIMARY KEY,
  updated_at TIMESTAMP WITH TIME ZONE,
  health_data JSONB, -- stores height, weight, goals, medical conditions
  first_name TEXT,
  last_name TEXT,
  avatar_url TEXT
);

-- Weekly Splits table
CREATE TABLE weekly_splits (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES profiles(id) NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  status_tracking JSONB, -- stores daily completion status
  split_data JSONB NOT NULL -- stores the AI generated workout split details
);

-- Workout Logs table
CREATE TABLE workout_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES profiles(id) NOT NULL,
  split_id UUID REFERENCES weekly_splits(id),
  workout_date DATE NOT NULL,
  started_at TIMESTAMP WITH TIME ZONE NOT NULL,
  completed_at TIMESTAMP WITH TIME ZONE,
  duration_minutes INTEGER,
  calories_burned INTEGER,
  posture_score_avg FLOAT,
  performance_data JSONB,
  notes TEXT
);

-- Enable RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_splits ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_logs ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Users can view own splits" ON weekly_splits FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own splits" ON weekly_splits FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own splits" ON weekly_splits FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can view own logs" ON workout_logs FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own logs" ON workout_logs FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own logs" ON workout_logs FOR UPDATE USING (auth.uid() = user_id);
