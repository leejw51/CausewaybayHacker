-- 0006_drill_reason — the one line that makes AI mode feel like a coach.
--
-- PROTOCOL §5.8's `Drill` carries `reason`: why *this* plan, in one sentence.
-- It is written at creation alongside the plan itself, because a reconnect
-- must resume the same session — including the same explanation of it.

ALTER TABLE drills ADD COLUMN reason TEXT NOT NULL DEFAULT '';
