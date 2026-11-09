-- 369 V10: server-authoritative demo wallet
-- Run this whole script in Supabase Dashboard > SQL Editor.
-- Before testing, enable Authentication > Providers > Anonymous Sign-Ins.
-- This wallet uses test coins only; it has no cash value.

create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallet_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount <> 0),
  description text not null default 'Giao dịch xu',
  created_at timestamptz not null default now()
);

alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;

drop policy if exists "wallet owner can read own wallet" on public.wallets;
create policy "wallet owner can read own wallet"
  on public.wallets for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "wallet owner can read own transactions" on public.wallet_transactions;
create policy "wallet owner can read own transactions"
  on public.wallet_transactions for select to authenticated
  using (auth.uid() = user_id);

revoke all on public.wallets from anon, authenticated;
revoke all on public.wallet_transactions from anon, authenticated;
grant select on public.wallets to authenticated;
grant select on public.wallet_transactions to authenticated;

create or replace function public.wallet_create_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.wallets(user_id, balance) values (new.id, 1000)
  on conflict (user_id) do nothing;
  insert into public.wallet_transactions(user_id, amount, description)
  values (new.id, 1000, 'Xu thử nghiệm chào mừng');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_wallet on auth.users;
create trigger on_auth_user_created_wallet
  after insert on auth.users
  for each row execute function public.wallet_create_for_new_user();

create or replace function public.wallet_get_my_balance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_balance bigint;
  v_transactions jsonb;
begin
  if v_user is null then
    raise exception 'Bạn cần đăng nhập để xem ví.';
  end if;
  select balance into v_balance from public.wallets where user_id = v_user;
  if v_balance is null then
    raise exception 'Ví chưa được khởi tạo. Hãy đăng xuất và đăng nhập lại.';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'amount', amount, 'description', description, 'created_at', created_at
  ) order by created_at desc), '[]'::jsonb)
  into v_transactions
  from (
    select amount, description, created_at
    from public.wallet_transactions
    where user_id = v_user
    order by created_at desc
    limit 30
  ) recent;
  return jsonb_build_object('balance', v_balance, 'transactions', v_transactions);
end;
$$;

create or replace function public.wallet_spend_xu(
  p_amount bigint,
  p_description text default 'Chi tiêu trong game'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_balance bigint;
begin
  if v_user is null then
    raise exception 'Bạn cần đăng nhập để sử dụng ví.';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then
    raise exception 'Số xu giao dịch không hợp lệ.';
  end if;
  select balance into v_balance
    from public.wallets
    where user_id = v_user
    for update;
  if v_balance is null then
    raise exception 'Ví chưa được khởi tạo.';
  end if;
  if v_balance < p_amount then
    raise exception 'Số dư xu không đủ.';
  end if;
  update public.wallets
    set balance = balance - p_amount, updated_at = now()
    where user_id = v_user
    returning balance into v_balance;
  insert into public.wallet_transactions(user_id, amount, description)
    values (v_user, -p_amount, left(coalesce(p_description, 'Chi tiêu trong game'), 120));
  return public.wallet_get_my_balance();
end;
$$;

revoke all on function public.wallet_get_my_balance() from public, anon;
revoke all on function public.wallet_spend_xu(bigint, text) from public, anon;
grant execute on function public.wallet_get_my_balance() to authenticated;
grant execute on function public.wallet_spend_xu(bigint, text) to authenticated;
