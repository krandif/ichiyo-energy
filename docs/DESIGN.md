# 一陽株式会社 社内システム 設計書（実装前）

住宅設備 × 訪問販売の業務基盤を、README のプロトタイプ（`ichiyo-mock.html`）から
本番システムへ実装するための設計書です。技術スタック・データモデル・権限（RLS）の
骨格を扱います。バックエンド（DBスキーマ・RLS・トリガー）は `supabase/` に**実装着手済み**。

- 最終更新: 2026-07-17
- 位置づけ: 全体設計。DBの実体は [`supabase/migrations`](../supabase/migrations)、解説は [`docs/schema.md`](schema.md)・運用は [`docs/ops.md`](ops.md)
- 前提: README の業務ロジック（検収基準の売上計上、2段階販売、クーリングオフ、可変報酬）を踏襲

---

## 1. 確定した技術スタック

| 項目 | 決定 | 補足 |
|---|---|---|
| 中核基盤（BaaS） | **Supabase**（Postgres + RLS + PostGIS + Auth + Storage） | 権限要件を行レベルセキュリティに直写し |
| 認証 | **LINE WORKS（Custom OIDC Provider）→ Supabase Auth** | JWTカスタムクレームでRLS駆動。管理者2名のみ email+password のバックドア |
| クライアント（管理画面・PC） | **Next.js** | ダッシュボード・案件・マスタ管理 |
| クライアント（営業アプリ・スマホ） | **Expo（React Native）** | GPS・地図・現場記録・オフライン |
| 地図 | **MapLibre GL + PostGIS** | ピンCRUD・近傍ルート |
| SNSタブ | **埋め込み＋手動リンク**（v1） | API自動取得は将来 Edge Function で後付け |
| 会計（freee）連携 | **将来フェーズ**（Outboxパターンで基盤のみ用意） | 売上計上/歩合は自前で確定、freee は後付け |

README では Twenty（OSS CRM）をコアに据える案だったが、今回の追加要件
（独自のきめ細かい権限・実地図の営業アプリ・SNSタブ・文書ビューア）はいずれも
「自社の差別化ロジック」側に寄るため、Twenty の制約内で作るより
**Supabase を中核に自社開発**する方針に変更した。

> **スタック整合メモ（2026-07-17）**: 初期の設計チャットでは「単一 PWA（Vite）」「Supabase の
> メール/招待認証」「freee は今フェーズ対象外」としていたが、実装着手時に
> **管理=Next.js / 営業=Expo の2クライアント**、**認証=LINE WORKS OIDC**、
> **freee=Outbox で基盤先行**に更新した（README・`supabase/` スキーマと一致）。

### 1.1 フロントエンド構成

- **Next.js（管理画面・PC）** — ダッシュボード・案件/契約・マスタ・書類管理
- **Expo / React Native（営業アプリ・スマホ）** — マップ・訪問記録・見積・歩合。GPS/オフライン
- **Tailwind CSS + shadcn/ui**（管理画面） — デザインの速度と品質を両立
- **TanStack Query + Supabase Realtime** — キャッシュ＋楽観的更新で「1操作→全画面同期」を再現
- **MapLibre GL** — 高速ベクタ地図。ピンCRUD（地理院タイル / MapTiler）
- **React Hook Form + Zod** — フォームと検証

### 1.2 バックエンド構成（Supabase）

- Postgres + RLS + **PostGIS**（顧客宅の緯度経度・近傍ルート）
- **Auth = LINE WORKS Custom OIDC**。Custom Access Token Hook で `app_role` / `member_id` / `member_status` を JWT に注入し RLS を駆動
- Storage（就業規則・賃金規定・雇用契約書・現場写真）
- Realtime（案件更新→全画面同期）
- 集計は **SQLビュー / RPC関数 / マテリアライズドビュー**
- pg_cron（月次歩合の締め処理・LINE WORKS 日次同期）
- Edge Functions（Outbox worker: freee 会計/人事労務・LINE WORKS Webhook・SNS API取得）

---

## 2. スケール・パフォーマンス方針（50〜100名規模）

データ量・同時接続とも Postgres には余裕の規模。効いてくるのは組織階層と運用プラン。

- ダッシュボードKPI・ランキング・パイプラインは **マテリアライズドビューで事前計算**
  （トリガ or pg_cron で更新）→ クライアントは読むだけで一覧が即表示
- RLS は **security definer のヘルパ関数**でユーザー属性を1回引き、ポリシーを単純比較に固定
- 索引: `(team_id, rep_id, status, geom)` ほか
- クライアントは **TanStack Query キャッシュ ＋ 楽観的更新 ＋ Realtime**
- **Supabase Pro プラン想定**（自動バックアップ・専用リソース・Supavisor 接続プーラー）

---

## 3. 役割モデル（4階層）

| 役割 | 人数 | 権限の要旨 |
|---|---|---|
| `system_admin`（ランディフ） | 1 | 全権。ユーザー管理・システム設定・文書管理・全データCRUD |
| `business_director`（事業ディレクター） | 1 | 全データ閲覧（**全員の契約書・歩合明細も可**）＋運用データの編集 |
| `team_leader`（チームリーダー） | 複数 | **自チームの**メンバー・案件・訪問・見積を管理・編集 |
| `member`（一般営業） | 〜100 | **自分の**案件・訪問・見積を書込。自チームは閲覧。他チームは**成績集計のみ**閲覧 |

### 機微情報のプライバシー既定

- **歩合明細・雇用契約書**は「本人＋システム管理者＋事業ディレクター」のみ閲覧可
- チームリーダーは運用データ（案件・訪問・成績）は自チーム分を閲覧・編集できるが、
  **部下の給与・契約書は閲覧できない**（後で変更可能）

---

## 4. データモデル（ERD 概要）

Twenty のカスタムオブジェクト構想を Postgres テーブルに写す。

```
── 認証・組織 ──────────────────────────
profiles(id=auth.uid, name, role, team_id, region_id, rank, status, hired_at)
                                    ↑ team_id/region_id は「現在の所属」の高速参照キャッシュ
regions(id, name)                             -- 拠点/地域: 愛媛, 千葉 …（多拠点の集計軸）
teams(id, name, region_id, area(geom), leader_id, color)
team_memberships(id, rep_id, team_id, region_id,
                 start_date, end_date, reason)   ← イミュータブル所属ログ（正）

── 営業ドメイン ────────────────────────
customers(id, name, type, address, lat, lng, geom(PostGIS),
          area, status, assigned_rep_id, team_id)
  └ buildings ─ units          ※マンションは後続で拡張可
deals(id, customer_id, rep_id, team_id, region_id, stage[S1/S2], status,
      amount, contract_date, cooling_off_end, accrual_date, freee_txn_id?)
                          ↑ team_id/region_id は成約/計上“時点”のスナップショット（固定）
visit_logs(id, customer_id, rep_id, team_id, visited_at, note, photos)
estimates(id, customer_id, rep_id, items(jsonb), total, created_at)
work_orders(id, deal_id, contractor_id?, type[internal/external], scheduled_at, status)
installations(id, deal_id, inspection_status, inspected_at)   ← 検収=売上計上トリガ
activity_logs(id, rep_id, team_id, type[apo/visit/contract/clawback], deal_id?, occurred_at)

── 商品・仕入 ──────────────────────────
suppliers / products ─ product_variants / purchase_orders / contractors

── 報酬（過去時点を再現可能に）──────────
rank_master(rank, fix_salary, apo_unit, contract_unit, valid_from)
rank_history(id, rep_id, rank, start_date, end_date)          ← イミュータブル
rep_contracts(id, rep_id, fix_salary_override, period_start, period_end)
commissions(id, rep_id, year_month, fix, apo_amount, contract_amount,
            clawback, total, status)

── 文書・SNS ───────────────────────────
documents(id, type[work_rules/wage_rules/employment_contract/other],
          title, visibility[company_wide/team/private],
          owner_id?, team_id?, storage_path, version, effective_date)
sns_accounts(id, platform, handle, url, embed_type, display_order, active)

── 成績（事前計算・体感速度用）──────────
mv_rep_performance(rep_id, team_id, region_id, year_month, deals, revenue, apo)  [MV]
mv_team_performance(team_id, region_id, year_month, deals, revenue, members)     [MV]
mv_region_performance(region_id, year_month, deals, revenue, teams)              [MV] 拠点別
```

### 業務ロジックの要点（README 踏襲）

- **売上計上は「検収完了」がトリガー** — `installations.inspection_status = 合格` で計上
- **2段階販売（Stage1 → Stage2）** — Stage1設置後のデータ蓄積顧客を Stage2 見込みに自動リスト化
- **クーリングオフ** — `deals.cooling_off_end` までは工事手配をロック
- **可変報酬** — `rank_master` ＋ `rank_history`（イミュータブル履歴）で過去時点を正確に再現。
  歩合はいきなり自動化せず、まず Excel で検証してから関数化する

### 時間軸の所属・成績の履歴方針

メンバーがチーム/拠点を移る（例: 2026H2 愛媛 → 2027H1 千葉）ケースを、過去成績を
壊さずに残すための方針。`rank_history` と同じ「イミュータブル履歴」を所属にも適用する。

- **所属は履歴で持つ**: `team_memberships`（期間つき・上書きしない）が「いつどのチーム/拠点だったか」の正。
  `profiles.team_id/region_id` は「今どこか」の高速参照キャッシュ。任意時点の解決は関数 `team_at(rep_id, date)`
- **成績は発生時点をスナップショット**: 案件・訪問・活動・歩合に、その時点の `team_id/region_id` を保存。
  現在の所属から都度導出しない（＝異動しても過去成績が付け替わらない）

これで次が正しく取れる:

| 問い | 取り方 |
|---|---|
| 愛媛チームの2026年下期成績 | `deals.team_id=愛媛 AND 期間` で集計（本人が後で千葉へ移っても不変） |
| ある営業マンの通算成績 | `deals.rep_id` で全期間横断（愛媛時代＋千葉時代を合算） |
| 2027上期の千葉拠点 | 異動後の分だけ千葉に計上 |
| 異動月をまたぐ歩合 | 月ごとに `team_at()` × `rank_history` を突き合わせて正しいチーム・ランクで計算 |

- **RLSの含意**: 「自チーム閲覧」は現在の所属で判定。異動すると旧チームの“他人の”案件は見えなくなるが、
  自分が作った過去案件（`rep_id=自分`）は引き続き閲覧可（自然な挙動）

---

## 5. RLS ポリシー設計

ポリシーを速く・単純に保つため、security definer のヘルパ関数でログインユーザーの属性を引く。

```sql
auth_role()        -- 'system_admin' | 'business_director' | 'team_leader' | 'member'
auth_team()        -- 自分の team_id
is_admin_or_dir()  -- 管理者 or ディレクター
```

主要テーブルの権限マトリクス:

| テーブル | SELECT（閲覧） | INSERT / UPDATE（書込） |
|---|---|---|
| `customers` / `deals` | 管理者・ディレクター=全件／リーダー・メンバー=**自チームのみ** | 管理者・ディレクター=全件／リーダー=自チーム／メンバー=**自分の担当のみ** |
| `visit_logs` / `estimates` | 自チームのみ | メンバー=`rep_id = 自分`／リーダー=自チーム |
| `commissions`（歩合明細） | 管理者・ディレクター=全件／**本人=自分のみ** | 管理者のみ（月次確定） |
| `documents`（契約書=private） | `owner_id = 自分` **OR** 管理者・ディレクター | 管理者のみ |
| `documents`（就業規則・賃金規定=company_wide） | **全員**（認証済み） | 管理者のみ |
| `mv_*_performance`（成績集計） | **全員**（＝他チーム成績はここで閲覧） | 更新はジョブのみ |
| `sns_accounts` | 全員 | 管理者のみ |
| `profiles` / `teams` | 全員（氏名・チーム・ランク等の基本情報） | 管理者（本人は自分の一部項目のみ） |

**設計のキモ**: メンバーが raw の `deals` で見られるのは**自チームまで**。
他チームは個票を出さず `mv_team_performance` の集計だけを見せる。
これで「他チーム成績は閲覧できるが、他チームの顧客個票は見えない」を両立し、
かつ集計は事前計算なので 50〜100名でも一覧が即表示される。

---

## 6. 画面と権限の出し分け

単一PWAで、ログイン役割に応じてナビゲーションを自動生成する。
凡例 — **● 全件 ／ ◐ 自チーム ／ ○ 自分のみ ／ – 非表示**

### A. 経営・バックオフィス（管理コンソール）

| 画面 | admin | director | leader | member |
|---|:--:|:--:|:--:|:--:|
| ダッシュボード（KPI・パイプライン） | ● | ● | ◐＋他チームは集計のみ | ◐＋他チームは集計のみ |
| 案件・契約 | ● | ● | ◐（自チーム編集） | ◐閲覧／書込は○自分の担当 |
| Stage2 見込み | ● | ● | ◐ | ◐ |
| 顧客宅 | ● | ● | ◐（自チーム編集） | ◐閲覧／書込は○ |
| エリア割当 | ●（編集） | ● | ◐（自チーム調整） | ○（自分の担当エリア閲覧） |
| 工事・検収 | ●（編集・計上） | ● | ◐（自チーム案件） | ○（自分の案件・閲覧中心） |
| 商品・型番 | ●（編集） | ●閲覧 | 閲覧（見積用） | 閲覧（見積用） |
| 仕入・発注 | ●（編集） | ●閲覧 | – | – |
| メンバー・チーム | ●（編集） | ●閲覧 | ◐（自チーム名簿） | ◐（自チーム名簿） |
| ランク定義 | ●（編集） | ●閲覧 | – | – |
| ユーザー管理・システム設定 | ● | – | – | – |

### B. 現場アプリ（営業アプリ・スマホUI）

| タブ | admin | director | leader | member |
|---|:--:|:--:|:--:|:--:|
| マップ（ピン留め） | ●全ピン | ●全ピン | ◐自チーム編集 | ○自分の担当を編集・自チーム閲覧 |
| ルート（近傍順） | ● | ● | ◐ | ○（自分の訪問先） |
| 見積 | ● | ● | ◐ | ○（自分で作成） |
| 活動ログ | ● | ● | ◐（自チーム） | ○（自分の活動） |
| 歩合 | ●全員分 | ●全員分 | **○自分のみ** | **○自分のみ** |

> 歩合はリーダーも自分の分だけ。部下の給与はプライバシー既定により非表示（§3の方針どおり）。

### C. 共通タブ（全役割に表示）

| 画面 | admin | director | leader | member |
|---|:--:|:--:|:--:|:--:|
| SNS（自社アカウント） | ●閲覧＋登録/並替 | 閲覧 | 閲覧 | 閲覧 |
| 就業規則・賃金規定 | ●閲覧＋管理 | 閲覧 | 閲覧 | 閲覧 |
| 自分の雇用契約書 | ●全員分 | ●全員分 | ○自分のみ | ○自分のみ |

### 出し分けの実装方針

- ナビゲーション自体を役割で生成（member/leader には「仕入・発注」「ランク定義」「ユーザー管理」を出さない）
- ただし **UIの非表示は防御にしない** — 実アクセス制御は §5 の RLS がDB側で担保（URL直打ち・API直叩きでも漏れない）
- 「他チーム成績」は個票を出さず `mv_team_performance` の集計カードだけをダッシュボードに表示
- 「自分の歩合」「自分の契約書」は本人トークンで `owner_id = auth.uid()` に解決

---

## 7. 追加機能の実装方針

### マップ ピン留め（詳細）

#### 地図プロバイダ／タイル

| 用途 | 採用 | 理由 |
|---|---|---|
| 地図エンジン | **MapLibre GL JS** | OSS・無料・ベクタで高速。ピン/ポリゴン/クラスタを自前制御 |
| ベースタイル（v1） | **地理院タイル（GSI）** | 日本政府提供・APIキー不要・無料・日本の住宅地の精度が高い |
| 見た目を上げる場合 | MapTiler（ベクタ） | 要APIキー。将来のアップグレード候補 |
| 住所⇔座標 | GSI ジオコーディング / Google Geocoding | 住所入力からピン生成。タップ設置なら座標は直接取得 |

まずコスト0の GSI で始め、タイル定義を1箇所に集約して差し替え可能にする。

#### ピンの状態（モック `STCOLOR` 踏襲）

```
new 未訪問(灰) → visited 訪問済(緑) → contract 契約済(青)
   →[CO満了]→ work 工事(橙) → done 計上済(橙)   ／ cancel 取消(赤)
```

#### CRUD と役割別の可否

| 操作 | admin / director | leader | member |
|---|:--:|:--:|:--:|
| ピン追加（地図タップ or 住所） | ●任意に割当 | ◐自チームへ割当 | ○自分に自動割当（自チームエリア） |
| ピン移動（ドラッグ）／削除 | ● | ◐自チーム | ○自分の担当のみ |
| 状態遷移（訪問記録・成約・検収） | ● | ◐自チーム | ○自分の担当のみ |
| 閲覧 | ●全ピン | ◐自チーム | ◐自チーム（他チームは非表示） |

- 追加フロー: 地図長押し/タップ → 仮ピン → シートで「表札・種別・住所」入力 → 保存。
  メンバーは `rep_id=自分・team_id=自チーム` を自動セット（RLSと一致）
- 状態遷移: ピンをタップ → ボトムシート（モックの `openSheet` 相当）で
  「訪問を記録／成約を登録／工事完了・検収」。1操作で色・KPI・一覧が Realtime 同期
- UIの出し分けに関わらず、書込可否は §5 の RLS が最終防衛

#### 表示・パフォーマンス（100件超対策）

- 状態で色分け（`STCOLOR`）＋自分のピンは強調リング
- クラスタリング（MapLibre 標準 or Supercluster）で数百ピンでも軽快
- フィルタ: 状態別・「自分の担当のみ」・エリア別・未訪問のみ
- 担当エリアのポリゴン破線表示（モックの `myAreaPoly`）。`teams.area` を共有し被り・空白地帯を検知

#### 現在地・ルート最適化

- `navigator.geolocation.watchPosition` で現在地の青ドット表示（モックの `ME`）
- ルート＝現在地からの近傍順: PostGIS の `geom <-> ST_Point(現在地)` で並べ替え（`buildRoute` をDB側へ）
- v1は直線近傍順。道路沿いの実ルート（所要時間）は外部ルーティングAPIが要るため将来拡張

#### オフライン挙動（PWA）

- タイル: Service Worker で直近閲覧範囲をキャッシュ
- ピンデータ: IndexedDB にキャッシュし、オフラインでも一覧・地図を表示
- 書込（訪問記録・写真）: オフライン中は送信キュー（outbox）にため、復帰時に自動同期。UIは楽観的更新
- 競合: `updated_at` で検出。基本 last-write-wins ＋ 衝突時は通知して手動解決の余地を残す
- 写真: ローカル保持 → 復帰時に Storage へアップロード

### SNSタブ（v1）
- `sns_accounts` に各アカウント（Instagram / X / TikTok 等）を登録
- 公式埋め込み＋リンク集で表示。管理者が登録・並び替え
- API 自動取得（投稿・フォロワー数集計）は将来 Edge Function で追加

### 文書ビューア
- `documents` を Storage の署名URLで配信
- `company_wide`（就業規則・賃金規定）＝全員閲覧
- `private`（雇用契約書）＝本人＋管理者＋ディレクターのみ
- バージョン・施行日を保持

---

## 8. 今フェーズ対象外（将来）

- freee 会計（検収→売上仕訳）／freee 人事労務（月次歩合→変動手当）連携
- SNS の API 自動取得・エンゲージメント集計
- マンションの棟・部屋単位（buildings / units）の詳細管理
- オフライン同期の高度化（PWA の下地は最初から入れる）

---

## 9. 未確定・要確認（実装前に握る）

- 売上計上の会計基準（検収基準／引渡基準）、前受金・消費税タイミング → 税理士確認
- 歩合の締めと基準日（成約日基準／検収完了日基準）→ 営業契約条件
- クローバックの運用（当月調整／翌月調整）
- ~~将来のFC・多拠点展開の有無（マルチテナント設計の要否）~~
  → **確定: マルチテナントは不要**。FCはやらない。多拠点は同一法人内の
  チーム/拠点（`region`）追加として扱い、`team_id` ベースの RLS でカバーする
- チームリーダーが自チームの給与・契約書を見る必要が出た場合のポリシー変更
- ~~設計 ↔ 実装スキーマの乖離（4階層/regions/team_memberships）~~
  → **確定: A（スキーマに追加）で決着**。`20260719000000_add_team_leader_role.sql` で `team_leader` を追加、
  `20260719000100_regions_membership_snapshots.sql` で `regions` / `team_memberships` / 発生時点スナップショット
  （`deals`・`activity_logs`・`commissions` の `team_id`/`region_id`）と `team_at()`/`auth_team()`、
  team_leader スコープの案件RLSを追加済み。
- **team_leader スコープRLSの網羅**: 現状 `deals` の書込のみ team_leader スコープを実装。
  `customers`/`constructions` 等の team_leader 書込は、下記「書き込みRLSの抜け」と併せて次フェーズで整備
  （`customers` に team_id 列が無い等、構造追加も要る）。
