-- ============================================================
-- app_role に team_leader を追加
-- （enum の ADD VALUE は、その値を使う DDL とは別トランザクションで
--   実行する必要があるため、後続マイグレーションと分離している）
-- ============================================================
alter type app_role add value if not exists 'team_leader' after 'director';
