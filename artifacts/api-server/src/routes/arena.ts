import { Router, type IRouter, type Request, type Response, type RequestHandler } from "express";
import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";
import { rateLimit } from "express-rate-limit";
import {
  CreateChallengeBody,
  CreateGroupBody,
  CreateReportBody,
  GetChallengeParams,
  GetGroupParams,
  GetLeaderboardQueryParams,
  JoinGroupBody,
  LeaveGroupParams,
  ListChallengesQueryParams,
  RemoveGroupMemberParams,
  ReviewReportBody,
  ReviewReportParams,
  ReviewSubmissionBody,
  ReviewSubmissionParams,
  StartChallengeParams,
  SubmitChallengeBody,
  SubmitChallengeParams,
  UpdateChallengeBody,
  UpdateChallengeParams,
  UpdateGroupBody,
  UpdateGroupParams,
  UpdateProfileBody,
  CreateGroupInvitationParams,
} from "@workspace/api-zod";

type Row = Record<string, unknown>;
type ArenaContext = { client: SupabaseClient; user: User };
type ArenaRequest = Request & { arena?: ArenaContext };
type ApiHandler = (req: ArenaRequest, res: Response) => Promise<void>;

class ArenaError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

const router: IRouter = Router();
const getContext = (req: ArenaRequest): ArenaContext => {
  if (!req.arena) throw new ArenaError(401, "Sign in to continue.");
  return req.arena;
};
const row = (value: unknown): Row => (value && typeof value === "object" ? value as Row : {});
const rows = (value: unknown): Row[] => Array.isArray(value) ? value.map(row) : [];
const text = (value: unknown, fallback = ""): string => typeof value === "string" ? value : fallback;
const nullableText = (value: unknown): string | null => typeof value === "string" ? value : null;
const numeric = (value: unknown, fallback = 0): number => typeof value === "number" ? value : Number(value ?? fallback) || fallback;
const boolean = (value: unknown): boolean => value === true;
const notFound = (error: { code?: string; message?: string } | null, message: string): never => {
  if (error?.code === "PGRST116" || error?.code === "PGRST204") throw new ArenaError(404, message);
  if (error) throw error;
  throw new ArenaError(404, message);
};

function apiError(req: ArenaRequest, res: Response, error: unknown): void {
  if (error instanceof ArenaError) {
    res.status(error.status).json({ error: error.message });
    return;
  }
  const dbError = row(error);
  const code = text(dbError.code);
  const dbMessage = text(dbError.message);
  if (code === "P0001") {
    res.status(400).json({ error: dbMessage || "This action is not allowed." });
    return;
  }
  if (code === "23505") {
    res.status(409).json({ error: "That value is already in use." });
    return;
  }
  if (code === "42501") {
    res.status(403).json({ error: "You do not have permission to do that." });
    return;
  }
  if (code === "22P02" || code === "23514" || code === "23503") {
    res.status(400).json({ error: "Some submitted information is invalid." });
    return;
  }
  req.log.error({ code: code || "unknown" }, "Challenge Arena request failed");
  res.status(500).json({ error: "We couldn't complete that action. Please try again." });
}

function route(handler: ApiHandler): RequestHandler {
  return (req, res) => {
    void handler(req as ArenaRequest, res).catch((error: unknown) => apiError(req as ArenaRequest, res, error));
  };
}

const signInRequired: RequestHandler = (req, res, next) => {
  void (async () => {
    const authorization = req.header("authorization");
    const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
    const supabaseUrl = process.env.VITE_SUPABASE_URL;
    const anonKey = process.env.VITE_SUPABASE_ANON_KEY;
    if (!supabaseUrl || !anonKey) {
      res.status(503).json({ error: "Supabase is not configured. Add the project URL and public anon key." });
      return;
    }
    if (!token) {
      res.status(401).json({ error: "Sign in to continue." });
      return;
    }
    const client = createClient(supabaseUrl, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data, error } = await client.auth.getUser(token);
    if (error || !data.user) {
      res.status(401).json({ error: "Your session expired. Sign in again." });
      return;
    }
    (req as ArenaRequest).arena = { client, user: data.user };
    next();
  })().catch((error: unknown) => apiError(req as ArenaRequest, res, error));
};

// Identity is verified before applying the per-account limit; Supabase Auth
// independently rate-limits its own password and recovery endpoints.
const perUserRateLimit = rateLimit({
  windowMs: 60_000,
  limit: 90,
  standardHeaders: "draft-8",
  legacyHeaders: false,
  keyGenerator: (req) => (req as ArenaRequest).arena?.user.id ?? req.ip ?? "unknown",
  handler: (_req, res) => res.status(429).json({ error: "Too many requests. Please wait a minute and try again." }),
});
router.use(signInRequired, perUserRateLimit);

function mapProfile(profileValue: unknown, statsValue: unknown): Row {
  const profile = row(profileValue);
  const stats = row(statsValue);
  return {
    id: text(profile.id),
    username: text(profile.username),
    displayName: text(profile.display_name),
    avatarUrl: nullableText(profile.avatar_url),
    points: numeric(stats.total_points),
    completedChallenges: numeric(stats.completed_challenges),
    groupsCount: numeric(stats.groups_count),
  };
}

function toAssignmentStatus(assignmentStatus: unknown, challenge: Row): string {
  if (boolean(challenge.is_cancelled)) return "cancelled";
  const status = text(assignmentStatus, "not-started");
  const deadline = nullableText(challenge.deadline);
  if (deadline && new Date(deadline).getTime() <= Date.now() && status !== "approved" && status !== "cancelled") return "expired";
  return status;
}

function mapChallenge(challengeValue: unknown, assignmentValue?: unknown, participantCount = 0, isTemplate = false): Row {
  const challenge = row(challengeValue);
  const assignment = row(assignmentValue);
  return {
    id: text(challenge.id),
    groupId: nullableText(challenge.group_id),
    creatorId: nullableText(challenge.creator_id),
    title: text(challenge.title),
    instructions: text(challenge.instructions),
    category: text(challenge.category),
    difficulty: text(challenge.difficulty),
    points: numeric(challenge.points),
    durationMinutes: numeric(challenge.duration_minutes),
    completionMethod: text(challenge.completion_method, "confirmation"),
    safetyNotes: nullableText(challenge.safety_notes),
    deadline: nullableText(challenge.deadline),
    status: isTemplate ? "not-started" : toAssignmentStatus(assignment.status, challenge),
    isTemplate,
    isAssigned: Boolean(assignment.id),
    maxAttempts: numeric(challenge.max_attempts, 3),
    participantCount,
    createdAt: text(challenge.created_at, new Date().toISOString()),
  };
}

function mapGroup(groupValue: unknown, memberCount = 0): Row {
  const group = row(groupValue);
  return {
    id: text(group.id),
    name: text(group.name),
    description: nullableText(group.description),
    ownerId: text(group.owner_id),
    memberCount,
    createdAt: text(group.created_at, new Date().toISOString()),
  };
}

function mapSubmission(submissionValue: unknown, userValue: unknown, challengeValue: unknown): Row {
  const submission = row(submissionValue);
  const profile = row(userValue);
  const challenge = row(challengeValue);
  return {
    id: text(submission.id),
    challengeId: text(challenge.id ?? challenge.challenge_id),
    userId: text(profile.id ?? profile.user_id),
    username: text(profile.username, "member"),
    displayName: text(profile.display_name, "Member"),
    challengeTitle: text(challenge.title, "Challenge"),
    answerText: nullableText(submission.answer_text),
    evidencePath: nullableText(submission.evidence_path),
    status: text(submission.status, "submitted"),
    reviewReason: nullableText(submission.review_reason),
    submittedAt: text(submission.submitted_at, new Date().toISOString()),
  };
}

async function getProfile(client: SupabaseClient, user: User): Promise<Row> {
  const [profileResult, statsResult] = await Promise.all([
    client.from("profiles").select("id,username,display_name,avatar_url").eq("id", user.id).maybeSingle(),
    client.rpc("get_profile_stats").maybeSingle(),
  ]);
  if (profileResult.error) throw profileResult.error;
  if (!profileResult.data) {
    throw new ArenaError(409, "Your profile is being set up. Please refresh in a moment.");
  }
  if (statsResult.error) throw statsResult.error;
  return mapProfile(profileResult.data, statsResult.data);
}

async function listGroups(client: SupabaseClient, user: User): Promise<Row[]> {
  const memberships = await client.from("memberships").select("group_id").eq("user_id", user.id).limit(100);
  if (memberships.error) throw memberships.error;
  const groupIds = rows(memberships.data).map((membership) => text(membership.group_id));
  if (!groupIds.length) return [];
  const [groupsResult, memberRows] = await Promise.all([
    client.from("groups").select("id,name,description,owner_id,created_at").in("id", groupIds).eq("is_active", true).order("created_at", { ascending: false }),
    client.from("memberships").select("group_id").in("group_id", groupIds).limit(10000),
  ]);
  if (groupsResult.error) throw groupsResult.error;
  if (memberRows.error) throw memberRows.error;
  const counts = new Map<string, number>();
  rows(memberRows.data).forEach((member) => {
    const id = text(member.group_id);
    counts.set(id, (counts.get(id) ?? 0) + 1);
  });
  return rows(groupsResult.data).map((group) => mapGroup(group, counts.get(text(group.id)) ?? 0));
}

async function listChallenges(client: SupabaseClient, user: User, query: Row): Promise<Row[]> {
  if (query.template === true || query.template === "true") {
    const result = await client.from("challenge_templates").select("*").order("category").order("title").limit(100);
    if (result.error) throw result.error;
    return rows(result.data).map((challenge) => mapChallenge(challenge, undefined, 0, true))
      .filter((challenge) => matchesChallenge(challenge, query));
  }
  const groupResult = await client.from("memberships").select("group_id").eq("user_id", user.id).limit(100);
  if (groupResult.error) throw groupResult.error;
  const groupIds = rows(groupResult.data).map((membership) => text(membership.group_id));
  if (!groupIds.length) return [];
  if (typeof query.groupId === "string" && !groupIds.includes(query.groupId)) return [];
  const challengeGroupIds = typeof query.groupId === "string" ? [query.groupId] : groupIds;
  let challengeQuery = client.from("challenges").select("*").in("group_id", challengeGroupIds).limit(200);
  if (typeof query.category === "string") challengeQuery = challengeQuery.eq("category", query.category);
  if (typeof query.difficulty === "string") challengeQuery = challengeQuery.eq("difficulty", query.difficulty);
  const challengeResult = await challengeQuery;
  if (challengeResult.error) throw challengeResult.error;
  const challenges = rows(challengeResult.data);
  const challengeIds = challenges.map((challenge) => text(challenge.id));
  if (!challengeIds.length) return [];
  const [assignmentsResult, countResult] = await Promise.all([
    client.from("assignments").select("id,challenge_id,user_id,status,updated_at")
      .eq("user_id", user.id).in("challenge_id", challengeIds).limit(200),
    client.rpc("get_challenge_counts", { p_challenge_ids: challengeIds }),
  ]);
  if (assignmentsResult.error) throw assignmentsResult.error;
  if (countResult.error) throw countResult.error;
  const assignmentsById = new Map(rows(assignmentsResult.data).map((assignment) => [text(assignment.challenge_id), assignment]));
  const countsById = new Map(rows(countResult.data).map((item) => [text(item.challenge_id), numeric(item.participant_count)]));
  return challenges.map((challenge) => {
    const id = text(challenge.id);
    return mapChallenge(challenge, assignmentsById.get(id), countsById.get(id) ?? 0);
  }).filter((challenge) => matchesChallenge(challenge, query));
}

function matchesChallenge(challenge: Row, query: Row): boolean {
  if (typeof query.status === "string" && challenge.status !== query.status) return false;
  if (typeof query.groupId === "string" && challenge.groupId !== query.groupId) return false;
  if (typeof query.category === "string" && challenge.category !== query.category) return false;
  if (typeof query.difficulty === "string" && challenge.difficulty !== query.difficulty) return false;
  if (typeof query.search === "string") {
    const search = query.search.trim().toLowerCase();
    if (search && !`${text(challenge.title)} ${text(challenge.instructions)}`.toLowerCase().includes(search)) return false;
  }
  return true;
}

async function getChallengeDetail(client: SupabaseClient, user: User, challengeId: string): Promise<Row> {
  const result = await client.from("challenges").select("*").eq("id", challengeId).maybeSingle();
  if (result.error) throw result.error;
  if (!result.data) throw new ArenaError(404, "Challenge not found.");
  const [assignmentResult, allAssignmentsResult] = await Promise.all([
    client.from("assignments").select("*").eq("challenge_id", challengeId).eq("user_id", user.id).maybeSingle(),
    client.from("assignments").select("user_id").eq("challenge_id", challengeId).limit(100),
  ]);
  if (assignmentResult.error) throw assignmentResult.error;
  if (allAssignmentsResult.error) throw allAssignmentsResult.error;
  const assignments = rows(allAssignmentsResult.data);
  const ids = assignments.map((assignment) => text(assignment.user_id));
  const groupId = text(row(result.data).group_id);
  const [profilesResult, membershipsResult, leaderboardResult] = await Promise.all([
    ids.length ? client.from("profiles").select("id,username,display_name,avatar_url").in("id", ids) : { data: [], error: null },
    ids.length ? client.from("memberships").select("user_id,role").eq("group_id", groupId).in("user_id", ids) : { data: [], error: null },
    client.rpc("group_leaderboard", { p_group_id: groupId, p_window: "all-time" }),
  ]);
  if (profilesResult.error) throw profilesResult.error;
  if (membershipsResult.error) throw membershipsResult.error;
  if (leaderboardResult.error) throw leaderboardResult.error;
  const profilesById = new Map(rows(profilesResult.data).map((profile) => [text(profile.id), profile]));
  const membershipsById = new Map(rows(membershipsResult.data).map((membership) => [text(membership.user_id), membership]));
  const scoresById = new Map(rows(leaderboardResult.data).map((entry) => [text(entry.user_id), numeric(entry.points)]));
  const participants = assignments.map((assignment) => {
    const id = text(assignment.user_id);
    const profile = profilesById.get(id) ?? {};
    const membership = membershipsById.get(id) ?? {};
    return {
      id: text(profile.id),
      username: text(profile.username, "member"),
      displayName: text(profile.display_name, "Member"),
      avatarUrl: nullableText(profile.avatar_url),
      role: text(membership.role, "member"),
      points: scoresById.get(id) ?? 0,
    };
  });
  return {
    challenge: mapChallenge(result.data, assignmentResult.data, assignments.length),
    ...(assignmentResult.data ? { assignment: {
      id: text(row(assignmentResult.data).id),
      challengeId,
      userId: user.id,
      status: text(row(assignmentResult.data).status),
      updatedAt: text(row(assignmentResult.data).updated_at),
    } } : {}),
    participants,
  };
}

async function getGroupDetail(client: SupabaseClient, groupId: string): Promise<Row> {
  const groupResult = await client.from("groups").select("id,name,description,owner_id,created_at").eq("id", groupId).maybeSingle();
  if (groupResult.error) throw groupResult.error;
  if (!groupResult.data) throw new ArenaError(404, "Group not found.");
  const membershipsResult = await client.from("memberships").select("user_id,role").eq("group_id", groupId).limit(100);
  if (membershipsResult.error) throw membershipsResult.error;
  const memberships = rows(membershipsResult.data);
  const userIds = memberships.map((membership) => text(membership.user_id));
  const [profilesResult, memberRows] = await Promise.all([
    userIds.length ? client.from("profiles").select("id,username,display_name,avatar_url").in("id", userIds) : { data: [], error: null },
    client.from("memberships").select("group_id").eq("group_id", groupId).limit(100),
  ]);
  if (profilesResult.error) throw profilesResult.error;
  if (memberRows.error) throw memberRows.error;
  const profilesById = new Map(rows(profilesResult.data).map((profile) => [text(profile.id), profile]));
  const leaderboardResult = await client.rpc("group_leaderboard", { p_group_id: groupId, p_window: "all-time" });
  if (leaderboardResult.error) throw leaderboardResult.error;
  const scores = new Map(rows(leaderboardResult.data).map((entry) => [text(entry.user_id), numeric(entry.points)]));
  const group = mapGroup(groupResult.data, rows(memberRows.data).length);
  const members = memberships.map((membership) => {
    const id = text(membership.user_id);
    const profile = profilesById.get(id) ?? {};
    return {
      id,
      username: text(profile.username, "member"),
      displayName: text(profile.display_name, "Member"),
      avatarUrl: nullableText(profile.avatar_url),
      role: text(membership.role, "member"),
      points: scores.get(id) ?? 0,
    };
  });
  return { group, members, inviteCode: null };
}

async function listReviews(client: SupabaseClient, user: User): Promise<Row[]> {
  const result = await client.from("submissions")
    .select("id,assignment_id,answer_text,evidence_path,status,review_reason,submitted_at")
    .eq("status", "submitted")
    .order("submitted_at", { ascending: true })
    .limit(100);
  if (result.error) throw result.error;
  const submissions = rows(result.data);
  if (!submissions.length) return [];
  const assignmentIds = submissions.map((submission) => text(submission.assignment_id));
  const assignmentResult = await client.from("assignments").select("id,user_id,challenge_id").in("id", assignmentIds);
  if (assignmentResult.error) throw assignmentResult.error;
  const assignments = rows(assignmentResult.data);
  const userIds = [...new Set(assignments.map((assignment) => text(assignment.user_id)))];
  const challengeIds = [...new Set(assignments.map((assignment) => text(assignment.challenge_id)))];
  const [profilesResult, challengesResult] = await Promise.all([
    userIds.length ? client.from("profiles").select("id,username,display_name").in("id", userIds) : { data: [], error: null },
    challengeIds.length ? client.from("challenges").select("id,title,creator_id,group_id").in("id", challengeIds) : { data: [], error: null },
  ]);
  if (profilesResult.error) throw profilesResult.error;
  if (challengesResult.error) throw challengesResult.error;
  const groupIds = [...new Set(rows(challengesResult.data).map((challenge) => text(challenge.group_id)))];
  const groupsResult = groupIds.length
    ? await client.from("groups").select("id,owner_id").in("id", groupIds)
    : { data: [], error: null };
  if (groupsResult.error) throw groupsResult.error;
  const byAssignment = new Map(assignments.map((assignment) => [text(assignment.id), assignment]));
  const byProfile = new Map(rows(profilesResult.data).map((profile) => [text(profile.id), profile]));
  const byChallenge = new Map(rows(challengesResult.data).map((challenge) => [text(challenge.id), challenge]));
  const ownerByGroup = new Map(rows(groupsResult.data).map((group) => [text(group.id), text(group.owner_id)]));
  return submissions.filter((submission) => {
    const assignment = byAssignment.get(text(submission.assignment_id)) ?? {};
    const challenge = byChallenge.get(text(assignment.challenge_id)) ?? {};
    return text(assignment.user_id) !== user.id
      && (text(challenge.creator_id) === user.id || ownerByGroup.get(text(challenge.group_id)) === user.id);
  }).map((submission) => {
    const assignment = byAssignment.get(text(submission.assignment_id)) ?? {};
    return mapSubmission(
      submission,
      byProfile.get(text(assignment.user_id)) ?? { id: assignment.user_id },
      byChallenge.get(text(assignment.challenge_id)) ?? { id: assignment.challenge_id },
    );
  });
}

async function mapCreatedSubmission(client: SupabaseClient, submissionValue: unknown): Promise<Row> {
  const submission = row(submissionValue);
  const assignmentResult = await client.from("assignments").select("user_id,challenge_id").eq("id", text(submission.assignment_id)).maybeSingle();
  if (assignmentResult.error) throw assignmentResult.error;
  if (!assignmentResult.data) throw new ArenaError(404, "Submission not found.");
  const assignment = row(assignmentResult.data);
  const [profileResult, challengeResult] = await Promise.all([
    client.from("profiles").select("id,username,display_name").eq("id", text(assignment.user_id)).maybeSingle(),
    client.from("challenges").select("id,title").eq("id", text(assignment.challenge_id)).maybeSingle(),
  ]);
  if (profileResult.error) throw profileResult.error;
  if (challengeResult.error) throw challengeResult.error;
  return mapSubmission(submission, profileResult.data ?? {}, challengeResult.data ?? {});
}

router.get("/arena/dashboard", route(async (req, res) => {
  const { client, user } = getContext(req);
  const [profile, groups, challenges, reviews, weeklyResult, activityResult] = await Promise.all([
    getProfile(client, user),
    listGroups(client, user),
    listChallenges(client, user, {}),
    listReviews(client, user),
    client.rpc("get_weekly_points"),
    client.from("points_ledger")
      .select("id,points,created_at,challenge:challenges(title),group:groups(name)")
      .eq("user_id", user.id).order("created_at", { ascending: false }).limit(6),
  ]);
  if (weeklyResult.error) throw weeklyResult.error;
  if (activityResult.error) throw activityResult.error;
  const recentActivity = rows(activityResult.data).map((activity) => {
    const challengeValue = Array.isArray(activity.challenge) ? activity.challenge[0] : activity.challenge;
    const groupValue = Array.isArray(activity.group) ? activity.group[0] : activity.group;
    return {
      id: text(activity.id),
      points: numeric(activity.points),
      createdAt: text(activity.created_at),
      challengeTitle: text(row(challengeValue).title, "Challenge completed"),
      groupName: text(row(groupValue).name, "Group"),
    };
  });
  res.json({
    profile,
    challenges: challenges.filter((challenge) => challenge.status !== "approved" && challenge.status !== "cancelled" && challenge.status !== "expired").slice(0, 8),
    groups,
    pendingReviews: reviews.length,
    weeklyPoints: numeric(weeklyResult.data),
    recentActivity,
  });
}));

router.get("/arena/challenges", route(async (req, res) => {
  const parsed = ListChallengesQueryParams.safeParse(req.query);
  if (!parsed.success) throw new ArenaError(400, "Search filters are invalid.");
  const { client, user } = getContext(req);
  res.json(await listChallenges(client, user, parsed.data as Row));
}));

router.post("/arena/challenges", route(async (req, res) => {
  const parsed = CreateChallengeBody.safeParse(req.body);
  if (!parsed.success) throw new ArenaError(400, "Check the challenge details and try again.");
  const { client, user } = getContext(req);
  const input = parsed.data;
  const created = await client.rpc("create_challenge", {
    p_group_id: input.groupId,
    p_title: input.title,
    p_instructions: input.instructions,
    p_category: input.category,
    p_difficulty: input.difficulty,
    p_points: input.points,
    p_duration_minutes: input.durationMinutes,
    p_completion_method: input.completionMethod,
    p_deadline: input.deadline ?? null,
    p_safety_notes: input.safetyNotes ?? null,
    p_participant_ids: input.participantIds,
    p_template_id: null,
    p_max_attempts: input.maxAttempts ?? 3,
  });
  if (created.error) throw created.error;
  const detail = await getChallengeDetail(client, user, text(created.data));
  res.status(201).json(detail.challenge);
}));

router.get("/arena/challenges/:challengeId", route(async (req, res) => {
  const params = GetChallengeParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Challenge id is invalid.");
  const { client, user } = getContext(req);
  res.json(await getChallengeDetail(client, user, params.data.challengeId));
}));

router.patch("/arena/challenges/:challengeId", route(async (req, res) => {
  const params = UpdateChallengeParams.safeParse(req.params);
  const parsed = UpdateChallengeBody.safeParse(req.body);
  if (!params.success || !parsed.success) throw new ArenaError(400, "Challenge update is invalid.");
  const { client, user } = getContext(req);
  const { data, error } = await client.rpc("update_challenge", { p_challenge_id: params.data.challengeId, p_input: parsed.data });
  if (error) throw error;
  const detail = await getChallengeDetail(client, user, params.data.challengeId);
  const updated = row(data);
  res.json(mapChallenge(updated, detail.assignment, rows(detail.participants).length));
}));

router.post("/arena/challenges/:challengeId/start", route(async (req, res) => {
  const params = StartChallengeParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Challenge id is invalid.");
  const { client, user } = getContext(req);
  const { data, error } = await client.rpc("start_challenge", { p_challenge_id: params.data.challengeId });
  if (error) throw error;
  const assignment = row(data);
  res.json({
    id: text(assignment.id),
    challengeId: params.data.challengeId,
    userId: user.id,
    status: text(assignment.status),
    updatedAt: text(assignment.updated_at),
  });
}));

router.post("/arena/challenges/:challengeId/submit", route(async (req, res) => {
  const params = SubmitChallengeParams.safeParse(req.params);
  const parsed = SubmitChallengeBody.safeParse(req.body);
  if (!params.success || !parsed.success) throw new ArenaError(400, "Submission details are invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("submit_challenge", {
    p_challenge_id: params.data.challengeId,
    p_answer_text: parsed.data.answerText ?? null,
    p_evidence_path: parsed.data.evidencePath ?? null,
    p_confirm_complete: parsed.data.confirmComplete,
  });
  if (error) throw error;
  res.status(201).json(await mapCreatedSubmission(client, data));
}));

router.get("/arena/challenge-templates", route(async (req, res) => {
  const { client } = getContext(req);
  const { data, error } = await client.from("challenge_templates").select("*").order("category").order("title").limit(100);
  if (error) throw error;
  res.json(rows(data).map((challenge) => mapChallenge(challenge, undefined, 0, true)));
}));

router.get("/arena/groups", route(async (req, res) => {
  const { client, user } = getContext(req);
  res.json(await listGroups(client, user));
}));

router.post("/arena/groups", route(async (req, res) => {
  const parsed = CreateGroupBody.safeParse(req.body);
  if (!parsed.success) throw new ArenaError(400, "Group details are invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("create_group", {
    p_name: parsed.data.name,
    p_description: parsed.data.description ?? null,
  });
  if (error) throw error;
  const detail = await getGroupDetail(client, text(data));
  res.status(201).json(detail.group);
}));

router.post("/arena/groups/join", route(async (req, res) => {
  const parsed = JoinGroupBody.safeParse(req.body);
  if (!parsed.success) throw new ArenaError(400, "Invitation code is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("join_group", { p_code: parsed.data.code });
  if (error) throw error;
  const detail = await getGroupDetail(client, text(data));
  res.json(detail.group);
}));

router.get("/arena/groups/:groupId", route(async (req, res) => {
  const params = GetGroupParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Group id is invalid.");
  const { client } = getContext(req);
  res.json(await getGroupDetail(client, params.data.groupId));
}));

router.patch("/arena/groups/:groupId", route(async (req, res) => {
  const params = UpdateGroupParams.safeParse(req.params);
  const parsed = UpdateGroupBody.safeParse(req.body);
  if (!params.success || !parsed.success || !Object.keys(parsed.data).length) throw new ArenaError(400, "Group update is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.from("groups").update({
    ...(parsed.data.name !== undefined ? { name: parsed.data.name.trim() } : {}),
    ...(parsed.data.description !== undefined ? { description: parsed.data.description?.trim() || null } : {}),
  }).eq("id", params.data.groupId).select("id,name,description,owner_id,created_at").maybeSingle();
  if (error) throw error;
  if (!data) notFound(null, "Group not found.");
  const detail = await getGroupDetail(client, params.data.groupId);
  res.json(detail.group);
}));

router.post("/arena/groups/:groupId/invite", route(async (req, res) => {
  const params = CreateGroupInvitationParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Group id is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("create_group_invitation", { p_group_id: params.data.groupId });
  if (error) throw error;
  const invitation = Array.isArray(data) ? row(data[0]) : row(data);
  res.status(201).json({ code: text(invitation.code), expiresAt: text(invitation.expires_at) });
}));

router.delete("/arena/groups/:groupId/members/:userId", route(async (req, res) => {
  const params = RemoveGroupMemberParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Group member id is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("remove_group_member", {
    p_group_id: params.data.groupId,
    p_user_id: params.data.userId,
  });
  if (error) throw error;
  res.json({ ok: boolean(data), id: params.data.userId, message: "Member removed." });
}));

router.delete("/arena/groups/:groupId/membership", route(async (req, res) => {
  const params = LeaveGroupParams.safeParse(req.params);
  if (!params.success) throw new ArenaError(400, "Group id is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("leave_group", { p_group_id: params.data.groupId });
  if (error) throw error;
  res.json({ ok: boolean(data), id: params.data.groupId, message: "You left the group." });
}));

router.get("/arena/reviews", route(async (req, res) => {
  const { client, user } = getContext(req);
  res.json(await listReviews(client, user));
}));

router.post("/arena/submissions/:submissionId/review", route(async (req, res) => {
  const params = ReviewSubmissionParams.safeParse(req.params);
  const parsed = ReviewSubmissionBody.safeParse(req.body);
  if (!params.success || !parsed.success) throw new ArenaError(400, "Review details are invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("review_submission", {
    p_submission_id: params.data.submissionId,
    p_decision: parsed.data.decision,
    p_reason: parsed.data.reason ?? null,
  });
  if (error) throw error;
  res.json(await mapCreatedSubmission(client, data));
}));

router.get("/arena/leaderboard", route(async (req, res) => {
  const parsed = GetLeaderboardQueryParams.safeParse(req.query);
  if (!parsed.success || !parsed.data.groupId) throw new ArenaError(400, "Choose a group to view its leaderboard.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("group_leaderboard", {
    p_group_id: parsed.data.groupId,
    p_window: parsed.data.window ?? "all-time",
  });
  if (error) throw error;
  res.json(rows(data).map((entry) => ({
    rank: numeric(entry.rank),
    userId: text(entry.user_id),
    username: text(entry.username),
    displayName: text(entry.display_name),
    avatarUrl: nullableText(entry.avatar_url),
    points: numeric(entry.points),
    completedChallenges: numeric(entry.completed_challenges),
  })));
}));

router.get("/arena/profile", route(async (req, res) => {
  const { client, user } = getContext(req);
  res.json(await getProfile(client, user));
}));

router.patch("/arena/profile", route(async (req, res) => {
  const parsed = UpdateProfileBody.safeParse(req.body);
  if (!parsed.success || !Object.keys(parsed.data).length) throw new ArenaError(400, "Profile details are invalid.");
  const { client, user } = getContext(req);
  const update = {
    ...(parsed.data.username !== undefined ? { username: parsed.data.username.trim() } : {}),
    ...(parsed.data.displayName !== undefined ? { display_name: parsed.data.displayName.trim() } : {}),
    ...(parsed.data.avatarUrl !== undefined ? { avatar_url: parsed.data.avatarUrl } : {}),
  };
  const { error } = await client.from("profiles").update(update).eq("id", user.id);
  if (error) throw error;
  res.json(await getProfile(client, user));
}));

router.get("/arena/reports", route(async (req, res) => {
  const { client } = getContext(req);
  const { data, error } = await client.from("reports")
    .select("id,reporter_id,target_type,target_id,reason,status,created_at,reviewed_at,reviewed_by")
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) throw error;
  res.json(rows(data).map((report) => ({
    id: text(report.id),
    reporterId: text(report.reporter_id),
    targetType: text(report.target_type),
    targetId: text(report.target_id),
    reason: text(report.reason),
    status: text(report.status),
    createdAt: text(report.created_at),
    reviewedAt: nullableText(report.reviewed_at),
    reviewedBy: nullableText(report.reviewed_by),
  })));
}));

router.post("/arena/reports", route(async (req, res) => {
  const parsed = CreateReportBody.safeParse(req.body);
  if (!parsed.success) throw new ArenaError(400, "Report details are invalid.");
  const { client, user } = getContext(req);
  const { data, error } = await client.from("reports").insert({
    reporter_id: user.id,
    target_type: parsed.data.targetType,
    target_id: parsed.data.targetId,
    reason: parsed.data.reason.trim(),
  }).select("id").single();
  if (error) throw error;
  res.status(201).json({ ok: true, id: text(row(data).id), message: "Report sent to the relevant group owner." });
}));

router.post("/arena/reports/:reportId/review", route(async (req, res) => {
  const params = ReviewReportParams.safeParse(req.params);
  const parsed = ReviewReportBody.safeParse(req.body);
  if (!params.success || !parsed.success) throw new ArenaError(400, "Report review is invalid.");
  const { client } = getContext(req);
  const { data, error } = await client.rpc("review_report", {
    p_report_id: params.data.reportId,
    p_decision: parsed.data.decision,
  });
  if (error) throw error;
  const report = row(data);
  res.json({
    id: text(report.id),
    reporterId: text(report.reporter_id),
    targetType: text(report.target_type),
    targetId: text(report.target_id),
    reason: text(report.reason),
    status: text(report.status),
    createdAt: text(report.created_at),
    reviewedAt: nullableText(report.reviewed_at),
    reviewedBy: nullableText(report.reviewed_by),
  });
}));

export default router;
