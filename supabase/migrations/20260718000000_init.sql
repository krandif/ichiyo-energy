-- ============================================================
-- ICHIYO 社内システム / Supabase Schema
-- PostgreSQL 15+ / PostGIS / RLS
-- ============================================================

-- ------------------------------------------------------------
-- 0. Extensions
-- ------------------------------------------------------------
create extension if not exists "uuid-ossp";
create extension if not exists postgis;
create extension if not exists btree_gist;   -- tstzrange + uuid の排他制約に必要
create extension if not exists pg_cron;      -- 日次同期バッチ用(任意)

-- ------------------------------------------------------------
-- 1. ENUM 型
-- ------------------------------------------------------------
create type app_role as enum ('sysadmin', 'director', 'member');
create type member_status as enum ('pending', 'active', 'suspended', 'left');
create type job_type as enum ('sales', 'office');           -- 販売員 / 営業事務
create type contract_type as enum ('fixed_term', 'indefinite'); -- 契約社員 / 正社員
create type rank_code as enum ('A', 'B', 'C', 'D', 'E');

create type property_type as enum ('detached', 'apartment', 'other');
create type visit_status as enum ('new', 'visited', 'appointed', 'contracted', 'recognized', 'rejected');

create type deal_stage as enum ('stage1', 'stage2');
create type deal_status as enum (
  'draft', 'contracted', 'cooling_off', 'construction_scheduled',
  'constructed', 'inspected', 'recognized', 'cancelled'
);
create type activity_kind as enum ('visit', 'appointment', 'contract', 'cancel', 'note');
create type commission_kind as enum ('appointment', 'contract', 'clawback', 'adjustment');
create type doc_scope as enum ('policy', 'employment');
create type outbox_status as enum ('pending', 'sent', 'failed', 'skipped');
create type construction_type as enum ('in_house', 'outsourced');

-- ============================================================
-- 2. 人・組織
-- ============================================================

-- 2.1 チーム
create table teams (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,          -- 西条チーム / 新居浜チーム
  lw_org_id    text unique,                   -- LINE WORKS の組織ID
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 2.2 メンバー（公開情報のみ。全員が読める）
create table members (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users(id) on delete set null,
  lw_user_id    text unique not null,          -- LINE WORKS userId。同期の突合キー
  lw_login_id   text,                          -- name@company.com 形式
  display_name  text not null,
  team_id       uuid references teams(id) on delete set null,
  job_type      job_type not null default 'sales',
  role          app_role not null default 'member',
  status        member_status not null default 'pending',
  joined_on     date,
  left_on       date,
  avatar_url    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint left_requires_date check (status <> 'left' or left_on is not null)
);
create index on members (team_id);
create index on members (status);
create index on members (lw_user_id);

-- 2.3 メンバー個人情報（本人 + sysadmin + director のみ）
create table member_private (
  member_id       uuid primary key references members(id) on delete cascade,
  legal_name      text not null,
  legal_name_kana text,
  birth_date      date,
  email           text,
  phone           text,
  postal_code     text,
  address         text,
  emergency_name  text,
  emergency_phone text,
  bank_name       text,
  bank_branch     text,
  bank_account    text,
  freee_employee_id text,                     -- freee人事労務の従業員ID
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ============================================================
-- 3. 報酬制度
-- ============================================================

-- 3.1 ランク定義マスタ（ランク×職種で固定給・アポ単価が決まる）
create table rank_master (
  id                 uuid primary key default gen_random_uuid(),
  rank               rank_code not null,
  job_type           job_type not null,
  base_salary        integer not null,          -- 月額固定給(円)
  appointment_unit   integer not null default 0,-- アポ1件あたり歩合(円)
  contract_unit      integer not null default 0,-- 成約1件あたり歩合(円)
  valid_from         date not null,
  valid_to           date,                      -- null = 現行
  created_at         timestamptz not null default now(),

  unique (rank, job_type, valid_from),
  constraint salary_positive check (base_salary >= 0)
);

-- 3.2 ランク履歴（不変。期間重複を制約で禁止）
create table rank_history (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id) on delete cascade,
  rank        rank_code not null,
  period      tstzrange not null,
  reason      text,
  decided_by  uuid references members(id),
  created_at  timestamptz not null default now(),

  exclude using gist (
    member_id with =,
    period    with &&
  )
);
create index on rank_history (member_id);

-- 3.3 雇用契約期間（個別の給与上書きを保持）
create table rep_contracts (
  id                 uuid primary key default gen_random_uuid(),
  member_id          uuid not null references members(id) on delete cascade,
  contract_type      contract_type not null,
  period             tstzrange not null,
  base_salary_override    integer,             -- null なら rank_master に従う
  appointment_unit_override integer,
  contract_unit_override    integer,
  doc_id             uuid,                     -- employment_docs への参照(後で FK)
  created_at         timestamptz not null default now(),

  exclude using gist (
    member_id with =,
    period    with &&
  )
);
create index on rep_contracts (member_id);

-- ============================================================
-- 4. 顧客・物件
-- ============================================================

create table properties (
  id             uuid primary key default gen_random_uuid(),
  address        text not null,
  building_name  text,
  property_type  property_type not null default 'detached',
  geom           geography(Point, 4326) not null,
  status         visit_status not null default 'new',
  area_id        uuid,                          -- areas への参照(後で FK)
  household_name text,                          -- 表札名
  note           text,
  last_visited_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index properties_geom_idx on properties using gist (geom);
create index on properties (status);
create index on properties (area_id);

-- 4.2 エリア（担当割当のポリゴン）
create table areas (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,                  -- 西条市大町 など
  boundary      geography(Polygon, 4326) not null,
  team_id       uuid references teams(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index areas_boundary_idx on areas using gist (boundary);

alter table properties
  add constraint properties_area_fk
  foreign key (area_id) references areas(id) on delete set null;

-- 4.3 エリア担当割当（メンバー×エリア×期間）
create table area_assignments (
  id          uuid primary key default gen_random_uuid(),
  area_id     uuid not null references areas(id) on delete cascade,
  member_id   uuid not null references members(id) on delete cascade,
  period      tstzrange not null,
  created_at  timestamptz not null default now(),

  exclude using gist (
    area_id   with =,
    member_id with =,
    period    with &&
  )
);

-- 4.4 顧客（世帯）
create table customers (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid references properties(id) on delete set null,
  name          text not null,
  name_kana     text,
  phone         text,
  email         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on customers (property_id);

-- ============================================================
-- 5. 商品
-- ============================================================

create table products (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,                  -- 太陽光パネル / 蓄電池 / エコキュート
  category     text not null,
  stage        deal_stage not null default 'stage1',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create table variants (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references products(id) on delete cascade,
  sku           text not null unique,
  model_name    text not null,
  maker         text,
  spec          jsonb not null default '{}',    -- 出力W・容量kWh 等
  cost_price    integer,                        -- 仕入原価
  list_price    integer not null,               -- 標準売価
  valid_from    date not null default current_date,
  valid_to      date,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index on variants (product_id);

-- ============================================================
-- 6. 案件・契約
-- ============================================================

create table deals (
  id                uuid primary key default gen_random_uuid(),
  deal_no           text unique not null,       -- 表示用の連番
  customer_id       uuid not null references customers(id) on delete restrict,
  property_id       uuid references properties(id) on delete set null,
  rep_id            uuid not null references members(id) on delete restrict, -- 担当営業
  closer_id         uuid references members(id) on delete set null,          -- クローザー
  stage             deal_stage not null default 'stage1',
  status            deal_status not null default 'draft',
  parent_deal_id    uuid references deals(id) on delete set null,            -- Stage2 の親

  contract_amount   integer not null default 0, -- 税込契約額
  loan_amount       integer,                    -- リフォームローン借入額
  contracted_on     date,
  cooling_off_start date,                       -- 起算日(書面交付日)
  cooling_off_end   date generated always as ((cooling_off_start + 8)::date) stored,
  constructed_on    date,
  inspected_on      date,                       -- 検収完了日 = 売上計上トリガー
  recognized_at     timestamptz,                -- freee連携完了日時
  cancelled_on      date,
  cancel_reason     text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint stage1_loan_cap check (
    stage <> 'stage1' or loan_amount is null or loan_amount <= 5000000
  ),
  constraint contracted_needs_date check (
    status = 'draft' or contracted_on is not null
  )
);
create index on deals (rep_id);
create index on deals (customer_id);
create index on deals (status);
create index on deals (inspected_on);
create index on deals (parent_deal_id);

-- 6.2 案件明細
create table deal_items (
  id          uuid primary key default gen_random_uuid(),
  deal_id     uuid not null references deals(id) on delete cascade,
  variant_id  uuid not null references variants(id) on delete restrict,
  quantity    integer not null default 1,
  unit_price  integer not null,                 -- 契約時点の売価をスナップショット
  subtotal    integer generated always as (quantity * unit_price) stored,
  created_at  timestamptz not null default now(),

  constraint qty_positive check (quantity > 0)
);
create index on deal_items (deal_id);

-- 6.3 書面交付チェック（特商法対応）
create table deal_documents (
  id             uuid primary key default gen_random_uuid(),
  deal_id        uuid not null references deals(id) on delete cascade,
  doc_kind       text not null,                 -- 契約書 / 重要事項説明書 / 概要書面
  delivered_on   date not null,
  delivered_by   uuid references members(id),
  file_path      text,                          -- Storage のパス
  created_at     timestamptz not null default now(),

  unique (deal_id, doc_kind)
);

-- ============================================================
-- 7. 工事・検収
-- ============================================================

create table contractors (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,                    -- ROY社 等
  phone       text,
  capacity_per_day integer default 1,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table constructions (
  id              uuid primary key default gen_random_uuid(),
  deal_id         uuid not null references deals(id) on delete cascade,
  type            construction_type not null default 'outsourced',
  contractor_id   uuid references contractors(id) on delete set null,
  scheduled_on    date,
  completed_on    date,
  inspected_on    date,
  inspected_by    uuid references members(id),
  passed          boolean,
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint inspect_after_cooling check (
    inspected_on is null or inspected_on >= scheduled_on
  )
);
create index on constructions (deal_id);
create index on constructions (scheduled_on);

create table construction_photos (
  id              uuid primary key default gen_random_uuid(),
  construction_id uuid not null references constructions(id) on delete cascade,
  file_path       text not null,
  caption         text,
  taken_at        timestamptz,
  uploaded_by     uuid references members(id),
  created_at      timestamptz not null default now()
);

-- ============================================================
-- 8. 仕入・発注
-- ============================================================

create table suppliers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  contact     text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table purchase_orders (
  id           uuid primary key default gen_random_uuid(),
  po_no        text unique not null,
  supplier_id  uuid not null references suppliers(id) on delete restrict,
  deal_id      uuid references deals(id) on delete set null,
  ordered_on   date not null default current_date,
  delivered_on date,
  total_amount integer not null default 0,
  status       text not null default 'ordered',
  created_at   timestamptz not null default now()
);

create table purchase_order_items (
  id                uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references purchase_orders(id) on delete cascade,
  variant_id        uuid not null references variants(id) on delete restrict,
  quantity          integer not null,
  unit_cost         integer not null
);

-- ============================================================
-- 9. 活動ログ・歩合
-- ============================================================

create table activity_logs (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members(id) on delete cascade,
  property_id  uuid references properties(id) on delete set null,
  deal_id      uuid references deals(id) on delete set null,
  kind         activity_kind not null,
  occurred_at  timestamptz not null default now(),
  geom         geography(Point, 4326),          -- 打刻時の位置
  note         text,
  created_at   timestamptz not null default now()
);
create index on activity_logs (member_id, occurred_at desc);
create index on activity_logs (deal_id);

-- 9.2 歩合（プラスもマイナス(クローバック)も同じテーブル）
create table commissions (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references members(id) on delete restrict,
  deal_id       uuid references deals(id) on delete set null,
  kind          commission_kind not null,
  target_month  date not null,                  -- 計算対象月(月初日で保持)
  amount        integer not null,               -- クローバックは負値
  unit_price    integer,                        -- 発生時点の単価スナップショット
  rank_snapshot rank_code,                      -- 発生時点のランク
  calculated_at timestamptz not null default now(),
  confirmed_at  timestamptz,                    -- 確定(締め)日時
  freee_synced_at timestamptz,
  note          text,

  constraint clawback_is_negative check (
    kind <> 'clawback' or amount < 0
  )
);
create index on commissions (member_id, target_month);
create index on commissions (deal_id);
create index on commissions (confirmed_at);

-- ============================================================
-- 10. 書類
-- ============================================================

-- 10.1 全社共通(就業規則・賃金規程) → 全員閲覧可
create table policy_docs (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  version      text not null,
  file_path    text not null,                   -- Storage: policy/
  effective_on date not null,
  superseded_on date,
  uploaded_by  uuid references members(id),
  created_at   timestamptz not null default now(),

  unique (title, version)
);

-- 10.2 個別(雇用契約書) → 本人 + sysadmin + director のみ
create table employment_docs (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members(id) on delete cascade,
  title        text not null,
  file_path    text not null,                   -- Storage: employment/{member_id}/
  signed_on    date,
  period       tstzrange,
  uploaded_by  uuid references members(id),
  created_at   timestamptz not null default now()
);
create index on employment_docs (member_id);

alter table rep_contracts
  add constraint rep_contracts_doc_fk
  foreign key (doc_id) references employment_docs(id) on delete set null;

-- 10.3 閲覧ログ（労務トラブル時の証跡）
create table doc_access_logs (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members(id) on delete cascade,
  scope       doc_scope not null,
  doc_id      uuid not null,
  accessed_at timestamptz not null default now(),
  ip          inet,
  user_agent  text
);
create index on doc_access_logs (member_id, accessed_at desc);

-- ============================================================
-- 11. SNS タブ
-- ============================================================

create table social_posts (
  id           uuid primary key default gen_random_uuid(),
  platform     text not null,                   -- x / instagram
  external_id  text not null,
  posted_at    timestamptz not null,
  content      text,
  media_urls   text[],
  permalink    text,
  metrics      jsonb default '{}',              -- likes / reposts 等
  fetched_at   timestamptz not null default now(),

  unique (platform, external_id)
);
create index on social_posts (posted_at desc);

-- ============================================================
-- 12. 外部連携（Outbox パターン）
-- ============================================================

create table integration_outbox (
  id            uuid primary key default gen_random_uuid(),
  target        text not null,                  -- freee_accounting / freee_hr / line_works
  event_type    text not null,                  -- deal.recognized / commission.confirmed
  payload       jsonb not null,
  idempotency_key text unique not null,         -- 二重送信防止
  status        outbox_status not null default 'pending',
  attempts      integer not null default 0,
  last_error    text,
  scheduled_at  timestamptz not null default now(),
  sent_at       timestamptz,
  created_at    timestamptz not null default now()
);
create index on integration_outbox (status, scheduled_at);

-- 12.2 LINE WORKS 同期ログ
create table lw_sync_logs (
  id            uuid primary key default gen_random_uuid(),
  run_at        timestamptz not null default now(),
  fetched_count integer,
  diff_added    jsonb default '[]',
  diff_removed  jsonb default '[]',
  diff_changed  jsonb default '[]',
  notified      boolean not null default false,
  error         text
);

-- ============================================================
-- 13. 監査
-- ============================================================

create table audit_logs (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references members(id) on delete set null,
  table_name  text not null,
  record_id   uuid,
  action      text not null,                    -- insert / update / delete
  before      jsonb,
  after       jsonb,
  occurred_at timestamptz not null default now()
);
create index on audit_logs (table_name, record_id);
create index on audit_logs (actor_id, occurred_at desc);

-- ============================================================
-- 14. ヘルパー関数（RLS 用。JWT クレームを読む）
-- ============================================================

create or replace function auth_role()
returns app_role
language sql stable
as $$
  select coalesce(
    (current_setting('request.jwt.claims', true)::jsonb ->> 'app_role')::app_role,
    'member'::app_role
  );
$$;

create or replace function auth_member_id()
returns uuid
language sql stable
as $$
  select nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'member_id',
    ''
  )::uuid;
$$;

create or replace function auth_is_active()
returns boolean
language sql stable
as $$
  select coalesce(
    (current_setting('request.jwt.claims', true)::jsonb ->> 'member_status') = 'active',
    false
  );
$$;

create or replace function is_admin()
returns boolean
language sql stable
as $$
  select auth_role() in ('sysadmin', 'director');
$$;

-- ============================================================
-- 15. Custom Access Token Hook
--     ログインのたびに JWT へ role / member_id / status を注入
-- ============================================================

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  claims jsonb;
  m record;
begin
  select id, role, status into m
  from public.members
  where auth_user_id = (event->>'user_id')::uuid;

  claims := event->'claims';

  if m.id is not null then
    claims := jsonb_set(claims, '{app_role}',      to_jsonb(m.role::text));
    claims := jsonb_set(claims, '{member_id}',     to_jsonb(m.id::text));
    claims := jsonb_set(claims, '{member_status}', to_jsonb(m.status::text));
  else
    claims := jsonb_set(claims, '{app_role}',      '"member"');
    claims := jsonb_set(claims, '{member_status}', '"pending"');
  end if;

  return jsonb_set(event, '{claims}', claims);
end;
$$;

grant execute on function public.custom_access_token_hook to supabase_auth_admin;

-- ============================================================
-- 16. 入社時トリガー（OIDC 初回ログインで pending 作成）
-- ============================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  lw_id text;
begin
  lw_id := new.raw_user_meta_data ->> 'sub';

  -- 既に lw_user_id がある(=同期済み or 再入社)なら auth_user_id を紐付けるだけ
  update members
     set auth_user_id = new.id,
         updated_at   = now()
   where lw_user_id = lw_id
     and auth_user_id is null;

  if not found then
    insert into members (auth_user_id, lw_user_id, lw_login_id, display_name, status)
    values (
      new.id,
      lw_id,
      new.email,
      coalesce(new.raw_user_meta_data ->> 'name', new.email),
      'pending'
    );
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ============================================================
-- 17. RLS
-- ============================================================

alter table teams             enable row level security;
alter table members           enable row level security;
alter table member_private    enable row level security;
alter table rank_master       enable row level security;
alter table rank_history      enable row level security;
alter table rep_contracts     enable row level security;
alter table properties        enable row level security;
alter table areas             enable row level security;
alter table area_assignments  enable row level security;
alter table customers         enable row level security;
alter table products          enable row level security;
alter table variants          enable row level security;
alter table deals             enable row level security;
alter table deal_items        enable row level security;
alter table deal_documents    enable row level security;
alter table contractors       enable row level security;
alter table constructions     enable row level security;
alter table construction_photos enable row level security;
alter table suppliers         enable row level security;
alter table purchase_orders   enable row level security;
alter table purchase_order_items enable row level security;
alter table activity_logs     enable row level security;
alter table commissions       enable row level security;
alter table policy_docs       enable row level security;
alter table employment_docs   enable row level security;
alter table doc_access_logs   enable row level security;
alter table social_posts      enable row level security;
alter table integration_outbox enable row level security;
alter table lw_sync_logs      enable row level security;
alter table audit_logs        enable row level security;

-- 17.1 members: 全員が全員を読める（個人名入りランキング公開のため）
create policy members_select on members
  for select using (auth_is_active());

create policy members_write on members
  for all using (auth_role() in ('sysadmin','director'))
  with check (auth_role() in ('sysadmin','director'));

-- role の変更は sysadmin だけ（director が自分を昇格できないように）
create policy members_role_change on members
  for update using (auth_role() = 'sysadmin');

-- 17.2 member_private: 本人 + 管理者2ロール
create policy member_private_select on member_private
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy member_private_write on member_private
  for all using (is_admin()) with check (is_admin());

-- 17.3 報酬: 本人 + 管理者
create policy rank_history_select on rank_history
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy rank_history_write on rank_history
  for all using (is_admin()) with check (is_admin());

create policy rep_contracts_select on rep_contracts
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy rep_contracts_write on rep_contracts
  for all using (is_admin()) with check (is_admin());

create policy commissions_select on commissions
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy commissions_write on commissions
  for all using (is_admin()) with check (is_admin());

-- rank_master は全員読める（賃金規程で公開されているため）
create policy rank_master_select on rank_master
  for select using (auth_is_active());
create policy rank_master_write on rank_master
  for all using (auth_role() = 'sysadmin') with check (auth_role() = 'sysadmin');

-- 17.4 業務データ: active なメンバーは読める
create policy teams_select on teams for select using (auth_is_active());
create policy properties_select on properties for select using (auth_is_active());
create policy areas_select on areas for select using (auth_is_active());
create policy area_assignments_select on area_assignments for select using (auth_is_active());
create policy customers_select on customers for select using (auth_is_active());
create policy products_select on products for select using (auth_is_active());
create policy variants_select on variants for select using (auth_is_active());
create policy deals_select on deals for select using (auth_is_active());
create policy deal_items_select on deal_items for select using (auth_is_active());
create policy contractors_select on contractors for select using (auth_is_active());
create policy constructions_select on constructions for select using (auth_is_active());
create policy social_posts_select on social_posts for select using (auth_is_active());
create policy policy_docs_select on policy_docs for select using (auth_is_active());

-- 書き込み: 担当者本人 or 管理者
create policy properties_update on properties
  for update using (auth_is_active()) with check (auth_is_active());

create policy deals_insert on deals
  for insert with check (auth_is_active() and rep_id = auth_member_id());
create policy deals_update on deals
  for update using (
    auth_is_active() and (rep_id = auth_member_id() or is_admin())
  );

create policy activity_logs_select on activity_logs
  for select using (auth_is_active());
create policy activity_logs_insert on activity_logs
  for insert with check (auth_is_active() and member_id = auth_member_id());

-- 17.5 雇用契約書: 本人 + 管理者
create policy employment_docs_select on employment_docs
  for select using (
    auth_is_active() and (member_id = auth_member_id() or is_admin())
  );
create policy employment_docs_write on employment_docs
  for all using (is_admin()) with check (is_admin());

-- 17.6 管理者専用
create policy suppliers_admin on suppliers for all using (is_admin());
create policy purchase_orders_admin on purchase_orders for all using (is_admin());
create policy purchase_order_items_admin on purchase_order_items for all using (is_admin());
create policy outbox_admin on integration_outbox for all using (auth_role() = 'sysadmin');
create policy lw_sync_admin on lw_sync_logs for all using (auth_role() = 'sysadmin');
create policy audit_admin on audit_logs for select using (auth_role() = 'sysadmin');
create policy doc_access_admin on doc_access_logs for select using (is_admin());
create policy doc_access_insert on doc_access_logs
  for insert with check (auth_is_active() and member_id = auth_member_id());

-- ============================================================
-- 18. 業務トリガー
-- ============================================================

-- 18.1 検収完了 → 売上計上 → Outbox へ freee 仕訳を積む
create or replace function on_deal_inspected()
returns trigger
language plpgsql
as $$
begin
  if new.inspected_on is not null and old.inspected_on is null then
    new.status := 'recognized';
    new.recognized_at := now();

    insert into integration_outbox (target, event_type, payload, idempotency_key)
    values (
      'freee_accounting',
      'deal.recognized',
      jsonb_build_object(
        'deal_id', new.id,
        'deal_no', new.deal_no,
        'amount',  new.contract_amount,
        'date',    new.inspected_on
      ),
      'deal.recognized:' || new.id::text
    )
    on conflict (idempotency_key) do nothing;
  end if;
  return new;
end;
$$;

create trigger deals_inspected
  before update on deals
  for each row execute function on_deal_inspected();

-- 18.2 キャンセル → クローバック歩合を自動生成
create or replace function on_deal_cancelled()
returns trigger
language plpgsql
as $$
declare
  paid integer;
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    select coalesce(sum(amount), 0) into paid
    from commissions
    where deal_id = new.id and kind in ('appointment','contract');

    if paid > 0 then
      insert into commissions (member_id, deal_id, kind, target_month, amount, note)
      values (
        new.rep_id,
        new.id,
        'clawback',
        date_trunc('month', current_date)::date,
        -paid,
        'キャンセルによる歩合戻し: ' || coalesce(new.cancel_reason, '')
      );
    end if;
  end if;
  return new;
end;
$$;

create trigger deals_cancelled
  after update on deals
  for each row execute function on_deal_cancelled();

-- 18.3 退職 → セッション失効を Outbox へ
create or replace function on_member_left()
returns trigger
language plpgsql
as $$
begin
  if new.status in ('left','suspended') and old.status not in ('left','suspended') then
    insert into integration_outbox (target, event_type, payload, idempotency_key)
    values (
      'supabase_auth',
      'member.deactivated',
      jsonb_build_object('member_id', new.id, 'auth_user_id', new.auth_user_id),
      'member.deactivated:' || new.id::text || ':' || extract(epoch from now())::text
    );
  end if;
  return new;
end;
$$;

create trigger members_left
  after update on members
  for each row execute function on_member_left();

-- 18.4 updated_at 自動更新
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

create trigger t1 before update on members       for each row execute function touch_updated_at();
create trigger t2 before update on member_private for each row execute function touch_updated_at();
create trigger t3 before update on properties    for each row execute function touch_updated_at();
create trigger t4 before update on deals         for each row execute function touch_updated_at();
create trigger t5 before update on customers     for each row execute function touch_updated_at();
create trigger t6 before update on constructions for each row execute function touch_updated_at();
create trigger t7 before update on teams         for each row execute function touch_updated_at();

-- ============================================================
-- 19. ビュー（成績ランキング用。個人名入りで全員に公開）
-- ============================================================

create or replace view v_member_performance as
select
  m.id            as member_id,
  m.display_name,
  t.name          as team_name,
  rh.rank         as current_rank,
  date_trunc('month', d.inspected_on)::date as month,
  count(d.id) filter (where d.status = 'recognized') as recognized_count,
  coalesce(sum(d.contract_amount) filter (where d.status = 'recognized'), 0) as revenue
from members m
left join teams t on t.id = m.team_id
left join rank_history rh on rh.member_id = m.id and rh.period @> now()
left join deals d on d.rep_id = m.id
where m.status = 'active'
group by m.id, m.display_name, t.name, rh.rank, date_trunc('month', d.inspected_on);

-- 近傍検索（営業アプリのルート最適化用）
create or replace function nearby_properties(
  lat double precision,
  lng double precision,
  radius_m integer default 500
)
returns setof properties
language sql stable
as $$
  select *
  from properties
  where ST_DWithin(
    geom,
    ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography,
    radius_m
  )
  order by geom <-> ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography;
$$;
