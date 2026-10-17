-- Controlled, idempotent seed for the original Challenge Arena template library.
-- No user accounts or group challenges are created by this script.
insert into public.challenge_templates (
  title, instructions, category, difficulty, points, duration_minutes,
  completion_method, safety_notes
)
select seed.title, seed.instructions, seed.category::public.challenge_category,
       seed.difficulty::public.challenge_difficulty, seed.points, seed.duration_minutes,
       seed.completion_method::public.completion_method, seed.safety_notes
from (values
  ('Three Clues, One Place', 'Solve the short riddle: I have a campus address but no building, a center but no walls, and a map but no roads. Name the place and explain your reasoning in one sentence.', 'brain', 'easy', 20, 5, 'text', null),
  ('One-Minute Memory Map', 'Look around a room for one minute, then look away. Write down ten distinct objects you remember and one detail about where each was.', 'brain', 'easy', 25, 8, 'text', null),
  ('The Number Ladder', 'Find the next two numbers and explain the pattern: 2, 6, 12, 20, 30, __, __. Your answer must include the rule, not only the numbers.', 'brain', 'medium', 35, 10, 'text', null),
  ('Question-Master Mini Quiz', 'Write five original general-knowledge questions, answer them privately, then ask a willing friend to try them. Share the questions and answer key with your group.', 'brain', 'medium', 40, 15, 'text', 'Keep every question light and non-personal; skip anything about health, identity, or private life.'),
  ('Campus Step Loop', 'Take a relaxed 15-minute walk on a familiar, public, accessible route. Return and share one thing you noticed. No pace or distance target.', 'physical', 'easy', 25, 20, 'confirmation', 'Choose a safe route and comfortable pace; skip or stop if the weather, surroundings, or your body feels unsafe.'),
  ('Supported Balance Pause', 'Near a wall or sturdy chair, balance on one foot for up to 20 seconds per side. Use support whenever you want; the goal is a calm attempt, not a record.', 'physical', 'easy', 20, 4, 'confirmation', 'Stay on the floor with support within reach. Stop if dizzy or uncomfortable; sitting is an equally valid alternative.'),
  ('Desk-Side Stretch Reset', 'Take three minutes for gentle shoulder rolls, wrist circles, and a comfortable seated or standing stretch. Share which movement helped you relax.', 'physical', 'easy', 20, 5, 'confirmation', 'Use a pain-free range of motion and do not force any stretch. Stop if you feel pain or dizziness.'),
  ('Paper-Cup Rhythm', 'Using an empty paper cup or simply tapping a desk, create a four-beat rhythm and repeat it three times without rushing.', 'physical', 'easy', 25, 6, 'confirmation', 'Use a light, stable surface and a soft or empty object; do not use glass or hit anyone.'),
  ('Scrap-Paper Bridge', 'Fold one sheet of scrap paper into a bridge between two books. See how many coins it can hold for five seconds, then share your design and count.', 'problem-solving', 'medium', 40, 15, 'text', 'Use only light coins, keep the bridge close to the table, and do not place heavy objects on it.'),
  ('Find the Tiny Bug', 'In a short code snippet you write yourself, deliberately add one simple error. Swap snippets with a willing teammate and explain the fix without running unknown code.', 'problem-solving', 'medium', 45, 15, 'text', 'Use your own harmless sample code only; never run code from an untrusted source.'),
  ('Route Planner', 'Plan a route that visits the library, a cafe, and a lecture hall with the least backtracking. Use an imaginary 5-by-5 grid and explain your approach.', 'problem-solving', 'medium', 35, 12, 'text', null),
  ('Pattern Tiles', 'Write a 4-by-4 grid of symbols with exactly one symbol repeated in every row and column. Share the grid and explain how you checked it.', 'problem-solving', 'hard', 50, 20, 'text', null),
  ('Tiny Campus Postcard', 'Draw a postcard-sized sketch of a familiar campus corner using only five shapes. Add a short title and share the drawing or describe it.', 'creativity', 'easy', 25, 12, 'evidence', 'Do not photograph people, screens, or private documents without permission; a written description is also acceptable.'),
  ('Six-Word Story', 'Write a complete story in exactly six words. Share the six words and, if you like, one sentence about the story behind them.', 'creativity', 'easy', 20, 8, 'text', null),
  ('Everyday Object, New Job', 'Choose a common object nearby and invent three safe, useful alternative uses. Do not damage, ingest, or misuse the object.', 'creativity', 'easy', 25, 10, 'text', 'Keep ideas safe, legal, and respectful; do not use another person’s belongings without permission.'),
  ('Micro-Poem from a Sound', 'Listen to an ordinary sound for a few seconds and write a four-line poem inspired by it. Share the poem, not a recording of other people.', 'creativity', 'medium', 30, 12, 'text', 'Avoid recording conversations or identifiable people without consent.'),
  ('Tongue-Twister Take Three', 'Say “Red lorry, yellow lorry” three times at a comfortable pace. Share how many clear tries you managed; a text-only attempt is fine.', 'social', 'easy', 20, 4, 'confirmation', 'No recording is required. Do not pressure anyone to perform or share a clip.'),
  ('A Specific Thank-You', 'Write a short, sincere thank-you for something someone willingly did. Share the message only if they are comfortable with it; otherwise describe the gesture without naming them.', 'social', 'easy', 25, 8, 'text', 'Do not post private messages, names, or personal details without permission.'),
  ('Would You Rather: Cozy Edition', 'Ask a willing friend one harmless choice, such as “sunrise study or late-night study?” Share the question and your own answer; no friend’s name is needed.', 'social', 'easy', 20, 5, 'text', 'Keep it light and optional. Avoid personal, sensitive, romantic, or embarrassing questions.'),
  ('Silent Charades: Everyday Edition', 'Act out an everyday object or activity for a willing friend to guess. Share the prompt and whether it was guessed; a written version is acceptable.', 'social', 'easy', 25, 8, 'confirmation', 'No filming, touching, pranks, or public disturbance. Participation must be voluntary.')
) as seed(title, instructions, category, difficulty, points, duration_minutes, completion_method, safety_notes)
where not exists (
  select 1 from public.challenge_templates existing where existing.title = seed.title
);
