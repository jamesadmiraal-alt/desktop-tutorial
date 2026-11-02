// RETIRED 2 Nov 2026 — refuses every call. Kept deployed (rather than deleted)
// so a page cached from before the change gets a clear answer instead of a 404.
//
// Team used to be "$59/mo base + $29/mo per extra person counting at the same
// time": this function set that number, organisations.concurrent_seats, and
// the matching Stripe subscription QUANTITY. Team is now a flat $79/mo with up
// to 10 people logged in at the same time (plan_people_at_once() in
// schema.sql, migration 20261102_01). On a flat price, changing the quantity
// multiplies the bill, so the one thing this function must never do any more
// is talk to Stripe. Hence the whole old body is gone, not just hidden.
//
// Deploy this version BEFORE the new pages and webhook go live (see
// STRIPE-SETUP.md §9). The previous code is in git history (before 2 Nov 2026).

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve((req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  return new Response(
    JSON.stringify({
      error: "Team now includes up to 10 people logged in at the same time, so there is nothing to buy here. "
        + "Need more than 10? Email hello@gantrystocktake.com about a Corporate plan.",
    }),
    { status: 410, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
  );
});
