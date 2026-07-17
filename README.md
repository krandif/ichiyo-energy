# 一陽株式会社 社内システム（プロトタイプ）

住宅設備 × 訪問販売の業務基盤。太陽光・蓄電池・エコキュートの訪問販売から、施工・検収・売上計上・営業歩合までを一気通貫で扱う社内システムの設計プロトタイプです。

このリポジトリの `ichiyo-mock.html` は、画面イメージと業務フローの合意形成を目的とした**動作するモック**です。単一のHTMLファイルで、依存パッケージもビルドも不要です。

- タグライン: つくる・ためる・そなえる（西の光を、夜の安心へ）
- 対象エリア: 愛媛（西条・新居浜を起点に西日本へ）
- 位置づけ: 実装前の仕様確認用プロトタイプ。データはブラウザ内のJavaScript変数で保持（保存はされません）

> **本番システムの設計は [`docs/DESIGN.md`](docs/DESIGN.md) に集約しています。**
> 技術スタック・役割モデル（4階層）・データモデル・RLS 権限・画面の出し分け・
> マップUX・多拠点/期間所属の履歴方針までを確定済み。このモックはその画面イメージです。

---

## クイックスタート

`ichiyo-mock.html` をブラウザで開くだけです。サーバーもインストールも要りません。

```
# ローカルで開く
open ichiyo-mock.html          # macOS
start ichiyo-mock.html         # Windows
```

画面右上のトグルで **管理画面** と **営業アプリ**（スマホUI）を切り替えられます。

---

## このモックで触れること

### 縦串（1案件を最後まで通す）

営業アプリのマップから、1件の案件を訪問から売上計上まで流せます。操作するとヘッダーの数字・管理ダッシュボード・案件テーブル・マップのピン色が**同時に**更新されます。

1. 未訪問ピン（灰）をタップ →「訪問を記録」→ 訪問済（緑）
2. 訪問済ピンをタップ →「成約を登録」→ 契約済（青）＋クーリングオフ期間が発生
3. 契約済ピンをタップ →「工事完了・検収」→ 計上済（オレンジ）＋売上計上

「現場で1件動かすと、経営が見る数字まで自動でつながる」を体感するのが狙いです。

### 主な画面

**管理画面**

| 画面 | 内容 |
|---|---|
| ダッシュボード | KPI（成約・売上・工事待ち）、パイプライン、営業マン別成績。今月/先月/四半期の期間トグル |
| 案件・契約 | 契約〜検収〜計上の一元管理。検索・ステータス絞り込み。検収→計上タイムライン |
| Stage2見込み | Stage1成約者を自動リスト化した蓄電池の提案パイプライン |
| 顧客宅 | 戸建て・マンションを緯度経度つきで管理（営業アプリのマップと同一データ） |
| エリア割当 | 営業マンごとの担当エリアをポリゴンで可視化。被り・空白地帯を検知 |
| 工事・検収 | 社内施工／外部委託の割当。検収合格が売上計上のトリガー |
| 商品・型番 | 製品ライン(Product)と型番(Variant)の2階層。スペック・価格改定を保持 |
| 仕入・発注 | メーカー・商社への発注 |
| メンバー・チーム | チーム編成・歩合ランキング・チーム間集計 |
| ランク定義 | ランク×契約期間で変わる固定給・歩合。昇降格履歴 |
| 売上計上・freee | 検収→freee会計、月次歩合→freee人事労務の連携 |

**営業アプリ（スマホUI）**

| タブ | 内容 |
|---|---|
| マップ | 顧客宅ピン（状態で色分け）、自分の担当エリアを破線表示 |
| ルート | 現在地から近い順に訪問先を自動並べ替え |
| 見積 | その場で概算見積。500万を超えるとリフォームローン枠の警告 |
| 活動 | 訪問・アポ・成約・クローバックのログ |
| 歩合 | 今月の見込支給を固定給・アポ歩合・成約歩合に分解表示 |

---

## 設計の考え方

### 技術選定：Supabase を中核に自社開発

本番は **Supabase（Postgres + Row Level Security + PostGIS + Auth + Storage）を中核 BaaS** に据え、
**管理画面は Next.js（PC）／営業アプリは Expo（スマホ）** の2クライアント、認証は **LINE WORKS の
Custom OIDC** で構築します。独自のきめ細かい権限・実地図の営業アプリ・SNSタブ・文書ビューアなど
「自社の差別化ロジック」が中心になるため、既製CRMの制約内で作るより、権限要件を RLS に直写できる
Supabase 上での自社開発が適すると判断しました。

具体的な技術スタック・ディレクトリ・セットアップは後述の「社内システム（Supabase バックエンド）」節に。
金額計算は Supabase 側で決定論的に確定し、記帳・支払（freee）は将来フェーズで Outbox 経由で連携します。

> 当初は OSS CRM の [Twenty](https://twenty.com/) をコアに据える案でしたが、
> 追加要件（4階層の権限・SNS・文書・多拠点/期間所属の履歴）を踏まえ Supabase 中心へ変更しました。
> 詳細な比較と決定理由は [`docs/DESIGN.md`](docs/DESIGN.md) を参照。

### 権限モデル（4階層）

| 役割 | 人数 | 権限の要旨 |
|---|---|---|
| `sysadmin`（ランディフ） | 1 | 全権。ユーザー管理・システム設定・全データCRUD |
| `director`（事業ディレクター） | 1 | 全データ閲覧（契約書・歩合明細も）＋運用データ編集 |
| `team_leader`（チームリーダー） | 複数 | 自チームの案件・訪問・見積を管理・編集 |
| `member`（一般営業） | 〜100 | 自分の案件・訪問・見積を書込。自チーム閲覧、他チームは成績集計のみ |

役割は JWT のカスタムクレーム（`app_role` / `member_id` / `member_status` / `team_id`）で持ち、
RLS が DB 側で強制します（UIの出し分けは防御にしない）。歩合明細・雇用契約書は本人＋管理者2名のみ。

### 業務ロジックの要点

**売上計上は「検収完了」がトリガー**
契約締結ではなく、工事設置の検収合格の時点で売上を認識します。住宅設備の据付完了＝検収基準での収益認識が実態に合います。前受金がある場合は契約時に前受金として計上し、検収時に売上へ振替。二重計上を防ぐため、freeeの取引IDを Supabase 側（`deals.freee_txn_id`）に保存します。

**2段階販売（Stage1 → Stage2）**
リフォームローンの枠（500万円）に収めるため、太陽光＋エコキュート（Stage1）と蓄電池（Stage2）を分けて販売します。Stage1設置後に発電・使用データが溜まった顧客を、システムが自動でStage2の見込みリストに載せます。Stage2は銀行借換で資金手当てするため、信販ローンに依存しません。これが2回目の売上機会になります。

**クーリングオフの管理（特定商取引法）**
訪問販売のため、契約日から起算した期間中は工事手配をロックします。営業アプリ・案件画面でカウントダウンを表示し、期間満了後に工事→検収→計上へ進みます。

**営業マンの可変報酬**
契約社員。ランク（A〜E）×職種（sales/office）ごとに固定給・アポ単価・成約単価が変わり、契約期間ごとにも変動、昇降格もあります。過去の任意時点の給与・所属を正確に再現できるよう、履歴を持ちます。

- `rank_master`: ランク×職種ごとの単価定義（有効期間つき）
- `rank_history`: 「いつからいつまで、どのランクだったか」の履歴（イミュータブル・期間重複禁止）
- `rep_contracts`: 契約期間ごとの固定給（個人交渉での上書き）
- `team_memberships`: 「いつどのチーム／拠点にいたか」の期間所属履歴（愛媛→千葉のような異動も追跡）

成績（`deals`/`activity_logs`/`commissions`）は**発生時点の `team_id`/`region_id` を刻む**ため、異動しても過去成績は付け替わりません。キャンセル・クーリングオフが出た場合は、支払済み歩合をマイナス調整（クローバック）できます。

---

## データモデル（Postgres テーブル）

30+テーブルの俯瞰です。全定義・関係・権限（RLS）は
[`docs/schema.md`](docs/schema.md)、多拠点/期間所属の履歴方針は [`docs/DESIGN.md`](docs/DESIGN.md) §4 を参照。

```
── 組織・人 ──────────────
regions（拠点: 愛媛/千葉…）── teams（チーム）
members（公開情報）── member_private（個人情報: 本人+管理者のみ）
team_memberships（期間所属の履歴・重複禁止）

── 報酬 ──────────────────
rank_master（ランク×職種の単価）／ rank_history（昇降格履歴・不変）／ rep_contracts（契約・給与上書き）
commissions（歩合。クローバックは負値）

── 顧客・物件 ────────────
properties（顧客宅: 緯度経度・訪問状態）／ areas（エリアポリゴン）／ area_assignments（担当・期間）
customers（世帯）

── 商品・仕入 ────────────
products ── variants（型番・スペック・価格）／ suppliers ／ purchase_orders ── purchase_order_items

── 案件・工事 ────────────
deals（案件・契約: 金額/ステージ/発生時点の team_id・region_id）
  ├ deal_items（明細）／ deal_documents（書面交付: 特商法）
  ├ constructions（工事・検収 → 売上計上トリガー）── construction_photos
  └ contractors（施工業者）
activity_logs（訪問・アポ・成約ログ）

── 書類・SNS ─────────────
policy_docs（就業規則・賃金規程: 全員）／ employment_docs（雇用契約書: 本人+管理者）
doc_access_logs（閲覧証跡）／ social_posts（自社SNS）

── 連携・監査 ────────────
integration_outbox（freee/Auth 連携キュー）／ lw_sync_logs（LINE WORKS 同期）／ audit_logs
v_member_performance（成績ランキング・ビュー）
```

実体は [`supabase/migrations/`](supabase/migrations)、解説は [`docs/schema.md`](docs/schema.md)、
運用フローは [`docs/ops.md`](docs/ops.md) を参照。

---

## 社内システム（Supabase バックエンド）

画面モックとは別に、本番社内システムの DB スキーマ・RLS・連携基盤を `supabase/` に置いています。

### 技術スタック

| 領域 | 採用 |
|---|---|
| BaaS / DB | Supabase（PostgreSQL + Auth + RLS + PostGIS + Storage） |
| 管理画面（PC） | Next.js |
| 営業アプリ（スマホ） | Expo（React Native） |
| 地図・近傍検索 | MapLibre GL + PostGIS |
| 認証 | LINE WORKS（Custom OIDC Provider） |
| 会計・給与 | freee会計 / freee人事労務 連携（将来フェーズ・Outbox 経由） |

### ディレクトリ構成

```
.
├── ichiyo-mock.html   # 画面モック（プロトタイプ。フロントの叩き台）
├── docs/              # 設計ドキュメント
│   ├── DESIGN.md      #   全体設計（基盤・権限・画面）
│   ├── schema.md      #   DBスキーマ解説
│   └── ops.md         #   入社〜退職の運用フロー
└── supabase/          # 社内システムのバックエンド
    ├── migrations/    #   スキーマ（実行順は YYYYMMDDHHMMSS で決まる）
    │   ├── 20260718000000_init.sql                        # 30テーブル・RLS・トリガー
    │   ├── 20260719000000_add_team_leader_role.sql        # app_role に team_leader 追加
    │   └── 20260719000100_regions_membership_snapshots.sql # 拠点・期間所属・発生時点スナップショット
    └── seed.sql       #   初期データ（ランク・チーム・商品）
```

- **フロント側**（`ichiyo-mock.html`、将来の `site/` や `web/` / Next.js・Expo アプリ）＝ 画面と操作
- **`supabase/` 側** ＝ データモデル・権限・業務ルール・外部連携の土台

### セットアップ手順

```bash
npx supabase init
npx supabase link --project-ref <PROJECT_REF>
npx supabase db push
npx supabase db reset   # ローカル検証時。seed.sql も流れる
```

### Custom Access Token Hook の有効化

ログインのたびに JWT へ `app_role` / `member_id` / `member_status` / `team_id` を注入するフックを有効化する。

- Dashboard → **Authentication → Hooks → Customize Access Token (JWT) Claims**
- `public.custom_access_token_hook` を選択

### Custom OIDC Provider（LINE WORKS）の登録

> **Custom OIDC Provider は Supabase Pro plan（$25/月〜）が必要**です。

- Dashboard → **Authentication → Providers → Add provider → OIDC**
- Issuer: `https://auth.worksmobile.com/oauth2/v2.0`
- Client ID / Secret: LINE WORKS Developer Console で取得
- Redirect URI: `https://<project>.supabase.co/auth/v1/callback`

### Secret の取り扱い（重要）

- **Secret は絶対にコミットしない。** Client Secret / `service_role` key / freee トークンは
  **GitHub Secrets** か **Supabase の環境変数**（Edge Function の secrets）に置く
- `.env` / `.env.local` / `*.key` は `.gitignore` 済み

---

## 連携フロー（freee は将来フェーズ）

> freee 連携は**今フェーズ対象外**です。以下は後続フェーズで Supabase Edge Function として
> 実装する想定の設計です。当面、売上計上・歩合は Supabase 側で決定論的に確定させます。

### 売上計上（検収 → freee会計）

```
Supabase: Installation.検収 = 合格  でトリガ/Edge Function 発火
   ↓
freee会計: POST /api/1/deals  type=income（売上高／顧客／契約額）
   ↓
前受金があれば消込仕訳を同時起票
   ↓
Supabase: Deal.売上計上日 と freee取引ID を保存（二重計上防止）
```

### 月次歩合（Commission → freee人事労務）

対象月・対象repのランク履歴から適用ランクを確定し、`固定給 + アポ数×アポ単価 + 成約数×成約単価 −クローバック` を算出。freee人事労務へ当月の変動手当として連携します。

基幹の売上・給与はAPI直叩きで決定論的に処理し、月次チェックや例外処理は freee公式MCP（freee-mcp）経由でも運用できます。

---

## 実装ロードマップ（想定）

| フェーズ | 内容 | 状況 |
|---|---|---|
| Phase 0 | Supabase プロジェクト作成、Auth・Storage・バックアップ運用確立 | 未 |
| Phase 1 | コアスキーマ（顧客・商品・案件・営業マン・チーム/拠点）定義、RLS・既存データ移行 | **スキーマ・RLS・seed 実装済**／データ移行は未 |
| Phase 2 | 仕入・工事手配・設置、売上計上トリガ（検収→計上）を Supabase 内で完結 | **トリガ実装済**（`on_deal_inspected` 等） |
| Phase 2.5 | 報酬・所属履歴（`rank_history` / `team_memberships`）を定義。まずExcelで正しさを検証してから関数化 | **スキーマ実装済**／歩合の関数化は検証後 |
| Phase 3 | 管理画面(Next.js)・営業アプリ(Expo)・SNS・文書ビューア 開発・配布 | 未 |
| Phase 4 | 営業アプリのマップ（地図ピン・訪問記録・見積・オフライン同期）を作り込み | 未 |
| Phase 5 | 運用データを見て権限・レポート・オフライン同期を調整。freee 連携を後付け | 未 |

> 現状の要対応: RLS の書き込みポリシー整備（`customers`/`constructions` 等）、role昇格ガード、
> `properties` 更新スコープ、状態遷移ガード。詳細は [`docs/schema.md`](docs/schema.md) の残論点と
> [`docs/DESIGN.md`](docs/DESIGN.md) §9 を参照。

歩合計算は、数ヶ月分をExcelで手計算して実態と合うか確認してからコード化します。報酬は間違えるとトラブルに直結するため、いきなり自動化しません。

---

## 確定前に握るべき論点

- **売上計上の会計基準**（検収基準／引渡基準）、前受金の扱い、消費税の課税タイミング → 顧問税理士に要確認
- **歩合の締めと基準日**（成約日基準／検収完了日基準）→ 営業マンとの契約条件そのもの
- **クローバックの運用**（当月調整／翌月調整）
- ~~将来のFC・多拠点展開の有無~~ → **確定・実装済み**。FC はやらないため**マルチテナント不要**。
  多拠点は `regions`／`teams`、期間所属は `team_memberships`、成績は発生時点スナップショットで**実装済み**
  （愛媛→千葉のような異動も追跡可。[`docs/DESIGN.md`](docs/DESIGN.md) §4）
- **運用体制**（Supabase の自動バックアップ確認、プラン／接続数、アップグレード手順）

---

## モックの技術メモ

- 単一HTMLファイル。外部依存はGoogle Fontsのみ（Noto Sans JP / Shippori Mincho / JetBrains Mono）
- データは `ichiyo-mock.html` 内の `DEALS` / `REPS` / `TEAMS` などのJavaScript変数。リロードで初期状態に戻ります（永続化なし）
- マップは実地図ではなくSVGで描いた模式図です
- レスポンシブ対応済み（デスクトップ・タブレット・スマホ幅）
- 登場する人名・顧客名・数値はすべてダミーです

### 注意

このモックは画面と業務フローの確認用です。以下は実装フェーズで対応します。

- データの永続化（ブラウザを閉じると消えます）
- 認証・権限（本番は LINE WORKS OIDC ＋ RLS。`supabase/` を参照）
- 実際の freee API との接続（将来フェーズ）
- 地図の実データ（MapLibre + 地理院タイル / Google Maps 等）

---

## 補足

法令・会計に関わる記述（クーリングオフ、収益認識、消費税）は要件に沿った一例です。実運用の基準は、社会保険労務士・税理士・弁護士の確認を前提とします。
