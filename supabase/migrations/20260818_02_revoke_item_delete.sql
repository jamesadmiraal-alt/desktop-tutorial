-- Remove the client's direct DELETE on stocktake_items, leaving
-- delete_stocktake_items() / clear_stocktake_items() (migration 01) as the only
-- ways to remove scanned items — both of which log what they removed.
--
-- *** RUN THIS ONLY AFTER THE NEW app.html IS DEPLOYED AND LIVE. ***
-- The previous app.html removes items with a direct
-- `delete from stocktake_items where id = ...`. Running this first breaks the
-- ✕ button for every operator still served the old page, which after a Pages
-- deploy includes anyone with it already open. That is the only reason this is a
-- separate migration from 01.
--
-- Both statements on purpose: dropping the policy alone leaves a table-level
-- GRANT that a later `create policy` would silently re-enable; revoking alone
-- leaves a policy reading as though staff can still delete.
--
-- Note this must ALSO live in schema.sql (it does) — Supabase's
-- `alter default privileges ... grant all on tables to anon, authenticated`
-- re-grants DELETE on every newly created table, so a rebuild without it
-- reopens the hole invisibly.
--
-- This does not affect `delete from stocktakes`: its cascade to stocktake_items
-- runs as the table owner with RLS forced off, not as the caller, so client
-- privileges are irrelevant to it. Verify after running:
--   1. deleting a stocktake still removes its items, and writes ONE
--      stocktake.deleted row carrying items_deleted/units_deleted;
--   2. a raw DELETE /rest/v1/stocktake_items?stocktake_id=eq.<uuid> with a
--      member JWT now fails with 42501 (insufficient_privilege).

drop policy if exists "org members delete items" on public.stocktake_items;
revoke delete on public.stocktake_items from authenticated, anon;
