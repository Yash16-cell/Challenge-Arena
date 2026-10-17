-- Challenge Arena schema for Supabase PostgreSQL.
-- Apply in order with `supabase db push` or paste into the Supabase SQL editor.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

do $$ begin
  create type public.challenge_category as enum ('brain', 'physical', 'problem-solving', 'creativity', 'social');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.challenge_difficulty as enum ('easy', 'medium', 'hard');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.completion_method as enum ('confirmation', 'text', 'evidence');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.assignment_status as enum ('not-started', 'in-progress', 'submitted', 'approved', 'rejected', 'expired', 'cancelled');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.member_role as enum ('owner', 'member');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.report_target_type as enum ('challenge', 'submission', 'user');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.report_status as enum ('pending', 'reviewed', 'dismissed');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_length check (char_length(username) between 3 and 24),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 48),
  constraint profiles_username_format check (username ~ '^[a-zA-Z0-9_]+$'),
  constraint profiles_avatar_url_length check (avatar_url is null or char_length(avatar_url) <= 500)
);
create unique index if not exists profiles_username_lower_unique on public.profiles (lower(username));

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint groups_name_length check (char_length(name) between 2 and 48),
  constraint groups_description_length check (description is null or char_length(description) <= 240)
);
create index if not exists groups_owner_id_idx on public.groups(owner_id);

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.member_role not null default 'member',
  joined_at timestamptz not null default now(),
  constraint memberships_group_user_unique unique (group_id, user_id)
);
create index if not exists memberships_user_id_idx on public.memberships(user_id, group_id);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  max_uses integer not null default 100,
  use_count integer not null default 0,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint invitations_positive_uses check (max_uses between 1 and 1000),
  constraint invitations_use_count_check check (use_count between 0 and max_uses)
);
create index if not exists invitations_group_id_idx on public.invitations(group_id);

create table if not exists public.challenge_templates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  instructions text not null,
  category public.challenge_category not null,
  difficulty public.challenge_difficulty not null,
  points integer not null,
  duration_minutes integer not null,
  completion_method public.completion_method not null,
  safety_notes text,
  created_at timestamptz not null default now(),
  constraint challenge_templates_points check (points between 5 and 500),
  constraint challenge_templates_duration check (duration_minutes between 1 and 1440),
  constraint challenge_templates_title_length check (char_length(title) between 3 and 100),
  constraint challenge_templates_instructions_length check (char_length(instructions) between 10 and 3000)
);

create table if not exists public.challenges (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  creator_id uuid not null references public.profiles(id) on delete restrict,
  template_id uuid references public.challenge_templates(id) on delete set null,
  title text not null,
  instructions text not null,
  category public.challenge_category not null,
  difficulty public.challenge_difficulty not null,
  points integer not null,
  duration_minutes integer not null,
  completion_method public.completion_method not null,
  safety_notes text,
  deadline timestamptz,
  max_attempts integer not null default 3,
  is_cancelled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint challenges_points check (points between 5 and 500),
  constraint challenges_duration check (duration_minutes between 1 and 1440),
  constraint challenges_max_attempts check (max_attempts between 1 and 10),
  constraint challenges_title_length check (char_length(title) between 3 and 100),
  constraint challenges_instructions_length check (char_length(instructions) between 10 and 3000),
  constraint challenges_safety_notes_length check (safety_notes is null or char_length(safety_notes) <= 500)
);
create index if not exists challenges_group_created_idx on public.challenges(group_id, created_at desc);
create index if not exists challenges_creator_idx on public.challenges(creator_id);
create index if not exists challenges_deadline_idx on public.challenges(deadline) where deadline is not null;

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status public.assignment_status not null default 'not-started',
  attempt_count integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint assignments_challenge_user_unique unique (challenge_id, user_id),
  constraint assignments_attempt_count_check check (attempt_count between 0 and 10)
);
create index if not exists assignments_user_status_idx on public.assignments(user_id, status, updated_at desc);
create index if not exists assignments_challenge_idx on public.assignments(challenge_id);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  attempt_number integer not null,
  answer_text text,
  evidence_path text,
  status public.assignment_status not null default 'submitted',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  review_reason text,
  constraint submissions_attempt_unique unique (assignment_id, attempt_number),
  constraint submissions_answer_length check (answer_text is null or char_length(answer_text) <= 3000),
  constraint submissions_evidence_path_length check (evidence_path is null or char_length(evidence_path) <= 500),
  constraint submissions_review_reason_length check (review_reason is null or char_length(review_reason) <= 500),
  constraint submissions_status_check check (status in ('submitted', 'approved', 'rejected'))
);
create index if not exists submissions_assignment_submitted_idx on public.submissions(assignment_id, submitted_at desc);
create index if not exists submissions_review_queue_idx on public.submissions(status, submitted_at desc);

create table if not exists public.review_history (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.submissions(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete restrict,
  decision public.assignment_status not null,
  reason text,
  reviewed_at timestamptz not null default now(),
  constraint review_history_decision_check check (decision in ('approved', 'rejected')),
  constraint review_history_reason_length check (reason is null or char_length(reason) <= 500)
);
create index if not exists review_history_submission_idx on public.review_history(submission_id, reviewed_at desc);

create table if not exists public.points_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  group_id uuid not null references public.groups(id) on delete cascade,
  challenge_id uuid not null references public.challenges(id) on delete restrict,
  submission_id uuid not null references public.submissions(id) on delete restrict,
  points integer not null,
  created_at timestamptz not null default now(),
  constraint points_ledger_submission_unique unique (submission_id),
  constraint points_ledger_positive_points check (points between 5 and 500)
);
create index if not exists points_ledger_group_time_idx on public.points_ledger(group_id, created_at desc);
create index if not exists points_ledger_user_time_idx on public.points_ledger(user_id, created_at desc);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type public.report_target_type not null,
  target_id uuid not null,
  reason text not null,
  status public.report_status not null default 'pending',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  constraint reports_reason_length check (char_length(reason) between 3 and 500)
);
create index if not exists reports_status_created_idx on public.reports(status, created_at desc);
create index if not exists reports_reporter_idx on public.reports(reporter_id, created_at desc);

-- A conservative server-side filter for clearly unsafe challenge prompts.
-- This is not a substitute for reports and human review.
create or replace function private.is_safe_challenge(p_title text, p_instructions text)
returns boolean
language sql
immutable
set search_path = pg_catalog
as $$
  select concat_ws(' ', p_title, p_instructions) !~* (
    '(\m(trespass|steal|break[[:space:]]+in|vandal|weapon|firearm|knife|drug|illegal|blackmail|bully|harass|humiliate|coerce|force[[:space:]]+someone|doxx|nude|nonconsensual|password|social[[:space:]]+security|bank[[:space:]]+account|home[[:space:]]+address)\M'
    '|(jump|leap|climb|hang).{0,40}(roof|balcony|bridge|traffic|moving[[:space:]]+vehicle)'
    '|(intimate|private).{0,25}(photo|image|video)'
    '|(share|post|send).{0,35}(nude|intimate|private[[:space:]]+photo)'
  );
$$;

-- Create a profile automatically for every Supabase Auth account. Never accept
-- a client-supplied score, role, or profile id.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  base_name text;
  candidate text;
  suffix integer := 0;
  wanted_name text;
begin
  wanted_name := coalesce(new.raw_user_meta_data ->> 'username', split_part(coalesce(new.email, 'player'), '@', 1));
  base_name := lower(regexp_replace(wanted_name, '[^a-zA-Z0-9_]', '', 'g'));
  if char_length(base_name) < 3 then base_name := 'player'; end if;
  base_name := left(base_name, 20);
  candidate := base_name;
  while exists (select 1 from public.profiles where lower(username) = lower(candidate)) loop
    suffix := suffix + 1;
    candidate := left(base_name, 20) || suffix::text;
  end loop;
  insert into public.profiles(id, username, display_name)
  values (
    new.id,
    candidate,
    left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), candidate), 48)
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles
for each row execute procedure public.set_updated_at();
drop trigger if exists groups_updated_at on public.groups;
create trigger groups_updated_at before update on public.groups
for each row execute procedure public.set_updated_at();
drop trigger if exists challenges_updated_at on public.challenges;
create trigger challenges_updated_at before update on public.challenges
for each row execute procedure public.set_updated_at();

create or replace function public.create_group(p_name text, p_description text default null)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_group uuid;
begin
  if v_user is null then raise exception 'Sign in to create a group'; end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 48 then raise exception 'Group name must be 2–48 characters'; end if;
  if p_description is not null and char_length(p_description) > 240 then raise exception 'Description is too long'; end if;
  insert into public.groups(name, description, owner_id)
  values (trim(p_name), nullif(trim(p_description), ''), v_user)
  returning id into v_group;
  insert into public.memberships(group_id, user_id, role) values (v_group, v_user, 'owner');
  return v_group;
end;
$$;

create or replace function public.create_group_invitation(p_group_id uuid)
returns table(code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_code text;
  v_expiry timestamptz := now() + interval '7 days';
begin
  if v_user is null or not exists (
    select 1 from public.memberships
    where group_id = p_group_id and user_id = v_user and role = 'owner'
  ) then raise exception 'Only a group owner can create invitations'; end if;
  v_code := upper(encode(extensions.gen_random_bytes(12), 'hex'));
  insert into public.invitations(group_id, created_by, token_hash, expires_at, max_uses)
  values (p_group_id, v_user, encode(extensions.digest(v_code, 'sha256'), 'hex'), v_expiry, 100);
  return query select v_code, v_expiry;
end;
$$;

create or replace function public.join_group(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_group uuid;
  v_invite public.invitations%rowtype;
begin
  if v_user is null then raise exception 'Sign in to join a group'; end if;
  if p_code is null or char_length(p_code) not between 8 and 32 then raise exception 'Invitation code is invalid or expired'; end if;
  select * into v_invite from public.invitations
  where token_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex')
  for update;
  if not found or v_invite.revoked_at is not null or v_invite.expires_at <= now() or v_invite.use_count >= v_invite.max_uses then
    raise exception 'Invitation code is invalid or expired';
  end if;
  v_group := v_invite.group_id;
  if exists (select 1 from public.memberships where group_id = v_group and user_id = v_user) then
    raise exception 'You are already a member of this group';
  end if;
  if (select count(*) from public.memberships where group_id = v_group) >= 100 then
    raise exception 'This group has reached its 100-member limit';
  end if;
  insert into public.memberships(group_id, user_id, role) values (v_group, v_user, 'member');
  update public.invitations set use_count = use_count + 1 where id = v_invite.id;
  return v_group;
end;
$$;

create or replace function public.create_challenge(
  p_group_id uuid,
  p_title text,
  p_instructions text,
  p_category public.challenge_category,
  p_difficulty public.challenge_difficulty,
  p_points integer,
  p_duration_minutes integer,
  p_completion_method public.completion_method,
  p_deadline timestamptz,
  p_safety_notes text,
  p_participant_ids uuid[],
  p_template_id uuid default null,
  p_max_attempts integer default 3
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_challenge uuid;
  v_member_count integer;
begin
  if v_user is null then raise exception 'Sign in to create a challenge'; end if;
  if not exists (select 1 from public.memberships where group_id = p_group_id and user_id = v_user) then
    raise exception 'You must be a group member to create challenges';
  end if;
  if char_length(trim(p_title)) not between 3 and 100 or char_length(trim(p_instructions)) not between 10 and 3000 then raise exception 'Challenge title or instructions are outside allowed limits'; end if;
  if not private.is_safe_challenge(p_title, p_instructions) then raise exception 'This challenge may involve unsafe or non-consensual activity'; end if;
  if p_points not between 5 and 500 or p_duration_minutes not between 1 and 1440 then raise exception 'Points or duration are outside allowed limits'; end if;
  if p_max_attempts not between 1 and 10 then raise exception 'Allowed attempts must be between 1 and 10'; end if;
  if p_deadline is not null and p_deadline <= now() then raise exception 'Deadline must be in the future'; end if;
  if coalesce(array_length(p_participant_ids, 1), 0) not between 1 and 100 then raise exception 'Assign the challenge to 1–100 members'; end if;
  if cardinality(p_participant_ids) <> (select count(distinct item) from unnest(p_participant_ids) item) then raise exception 'Duplicate participants are not allowed'; end if;
  if exists (
    select 1 from unnest(p_participant_ids) participant_id
    where not exists (select 1 from public.memberships m where m.group_id = p_group_id and m.user_id = participant_id)
  ) then raise exception 'Every participant must be a member of the selected group'; end if;
  select count(*) into v_member_count from unnest(p_participant_ids);
  insert into public.challenges(
    group_id, creator_id, template_id, title, instructions, category, difficulty,
    points, duration_minutes, completion_method, safety_notes, deadline, max_attempts
  ) values (
    p_group_id, v_user, p_template_id, trim(p_title), trim(p_instructions), p_category,
    p_difficulty, p_points, p_duration_minutes, p_completion_method,
    nullif(trim(p_safety_notes), ''), p_deadline, p_max_attempts
  ) returning id into v_challenge;
  insert into public.assignments(challenge_id, user_id)
    select v_challenge, participant_id from unnest(p_participant_ids) participant_id;
  return v_challenge;
end;
$$;

create or replace function public.update_challenge(p_challenge_id uuid, p_input jsonb)
returns public.challenges
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_challenge public.challenges%rowtype;
  v_updated public.challenges%rowtype;
  v_allowed constant text[] := array[
    'title', 'instructions', 'category', 'difficulty', 'points',
    'durationMinutes', 'completionMethod', 'safetyNotes', 'deadline',
    'maxAttempts', 'cancelled'
  ];
  v_key text;
begin
  if v_user is null then raise exception 'Sign in to edit a challenge'; end if;
  if jsonb_typeof(p_input) <> 'object' or p_input = '{}'::jsonb then raise exception 'Challenge update is empty'; end if;
  for v_key in select jsonb_object_keys(p_input) loop
    if not (v_key = any(v_allowed)) then raise exception 'Challenge field is not editable'; end if;
  end loop;
  select * into v_challenge from public.challenges where id = p_challenge_id for update;
  if not found then raise exception 'Challenge not found'; end if;
  if v_user <> v_challenge.creator_id and not private.is_group_owner(v_challenge.group_id) then
    raise exception 'Only the challenge creator or group owner can edit it';
  end if;
  if v_challenge.is_cancelled then raise exception 'This challenge is already cancelled'; end if;
  if p_input ? 'points' and exists (
    select 1 from public.assignments a join public.submissions s on s.assignment_id = a.id
    where a.challenge_id = p_challenge_id
  ) then raise exception 'Points cannot be changed after a submission has been made'; end if;
  if p_input ? 'title' and char_length(trim(p_input->>'title')) not between 3 and 100 then raise exception 'Challenge title must be 3–100 characters'; end if;
  if p_input ? 'instructions' and char_length(trim(p_input->>'instructions')) not between 10 and 3000 then raise exception 'Instructions must be 10–3000 characters'; end if;
  if not private.is_safe_challenge(
    case when p_input ? 'title' then p_input->>'title' else v_challenge.title end,
    case when p_input ? 'instructions' then p_input->>'instructions' else v_challenge.instructions end
  ) then raise exception 'This challenge may involve unsafe or non-consensual activity'; end if;
  if p_input ? 'points' and (p_input->>'points')::integer not between 5 and 500 then raise exception 'Points must be 5–500'; end if;
  if p_input ? 'durationMinutes' and (p_input->>'durationMinutes')::integer not between 1 and 1440 then raise exception 'Duration must be 1–1440 minutes'; end if;
  if p_input ? 'maxAttempts' and (p_input->>'maxAttempts')::integer not between 1 and 10 then raise exception 'Attempts must be 1–10'; end if;
  if p_input ? 'deadline' and p_input->>'deadline' is not null
     and (p_input->>'deadline')::timestamptz <= now() then raise exception 'Deadline must be in the future'; end if;
  if p_input ? 'cancelled' and (p_input->>'cancelled')::boolean is distinct from true then
    raise exception 'Cancelled challenges cannot be reopened';
  end if;
  update public.challenges set
    title = case when p_input ? 'title' then trim(p_input->>'title') else title end,
    instructions = case when p_input ? 'instructions' then trim(p_input->>'instructions') else instructions end,
    category = case when p_input ? 'category' then (p_input->>'category')::public.challenge_category else category end,
    difficulty = case when p_input ? 'difficulty' then (p_input->>'difficulty')::public.challenge_difficulty else difficulty end,
    points = case when p_input ? 'points' then (p_input->>'points')::integer else points end,
    duration_minutes = case when p_input ? 'durationMinutes' then (p_input->>'durationMinutes')::integer else duration_minutes end,
    completion_method = case when p_input ? 'completionMethod' then (p_input->>'completionMethod')::public.completion_method else completion_method end,
    safety_notes = case when p_input ? 'safetyNotes' then nullif(p_input->>'safetyNotes', '') else safety_notes end,
    deadline = case when p_input ? 'deadline' then (p_input->>'deadline')::timestamptz else deadline end,
    max_attempts = case when p_input ? 'maxAttempts' then (p_input->>'maxAttempts')::integer else max_attempts end,
    is_cancelled = case when p_input ? 'cancelled' then true else is_cancelled end
  where id = p_challenge_id returning * into v_updated;
  if v_updated.is_cancelled then
    update public.assignments set status = 'cancelled', updated_at = now()
    where challenge_id = p_challenge_id and status not in ('approved', 'cancelled');
  end if;
  return v_updated;
end;
$$;

create or replace function public.start_challenge(p_challenge_id uuid)
returns public.assignments
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_assignment public.assignments%rowtype;
  v_challenge public.challenges%rowtype;
begin
  select * into v_assignment from public.assignments where challenge_id = p_challenge_id and user_id = v_user for update;
  if not found then raise exception 'Challenge assignment not found'; end if;
  select * into v_challenge from public.challenges where id = p_challenge_id;
  if v_challenge.is_cancelled then raise exception 'This challenge has been cancelled'; end if;
  if v_challenge.deadline is not null and v_challenge.deadline <= now() then
    update public.assignments set status = 'expired', updated_at = now() where id = v_assignment.id returning * into v_assignment;
    return v_assignment;
  end if;
  if v_assignment.status not in ('not-started', 'rejected') or v_assignment.attempt_count >= v_challenge.max_attempts then
    raise exception 'This challenge cannot be started';
  end if;
  update public.assignments set status = 'in-progress', updated_at = now()
  where id = v_assignment.id returning * into v_assignment;
  return v_assignment;
end;
$$;

create or replace function public.submit_challenge(
  p_challenge_id uuid,
  p_answer_text text,
  p_evidence_path text,
  p_confirm_complete boolean
)
returns public.submissions
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_assignment public.assignments%rowtype;
  v_challenge public.challenges%rowtype;
  v_submission public.submissions%rowtype;
begin
  if v_user is null then raise exception 'Sign in to submit a challenge'; end if;
  if p_confirm_complete is distinct from true then raise exception 'Confirm that you completed the challenge'; end if;
  if p_answer_text is not null and char_length(p_answer_text) > 3000 then raise exception 'Your answer is too long'; end if;
  if p_evidence_path is not null and char_length(p_evidence_path) > 500 then raise exception 'Evidence path is invalid'; end if;
  select * into v_assignment from public.assignments
  where challenge_id = p_challenge_id and user_id = v_user for update;
  if not found then raise exception 'Only assigned members can submit'; end if;
  select * into v_challenge from public.challenges where id = p_challenge_id;
  if v_challenge.is_cancelled then raise exception 'This challenge has been cancelled'; end if;
  if v_challenge.deadline is not null and v_challenge.deadline <= now() then
    update public.assignments set status = 'expired', updated_at = now() where id = v_assignment.id;
    raise exception 'This challenge has expired';
  end if;
  if v_assignment.status not in ('not-started', 'in-progress', 'rejected') then raise exception 'This assignment cannot accept another submission'; end if;
  if v_assignment.attempt_count >= v_challenge.max_attempts then raise exception 'No submission attempts remain'; end if;
  if v_challenge.completion_method = 'text' and nullif(trim(p_answer_text), '') is null then raise exception 'Add a text answer before submitting'; end if;
  if v_challenge.completion_method = 'evidence' and p_evidence_path is null then raise exception 'Upload an image or provide an answer before submitting'; end if;
  if p_evidence_path is not null and split_part(p_evidence_path, '/', 1) <> v_user::text then raise exception 'Evidence must be stored under your own account'; end if;
  if p_evidence_path is not null and split_part(p_evidence_path, '/', 2) <> p_challenge_id::text then raise exception 'Evidence path does not match this challenge'; end if;
  if p_evidence_path is not null and not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'challenge-evidence' and o.name = p_evidence_path
  ) then raise exception 'Evidence image was not uploaded successfully'; end if;
  insert into public.submissions(assignment_id, attempt_number, answer_text, evidence_path, status)
  values (v_assignment.id, v_assignment.attempt_count + 1, nullif(trim(p_answer_text), ''), p_evidence_path, 'submitted')
  returning * into v_submission;
  update public.assignments set status = 'submitted', attempt_count = attempt_count + 1, updated_at = now()
  where id = v_assignment.id;
  return v_submission;
end;
$$;

create or replace function public.review_submission(
  p_submission_id uuid,
  p_decision public.assignment_status,
  p_reason text default null
)
returns public.submissions
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_submission public.submissions%rowtype;
  v_assignment public.assignments%rowtype;
  v_challenge public.challenges%rowtype;
  v_owner uuid;
begin
  if v_user is null then raise exception 'Sign in to review submissions'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'Choose approve or reject'; end if;
  if p_reason is not null and char_length(p_reason) > 500 then raise exception 'Review reason is too long'; end if;
  select * into v_submission from public.submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found'; end if;
  select * into v_assignment from public.assignments where id = v_submission.assignment_id;
  select * into v_challenge from public.challenges where id = v_assignment.challenge_id;
  select owner_id into v_owner from public.groups where id = v_challenge.group_id;
  if v_submission.assignment_id is null or v_submission.status <> 'submitted' then raise exception 'This submission has already been reviewed'; end if;
  if v_assignment.user_id = v_user then raise exception 'You cannot review your own submission'; end if;
  if v_user <> v_challenge.creator_id and v_user <> v_owner then raise exception 'Only the challenge creator or group owner can review'; end if;
  if v_challenge.is_cancelled then raise exception 'This challenge has been cancelled'; end if;
  update public.submissions
    set status = p_decision, reviewed_at = now(), reviewed_by = v_user,
        review_reason = nullif(trim(p_reason), '')
    where id = p_submission_id returning * into v_submission;
  update public.assignments set status = p_decision, updated_at = now()
    where id = v_assignment.id;
  insert into public.review_history(submission_id, reviewer_id, decision, reason)
    values (p_submission_id, v_user, p_decision, nullif(trim(p_reason), ''));
  if p_decision = 'approved' then
    insert into public.points_ledger(user_id, group_id, challenge_id, submission_id, points)
    values (v_assignment.user_id, v_challenge.group_id, v_challenge.id, v_submission.id, v_challenge.points)
    on conflict (submission_id) do nothing;
  end if;
  return v_submission;
end;
$$;

create or replace function public.leave_group(p_group_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_new_owner uuid;
begin
  if v_user is null then raise exception 'Sign in to leave a group'; end if;
  if not exists (select 1 from public.memberships where group_id = p_group_id and user_id = v_user) then raise exception 'You are not a member of this group'; end if;
  if exists (select 1 from public.memberships where group_id = p_group_id and user_id = v_user and role = 'owner') then
    select user_id into v_new_owner from public.memberships
    where group_id = p_group_id and user_id <> v_user
    order by joined_at asc limit 1 for update;
    if v_new_owner is null then raise exception 'Invite another member before leaving this group'; end if;
    update public.memberships set role = 'owner' where group_id = p_group_id and user_id = v_new_owner;
    update public.groups set owner_id = v_new_owner where id = p_group_id;
  end if;
  delete from public.memberships where group_id = p_group_id and user_id = v_user;
  return true;
end;
$$;

create or replace function public.remove_group_member(p_group_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null or not exists (
    select 1 from public.memberships where group_id = p_group_id and user_id = v_user and role = 'owner'
  ) then raise exception 'Only a group owner can remove members'; end if;
  if p_user_id = v_user then raise exception 'Use leave group to transfer ownership safely'; end if;
  delete from public.memberships where group_id = p_group_id and user_id = p_user_id and role = 'member';
  if not found then raise exception 'Member not found or cannot be removed'; end if;
  return true;
end;
$$;

create or replace function public.review_report(p_report_id uuid, p_decision public.report_status)
returns public.reports
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_report public.reports%rowtype;
  v_can_review boolean := false;
begin
  if v_user is null then raise exception 'Sign in to review reports'; end if;
  if p_decision not in ('reviewed', 'dismissed') then raise exception 'Choose reviewed or dismissed'; end if;
  select * into v_report from public.reports where id = p_report_id for update;
  if not found then raise exception 'Report not found'; end if;
  if v_report.status <> 'pending' then raise exception 'This report has already been reviewed'; end if;
  if v_report.target_type = 'challenge' then
    select private.is_group_owner(c.group_id) into v_can_review
    from public.challenges c where c.id = v_report.target_id;
  elsif v_report.target_type = 'submission' then
    select private.is_group_owner(c.group_id) into v_can_review
    from public.submissions s
    join public.assignments a on a.id = s.assignment_id
    join public.challenges c on c.id = a.challenge_id
    where s.id = v_report.target_id;
  else
    select exists (
      select 1 from public.memberships m
      where m.user_id = v_report.target_id and private.is_group_owner(m.group_id)
    ) into v_can_review;
  end if;
  if not coalesce(v_can_review, false) then raise exception 'Only a relevant group owner can review this report'; end if;
  update public.reports set status = p_decision, reviewed_at = now(), reviewed_by = v_user
  where id = p_report_id returning * into v_report;
  return v_report;
end;
$$;

create or replace function public.group_leaderboard(p_group_id uuid, p_window text default 'all-time')
returns table(
  rank bigint, user_id uuid, username text, display_name text, avatar_url text,
  points bigint, completed_challenges bigint
)
language plpgsql
stable
security invoker
set search_path = public, auth
as $$
declare
  v_start timestamptz;
begin
  if auth.uid() is null or not private.is_group_member(p_group_id) then
    raise exception 'You must be a group member to view its leaderboard';
  end if;
  if p_window not in ('weekly', 'all-time') then raise exception 'Leaderboard period is invalid'; end if;
  v_start := case when p_window = 'weekly'
    then date_trunc('week', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
    else '-infinity'::timestamptz end;
  return query
    with scores as (
      select m.user_id,
        coalesce(sum(l.points), 0)::bigint as points,
        count(l.id)::bigint as completed_challenges,
        min(l.created_at) as first_achievement
      from public.memberships m
      left join public.points_ledger l
        on l.user_id = m.user_id and l.group_id = p_group_id and l.created_at >= v_start
      where m.group_id = p_group_id
      group by m.user_id
    ), details as (
      select s.*, p.username, p.display_name, p.avatar_url
      from scores s join public.profiles p on p.id = s.user_id
    )
    select row_number() over (
      order by d.points desc, d.completed_challenges desc, d.first_achievement asc nulls last, d.username asc
    ), d.user_id, d.username, d.display_name, d.avatar_url, d.points, d.completed_challenges
    from details d
    order by d.points desc, d.completed_challenges desc, d.first_achievement asc nulls last, d.username asc;
end;
$$;

create or replace function public.get_profile_stats()
returns table(total_points bigint, completed_challenges bigint, groups_count bigint)
language sql
stable
security invoker
set search_path = public, auth
as $$
  select
    coalesce((select sum(l.points) from public.points_ledger l where l.user_id = auth.uid()), 0)::bigint,
    coalesce((select count(*) from public.points_ledger l where l.user_id = auth.uid()), 0)::bigint,
    coalesce((select count(*) from public.memberships m where m.user_id = auth.uid()), 0)::bigint;
$$;

create or replace function public.get_weekly_points()
returns bigint
language sql
stable
security invoker
set search_path = public, auth
as $$
  select coalesce(sum(l.points), 0)::bigint
  from public.points_ledger l
  where l.user_id = auth.uid()
    and l.created_at >= date_trunc('week', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
$$;

create or replace function public.get_challenge_counts(p_challenge_ids uuid[])
returns table(challenge_id uuid, participant_count bigint)
language sql
stable
security invoker
set search_path = public, auth
as $$
  select a.challenge_id, count(*)::bigint
  from public.assignments a
  join public.challenges c on c.id = a.challenge_id
  where a.challenge_id = any(p_challenge_ids)
    and private.is_group_member(c.group_id)
  group by a.challenge_id;
$$;

-- RLS is enabled on every exposed table. Write access that can affect scores,
-- roles, invitations, or workflow state is available only through checked SQL
-- functions above.
revoke all on public.profiles, public.groups, public.memberships, public.invitations,
  public.challenge_templates, public.challenges, public.assignments, public.submissions,
  public.review_history, public.points_ledger, public.reports
from anon, authenticated;
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.memberships enable row level security;
alter table public.invitations enable row level security;
alter table public.challenge_templates enable row level security;
alter table public.challenges enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.review_history enable row level security;
alter table public.points_ledger enable row level security;
alter table public.reports enable row level security;

create or replace function private.is_group_member(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from public.memberships where group_id = p_group_id and user_id = auth.uid());
$$;
create or replace function private.is_group_owner(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from public.memberships where group_id = p_group_id and user_id = auth.uid() and role = 'owner');
$$;
revoke all on function private.is_group_member(uuid) from public, anon;
revoke all on function private.is_group_owner(uuid) from public, anon;
grant execute on function private.is_group_member(uuid) to authenticated;
grant execute on function private.is_group_owner(uuid) to authenticated;

drop policy if exists "profiles readable by self or groupmates" on public.profiles;
create policy "profiles readable by self or groupmates" on public.profiles for select to authenticated using (
  id = auth.uid() or exists (
    select 1 from public.memberships mine
    join public.memberships theirs on theirs.group_id = mine.group_id
    where mine.user_id = auth.uid() and theirs.user_id = profiles.id
  )
);
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke insert, delete on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update(username, display_name, avatar_url) on public.profiles to authenticated;

drop policy if exists "groups visible to members" on public.groups;
create policy "groups visible to members" on public.groups for select to authenticated using (private.is_group_member(id));
drop policy if exists "owners update groups" on public.groups;
create policy "owners update groups" on public.groups for update to authenticated using (private.is_group_owner(id)) with check (
  private.is_group_owner(id)
);
revoke insert, delete on public.groups from anon, authenticated;
revoke update on public.groups from anon, authenticated;
grant select on public.groups to authenticated;
grant update(name, description) on public.groups to authenticated;

drop policy if exists "members read group memberships" on public.memberships;
create policy "members read group memberships" on public.memberships for select to authenticated using (private.is_group_member(group_id));
revoke insert, update, delete on public.memberships from anon, authenticated;
grant select on public.memberships to authenticated;

drop policy if exists "owners read invitations" on public.invitations;
create policy "owners read invitations" on public.invitations for select to authenticated using (private.is_group_owner(group_id));
revoke insert, update, delete on public.invitations from anon, authenticated;
grant select on public.invitations to authenticated;

drop policy if exists "templates readable to authenticated" on public.challenge_templates;
create policy "templates readable to authenticated" on public.challenge_templates for select to authenticated using (true);
revoke insert, update, delete on public.challenge_templates from anon, authenticated;
grant select on public.challenge_templates to authenticated;

drop policy if exists "group challenges visible to members" on public.challenges;
create policy "group challenges visible to members" on public.challenges for select to authenticated using (private.is_group_member(group_id));
revoke insert, update, delete on public.challenges from anon, authenticated;
grant select on public.challenges to authenticated;

drop policy if exists "assigned users or group members read assignments" on public.assignments;
create policy "assigned users or group members read assignments" on public.assignments for select to authenticated using (
  user_id = auth.uid() or exists (
    select 1 from public.challenges c where c.id = challenge_id and private.is_group_member(c.group_id)
  )
);
revoke insert, update, delete on public.assignments from anon, authenticated;
grant select on public.assignments to authenticated;

drop policy if exists "participants and authorized reviewers read submissions" on public.submissions;
create policy "participants and authorized reviewers read submissions" on public.submissions for select to authenticated using (
  exists (
    select 1 from public.assignments a
    join public.challenges c on c.id = a.challenge_id
    where a.id = assignment_id and (
      a.user_id = auth.uid() or c.creator_id = auth.uid() or private.is_group_owner(c.group_id)
    )
  )
);
revoke insert, update, delete on public.submissions from anon, authenticated;
grant select on public.submissions to authenticated;

drop policy if exists "participants and reviewers read history" on public.review_history;
create policy "participants and reviewers read history" on public.review_history for select to authenticated using (
  exists (
    select 1 from public.submissions s
    join public.assignments a on a.id = s.assignment_id
    join public.challenges c on c.id = a.challenge_id
    where s.id = submission_id and (
      a.user_id = auth.uid() or c.creator_id = auth.uid() or private.is_group_owner(c.group_id)
    )
  )
);
revoke insert, update, delete on public.review_history from anon, authenticated;
grant select on public.review_history to authenticated;

drop policy if exists "group members read ledger" on public.points_ledger;
create policy "group members read ledger" on public.points_ledger for select to authenticated using (
  user_id = auth.uid() or private.is_group_member(group_id)
);
revoke insert, update, delete on public.points_ledger from anon, authenticated;
grant select on public.points_ledger to authenticated;

drop policy if exists "users create own reports" on public.reports;
create policy "users create own reports" on public.reports for insert to authenticated with check (
  reporter_id = auth.uid() and (
    (target_type = 'challenge' and exists (select 1 from public.challenges c where c.id = target_id))
    or (target_type = 'submission' and exists (select 1 from public.submissions s where s.id = target_id))
    or (target_type = 'user' and target_id <> auth.uid() and exists (select 1 from public.profiles p where p.id = target_id))
  )
);
drop policy if exists "reporters and group owners read reports" on public.reports;
create policy "reporters and group owners read reports" on public.reports for select to authenticated using (
  reporter_id = auth.uid() or exists (
    select 1 from public.challenges c where c.id = target_id and target_type = 'challenge' and private.is_group_owner(c.group_id)
  ) or exists (
    select 1 from public.submissions s
    join public.assignments a on a.id = s.assignment_id
    join public.challenges c on c.id = a.challenge_id
    where s.id = target_id and target_type = 'submission' and private.is_group_owner(c.group_id)
  ) or (target_type = 'user' and exists (
    select 1 from public.memberships m
    where m.user_id = reports.target_id and private.is_group_owner(m.group_id)
      and private.is_group_member(m.group_id)
  ))
);
revoke update, delete on public.reports from anon, authenticated;
grant select, insert on public.reports to authenticated;

-- RPCs are callable only by signed-in users; all identities and point values
-- are read from auth.uid() and trusted database rows, never from client totals.
revoke all on function public.create_group(text, text) from public, anon;
revoke all on function public.create_group_invitation(uuid) from public, anon;
revoke all on function public.join_group(text) from public, anon;
revoke all on function public.update_challenge(uuid, jsonb) from public, anon;
revoke all on function public.start_challenge(uuid) from public, anon;
revoke all on function public.submit_challenge(uuid, text, text, boolean) from public, anon;
revoke all on function public.review_submission(uuid, public.assignment_status, text) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
revoke all on function public.review_report(uuid, public.report_status) from public, anon;
revoke all on function public.group_leaderboard(uuid, text) from public, anon;
revoke all on function public.get_profile_stats() from public, anon;
revoke all on function public.get_weekly_points() from public, anon;
revoke all on function public.get_challenge_counts(uuid[]) from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
grant execute on function public.create_group(text, text) to authenticated;
grant execute on function public.create_group_invitation(uuid) to authenticated;
grant execute on function public.join_group(text) to authenticated;
revoke all on function public.create_challenge(uuid, text, text, public.challenge_category, public.challenge_difficulty, integer, integer, public.completion_method, timestamptz, text, uuid[], uuid, integer) from public, anon;
grant execute on function public.create_challenge(uuid, text, text, public.challenge_category, public.challenge_difficulty, integer, integer, public.completion_method, timestamptz, text, uuid[], uuid, integer) to authenticated;
grant execute on function public.update_challenge(uuid, jsonb) to authenticated;
grant execute on function public.start_challenge(uuid) to authenticated;
grant execute on function public.submit_challenge(uuid, text, text, boolean) to authenticated;
grant execute on function public.review_submission(uuid, public.assignment_status, text) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.review_report(uuid, public.report_status) to authenticated;
grant execute on function public.group_leaderboard(uuid, text) to authenticated;
grant execute on function public.get_profile_stats() to authenticated;
grant execute on function public.get_weekly_points() to authenticated;
grant execute on function public.get_challenge_counts(uuid[]) to authenticated;
grant select on public.groups, public.memberships, public.invitations,
  public.challenge_templates, public.challenges, public.assignments, public.submissions,
  public.review_history, public.points_ledger, public.reports to authenticated;
grant select on public.profiles to authenticated;
grant update(username, display_name, avatar_url) on public.profiles to authenticated;
grant update(name, description) on public.groups to authenticated;
grant insert(reporter_id, target_type, target_id, reason) on public.reports to authenticated;

-- Private evidence images. Paths use {user_id}/{challenge_id}/{filename}.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('challenge-evidence', 'challenge-evidence', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "users upload own challenge evidence" on storage.objects;
create policy "users upload own challenge evidence" on storage.objects for insert to authenticated with check (
  bucket_id = 'challenge-evidence'
  and (storage.foldername(name))[1] = auth.uid()::text
  and exists (
    select 1 from public.assignments a
    join public.challenges c on c.id = a.challenge_id
    where c.id::text = (storage.foldername(name))[2]
      and a.user_id = auth.uid()
      and not c.is_cancelled
      and (c.deadline is null or c.deadline > now())
  )
);
drop policy if exists "owners and assigned reviewers read evidence" on storage.objects;
create policy "owners and assigned reviewers read evidence" on storage.objects for select to authenticated using (
  bucket_id = 'challenge-evidence'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.challenges c
      join public.groups g on g.id = c.group_id
      where c.id::text = (storage.foldername(name))[2]
        and (c.creator_id = auth.uid() or g.owner_id = auth.uid())
    )
  )
);
drop policy if exists "users delete own unsubmitted evidence" on storage.objects;
create policy "users delete own unsubmitted evidence" on storage.objects for delete to authenticated using (
  bucket_id = 'challenge-evidence' and (storage.foldername(name))[1] = auth.uid()::text
  and not exists (select 1 from public.submissions s where s.evidence_path = name)
);

comment on table public.points_ledger is 'Immutable approved completion awards; each submission can award points once.';
comment on table public.review_history is 'Append-only record of each authorized submission decision.';
comment on table public.invitations is 'Only a SHA-256 digest of an invite code is stored; plaintext is returned once at creation.';
