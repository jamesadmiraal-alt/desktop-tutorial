-- Barscan schema for Supabase
-- Run this once in your Supabase project: Dashboard -> SQL Editor -> New query -> paste -> Run

create table if not exists public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stocktake_items (
  id uuid primary key default gen_random_uuid(),
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  barcode text not null,
  qty integer not null check (qty >= 1),
  first_scanned timestamptz not null default now(),
  last_scanned timestamptz not null default now(),
  unique (stocktake_id, barcode)
);

create index if not exists stocktakes_user_idx on public.stocktakes (user_id, updated_at desc);
create index if not exists items_stocktake_idx on public.stocktake_items (stocktake_id);

-- Keep the parent stocktake's updated_at fresh whenever its items change
create or replace function public.touch_stocktake()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.stocktakes
     set updated_at = now()
   where id = coalesce(new.stocktake_id, old.stocktake_id);
  return coalesce(new, old);
end $$;

drop trigger if exists touch_stocktake_on_items on public.stocktake_items;
create trigger touch_stocktake_on_items
  after insert or update or delete on public.stocktake_items
  for each row execute function public.touch_stocktake();

-- Row Level Security: each user can only see and modify their own rows
alter table public.stocktakes enable row level security;
alter table public.stocktake_items enable row level security;

drop policy if exists "own stocktakes" on public.stocktakes;
create policy "own stocktakes" on public.stocktakes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own items" on public.stocktake_items;
create policy "own items" on public.stocktake_items
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
