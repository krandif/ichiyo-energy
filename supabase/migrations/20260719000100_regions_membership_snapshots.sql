-- ============================================================
-- 多拠点（regions）＋ 期間所属の履歴（team_memberships）
-- ＋ 成績の発生時点スナップショット ＋ team_leader スコープRLS
--
-- DESIGN.md §3(4階層)・§4(時間軸の所属・成績の履歴方針) にスキーマを整合させる。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 拠点（region）: チームの上位。多拠点の集計軸
-- ------------------------------------------------------------
create table regions (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,          -- 愛媛 / 千葉 …
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table teams
  add column region_id uuid references regions(id) on delete set null;
create index on teams (region_id);

-- ------------------------------------------------------------
-- 2. 期間所属の履歴（イミュータブル）。「いつどのチーム/拠点だったか」の正
--    members.team_id / region_id は「今どこか」の高速参照キャッシュとして残す
-- ------------------------------------------------------------
alter table members
  add column region_id uuid references regions(id) on delete set null;

create table team_memberships (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references members(id) on delete cascade,
  team_id    uuid not null references teams(id) on delete restrict,
  region_id  uuid references regions(id) on delete set null,
  period     tstzrange not null,
  reason     text,
  created_at timestamptz not null default now(),

  -- 同一メンバーの所属期間が重複しない
  exclude using gist (
    member_id with =,
    period    with &&
  )
);
create index on team_memberships (member_id);
create index on team_memberships (team_id);

-- ------------------------------------------------------------
-- 3. 成績の発生時点スナップショット（現在の所属から都度導出しない）
--    異動しても過去成績が付け替わらないようにする
-- ------------------------------------------------------------
alter table deals
  add column team_id   uuid references teams(id)   on delete set null,
  add column region_id uuid references regions(id) on delete set null;
create index on deals (team_id);

alter table activity_logs
  add column team_id uuid references teams(id) on delete set null;
create index on activity_logs (team_id);

alter table commissions
  add column team_id   uuid references teams(id)   on delete set null,
  add column region_id uuid references regions(id) on delete set null;

-- ------------------------------------------------------------
-- 4. ヘルパー: 任意時点の所属を解決（RLSを迂回して確実に引くため security definer）
-- ------------------------------------------------------------
create or replace function team_at(p_member uuid, p_ts timestamptz)
returns uuid
language sql stable security definer set search_path = public
as $$
  select team_id from team_memberships
  where member_id = p_member and period @> p_ts
  order by lower(period) desc
  limit 1;
$$;

create or replace function region_at(p_member uuid, p_ts timestamptz)
returns uuid
language sql stable security definer set search_path = public
as $$
  select region_id from team_memberships
  where member_id = p_member and period @> p_ts
  order by lower(period) desc
  limit 1;
$$;

-- RLS 用: ログインユーザーの現在チーム（JWT クレームから）
create or replace function auth_team()
returns uuid
language sql stable
as $$
  select nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'team_id',
    ''
  )::uuid;
$$;

-- ------------------------------------------------------------
-- 5. Custom Access Token Hook を更新（team_id クレームを追加）
-- ------------------------------------------------------------
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  claims jsonb;
  m record;
begin
  select id, role, status, team_id into m
  from public.members
  where auth_user_id = (event->>'user_id')::uuid;

  claims := event->'claims';

  if m.id is not null then
    claims := jsonb_set(claims, '{app_role}',      to_jsonb(m.role::text));
    claims := jsonb_set(claims, '{member_id}',     to_jsonb(m.id::text));
    claims := jsonb_set(claims, '{member_status}', to_jsonb(m.status::text));
    claims := jsonb_set(claims, '{team_id}',       coalesce(to_jsonb(m.team_id::text), 'null'::jsonb));
  else
    claims := jsonb_set(claims, '{app_role}',      '"member"');
    claims := jsonb_set(claims, '{member_status}', '"pending"');
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;

-- ------------------------------------------------------------
-- 6. 発生時点スナップショットを自動で刻むトリガー
--    （team_id/region_id が未指定なら、当該repの所属履歴から埋める）
-- ------------------------------------------------------------
create or replace function stamp_deal_team()
returns trigger language plpgsql as $$
declare
  ts timestamptz := coalesce(new.contracted_on::timestamptz, now());
begin
  if new.team_id   is null then new.team_id   := team_at(new.rep_id, ts);   end if;
  if new.region_id is null then new.region_id := region_at(new.rep_id, ts); end if;
  return new;
end $$;

create trigger deals_stamp_team
  before insert on deals
  for each row execute function stamp_deal_team();

create or replace function stamp_activity_team()
returns trigger language plpgsql as $$
begin
  if new.team_id is null then
    new.team_id := team_at(new.member_id, coalesce(new.occurred_at, now()));
  end if;
  return new;
end $$;

create trigger activity_stamp_team
  before insert on activity_logs
  for each row execute function stamp_activity_team();

-- ------------------------------------------------------------
-- 7. RLS: 新テーブル
-- ------------------------------------------------------------
alter table regions          enable row level security;
alter table team_memberships enable row level security;

-- regions: 全 active 会員が読める / 更新は sysadmin
create policy regions_select on regions
  for select using (auth_is_active());
create policy regions_admin on regions
  for all using (auth_role() = 'sysadmin') with check (auth_role() = 'sysadmin');

-- team_memberships: 本人 + 管理者が読める / 書きは管理者
create policy team_memberships_select on team_memberships
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy team_memberships_write on team_memberships
  for all using (is_admin()) with check (is_admin());

-- ------------------------------------------------------------
-- 8. team_leader スコープ: 自チームの案件を編集できる
--    （既存の member/admin 向けポリシーに OR で追加される）
-- ------------------------------------------------------------
create policy deals_insert_leader on deals
  for insert with check (
    auth_is_active() and auth_role() = 'team_leader' and team_id = auth_team()
  );

create policy deals_update_leader on deals
  for update using (
    auth_is_active() and auth_role() = 'team_leader' and team_id = auth_team()
  );
