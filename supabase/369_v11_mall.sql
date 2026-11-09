-- 369 V11 MALL: internal xu marketplace only. No cash-out or external payment.
create table if not exists public.mall_stores (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  store_name text not null check (char_length(trim(store_name)) between 2 and 40),
  description text not null default '' check (char_length(description) <= 240),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.mall_products (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.mall_stores(id) on delete cascade,
  seller_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 2 and 60),
  description text not null default '' check (char_length(description) <= 300),
  price_xu bigint not null check (price_xu between 1 and 100000000),
  stock integer not null default 1 check (stock between 0 and 100000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists mall_products_catalog_idx on public.mall_products(active, created_at desc);
create index if not exists mall_products_seller_idx on public.mall_products(seller_id);
create table if not exists public.mall_orders (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.mall_products(id),
  store_id uuid not null references public.mall_stores(id),
  buyer_id uuid not null references auth.users(id),
  seller_id uuid not null references auth.users(id),
  quantity integer not null check (quantity between 1 and 100),
  unit_price_xu bigint not null check (unit_price_xu > 0),
  total_xu bigint not null check (total_xu > 0),
  status text not null default 'paid_in_game' check (status in ('paid_in_game','cancelled')),
  created_at timestamptz not null default now()
);
create index if not exists mall_orders_buyer_idx on public.mall_orders(buyer_id,created_at desc);
create index if not exists mall_orders_seller_idx on public.mall_orders(seller_id,created_at desc);
alter table public.mall_stores enable row level security;
alter table public.mall_products enable row level security;
alter table public.mall_orders enable row level security;
drop policy if exists "mall stores public read active" on public.mall_stores;
create policy "mall stores public read active" on public.mall_stores for select to anon, authenticated using (active = true or owner_id = auth.uid());
drop policy if exists "mall products public read active" on public.mall_products;
create policy "mall products public read active" on public.mall_products for select to anon, authenticated using (active = true);
drop policy if exists "mall orders parties read" on public.mall_orders;
create policy "mall orders parties read" on public.mall_orders for select to authenticated using (buyer_id = auth.uid() or seller_id = auth.uid());
revoke all on public.mall_stores, public.mall_products, public.mall_orders from anon, authenticated;
grant select on public.mall_stores, public.mall_products to anon, authenticated;
grant select on public.mall_orders to authenticated;
create or replace function public.mall_get_catalog()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_items jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'store_id',p.store_id,'seller_id',p.seller_id,'store_name',s.store_name,'name',p.name,'description',p.description,'price_xu',p.price_xu,'stock',p.stock) order by p.created_at desc),'[]'::jsonb)
 into v_items from public.mall_products p join public.mall_stores s on s.id=p.store_id where p.active and p.stock>0 and s.active;
 return v_items;
end $$;
create or replace function public.mall_get_my_store()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_user uuid:=auth.uid(); v_store jsonb;
begin
 if v_user is null then raise exception 'Bạn cần đăng nhập.'; end if;
 select to_jsonb(s) into v_store from public.mall_stores s where s.owner_id=v_user;
 return coalesce(v_store,'null'::jsonb);
end $$;
create or replace function public.mall_save_store(p_name text,p_description text default '')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_user uuid:=auth.uid(); v_store public.mall_stores;
begin
 if v_user is null then raise exception 'Bạn cần đăng nhập.'; end if;
 if p_name is null or char_length(trim(p_name)) not between 2 and 40 then raise exception 'Tên gian hàng cần từ 2 đến 40 ký tự.'; end if;
 insert into public.mall_stores(owner_id,store_name,description) values(v_user,trim(p_name),left(coalesce(p_description,''),240))
 on conflict(owner_id) do update set store_name=excluded.store_name,description=excluded.description,active=true,updated_at=now() returning * into v_store;
 return to_jsonb(v_store);
end $$;
create or replace function public.mall_save_product(p_product_id uuid,p_name text,p_description text,p_price_xu bigint,p_stock integer)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_user uuid:=auth.uid(); v_store public.mall_stores; v_product public.mall_products;
begin
 if v_user is null then raise exception 'Bạn cần đăng nhập.'; end if;
 select * into v_store from public.mall_stores where owner_id=v_user and active for update;
 if not found then raise exception 'Bạn cần đăng ký gian hàng trước.'; end if;
 if p_name is null or char_length(trim(p_name)) not between 2 and 60 then raise exception 'Tên sản phẩm cần từ 2 đến 60 ký tự.'; end if;
 if p_price_xu is null or p_price_xu not between 1 and 100000000 then raise exception 'Giá xu không hợp lệ.'; end if;
 if p_stock is null or p_stock not between 0 and 100000 then raise exception 'Số lượng không hợp lệ.'; end if;
 if p_product_id is null then
  insert into public.mall_products(store_id,seller_id,name,description,price_xu,stock) values(v_store.id,v_user,trim(p_name),left(coalesce(p_description,''),300),p_price_xu,p_stock) returning * into v_product;
 else
  update public.mall_products set name=trim(p_name),description=left(coalesce(p_description,''),300),price_xu=p_price_xu,stock=p_stock,active=true,updated_at=now()
  where id=p_product_id and seller_id=v_user returning * into v_product;
  if not found then raise exception 'Không tìm thấy sản phẩm của gian hàng bạn.'; end if;
 end if;
 return to_jsonb(v_product);
end $$;
create or replace function public.mall_buy_product(p_product_id uuid,p_quantity integer default 1)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_buyer uuid:=auth.uid(); v_product public.mall_products; v_total bigint; v_buyer_balance bigint; v_seller_balance bigint; v_order_id bigint;
begin
 if v_buyer is null then raise exception 'Bạn cần đăng nhập.'; end if;
 if p_quantity is null or p_quantity not between 1 and 100 then raise exception 'Số lượng mua không hợp lệ.'; end if;
 select * into v_product from public.mall_products where id=p_product_id and active for update;
 if not found then raise exception 'Sản phẩm không còn được bán.'; end if;
 if v_product.stock<p_quantity then raise exception 'Gian hàng không đủ số lượng.'; end if;
 if v_product.seller_id=v_buyer then raise exception 'Bạn không thể tự mua sản phẩm của mình.'; end if;
 v_total:=v_product.price_xu*p_quantity;
 perform 1 from public.wallets where user_id in (v_buyer,v_product.seller_id) order by user_id for update;
 select balance into v_buyer_balance from public.wallets where user_id=v_buyer;
 select balance into v_seller_balance from public.wallets where user_id=v_product.seller_id;
 if v_buyer_balance is null or v_seller_balance is null then raise exception 'Ví người mua hoặc người bán chưa được khởi tạo.'; end if;
 if v_buyer_balance<v_total then raise exception 'Số dư xu của bạn không đủ.'; end if;
 update public.wallets set balance=balance-v_total,updated_at=now() where user_id=v_buyer;
 update public.wallets set balance=balance+v_total,updated_at=now() where user_id=v_product.seller_id;
 update public.mall_products set stock=stock-p_quantity,updated_at=now() where id=p_product_id;
 insert into public.wallet_transactions(user_id,amount,description) values(v_buyer,-v_total,'Mua hàng MALL: '||v_product.name),(v_product.seller_id,v_total,'Bán hàng MALL: '||v_product.name);
 insert into public.mall_orders(product_id,store_id,buyer_id,seller_id,quantity,unit_price_xu,total_xu) values(v_product.id,v_product.store_id,v_buyer,v_product.seller_id,p_quantity,v_product.price_xu,v_total) returning id into v_order_id;
 return jsonb_build_object('order_id',v_order_id,'product_name',v_product.name,'quantity',p_quantity,'total_xu',v_total,'buyer_balance',(select balance from public.wallets where user_id=v_buyer),'seller_balance',(select balance from public.wallets where user_id=v_product.seller_id),'remaining_stock',v_product.stock-p_quantity);
end $$;
revoke all on function public.mall_get_catalog() from public;
revoke all on function public.mall_get_my_store() from public;
revoke all on function public.mall_save_store(text,text) from public,anon;
revoke all on function public.mall_save_product(uuid,text,text,bigint,integer) from public,anon;
revoke all on function public.mall_buy_product(uuid,integer) from public,anon;
grant execute on function public.mall_get_catalog() to anon,authenticated;
grant execute on function public.mall_get_my_store() to authenticated;
grant execute on function public.mall_save_store(text,text) to authenticated;
grant execute on function public.mall_save_product(uuid,text,text,bigint,integer) to authenticated;
grant execute on function public.mall_buy_product(uuid,integer) to authenticated;
