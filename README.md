# solstice-quiz

Live party quiz: players join on their phones, the host runs it from `?host=1`,
and `?present=1` shows questions and a live leaderboard on a big screen.

## Reusing for a new quiz
1. Edit `QUESTIONS` (and `TIERS`) in `index.html`. Mark a bonus question with `bonus: true`.
   Do **not** put the correct answers in this file — the repo is public.
2. Put the correct answers in Supabase: Table Editor → `quiz_answers`
   (one row per question: `question` = 1, 2, 3…, `answer` = A/B/C/D). Delete any extra rows.
3. Clear old players from the host screen before the quiz starts.
4. New Supabase project: run `supabase/setup.sql` in the SQL Editor,
   follow the dashboard steps at the top of that file, and update `SUPABASE_URL`/`SUPABASE_KEY`.

## Security model
- The anon key in `index.html` is public by design. Access is enforced by the
  Row Level Security policies in `supabase/setup.sql`.
- Players get an anonymous session and can only edit their own unfinished entry.
- Scores are calculated by the database when a player submits, against the hidden
  `quiz_answers` table. Players can't see the key, each other's picks, or a score before submitting.
- Hosts sign in with Supabase Auth and must be listed in `quiz_hosts`. Only
  hosts can clear the board or drive the presentation channel.
- Never put the `service_role` key, or any password, in this repo.
