# thelook-analytics-dbt

BigQuery の公開データ `thelook_ecommerce`（架空の衣料品 EC サイト）を題材に、**元データの取り込みから、変換、テスト、分析用のテーブルまで**を、dbt Cloud と BigQuery で通したプロジェクトです。

アナリティクスエンジニアに必要な次の4つを、1つのプロジェクトで示すことを目的にしています。

| 要素 | このプロジェクトでやったこと |
|---|---|
| BigQuery の SQL（性能設計） | `fct_order_items` を、月単位のパーティションとクラスタリング付きのテーブルにし、処理されるバイト数で効果を確認 |
| dbt でのデータ変換 | staging と marts の2層、`ref()` / `source()`、テスト13件、モデルと列の説明文 |
| データモデリング | 粒度を「明細1つ」に決めたファクトテーブルの設計と、判断の理由の記録 |
| パイプライン（自動化） | 取り込み（BigQuery）→ 変換（dbt）を、時刻をずらして毎日自動実行 |

## 使っているもの

- データ：BigQuery の公開データ `bigquery-public-data.thelook_ecommerce`（プログラムで生成された、架空のデータ）。`orders`、`order_items`、`products`、`users` の4テーブルを使用
- 変換：dbt Cloud（Developer プラン）、dbt は `v1 Latest`
- データウェアハウス：BigQuery（US ロケーション）
- コード管理：GitHub

## 構成

```
bigquery-public-data.thelook_ecommerce        （公開データ）
        │  BigQuery のスケジュールされたクエリ（Daily_thelook）
        │  毎日 10:30 JST ／ 4テーブルを全件入れ替え
        ▼
raw_thelook                                    （自分の BigQuery に置いた元データ。dbt では source）
  orders / order_items / products / users
        │  dbt のジョブ（Daily build、dbt build）
        │  毎日 15:30 JST
        ▼
dbt_analytics                                  （本番用のデータセット）
  stg_thelook__orders        ┐
  stg_thelook__order_items   │ view。元データを1テーブルずつ整える
  stg_thelook__products      │
  stg_thelook__users         ┘
        │  ref()
        ▼
  fct_order_items                              （table。分析用の完成形）
```

開発用（dbt Cloud の Studio で試す場所）は `dbt_saeh`、本番用は `dbt_analytics` で、同じ元データ（`raw_thelook`）を読み、出力先だけを分けています。

### フォルダ

```
models/
  staging/   元データを1テーブルずつ整える層（stg_thelook__◯◯.sql、_thelook__sources.yml、_thelook__models.yml）
  marts/     分析用の完成形の層（fct_order_items.sql、_marts__models.yml）
dbt_project.yml
```

staging には、列名の変更、使う列の選択だけを置き、結合と集計は入れていません。

## 設計の判断

後から読んだときに、数字の意味で迷わないよう、決めたことと理由を残します。

### `fct_order_items`（ファクトテーブル）

| 項目 | 決めたこと | 理由 |
|---|---|---|
| 粒度（1行が表すもの） | 注文の**明細1つ**。主キーは `order_item_id` | 集計は、細かい表から粗い結果を作れるが、粗い表から細かい結果は作れない。問いに答えられる範囲で、一番細かい粒度にした |
| 時刻 | 元の時刻（UTC）は `orders_created_at` に残し、日本時間の列（`orders_created_at_jst`、`order_month_jst`）を**足す** | 置き換えると、元に戻せない。月別の集計は、日本時間の月で数える |
| 状態 | 注文（`orders`）ではなく、**明細（`order_items`）の `status`** を使う | 出荷や返品は、明細ごとに起きるため |
| 行の絞り込み | ファクトテーブルでは**しない**（全部の状態の行を残す） | 絞り込みは、問いごとの集計で行う（例：販売額は `Complete` のみ） |
| 結合 | `order_items` を土台に、すべて `left join` | 明細の行を落とさない。結合はすべて多対1で、行数は増えない |
| 属性（国、商品名） | ファクトテーブルに**横持ち**にした。`dim_` 表は作っていない | 分析する人が、結合せずに集計できる。dbt の公式ガイドでも、marts は「幅広く、概念単位」が基本 |

**弱み**：国と商品名は、元の `users` と `products` のコピーです。属性の「正」は、元の1か所で、このテーブルが持つのはコピーです。分析する人や用途が増えるなら、`dim_` 表に分ける設計もあり得ます。

### パーティションとクラスタリング

| 項目 | 決めたこと | 理由 |
|---|---|---|
| パーティション | `order_month_jst`（date）、粒度は月（約94区画） | 日単位だと約2,781区画になり、1区画が数十行で、細かすぎる。日本時間の月で絞る分析と、基準が合う |
| クラスタリング | `orders_created_at_jst`、`order_items_status` の順 | 月より細かい期間（日・週）で絞ることが多いと想定し、日時を先頭にした。注文IDやユーザーIDでの詳細検索は、主な用途ではないと判断した |

**使い方の約束**：月で絞るときは、`order_month_jst` の条件を必ず書きます。パーティションの列そのもので絞ったときだけ、読む量が減ります。

**弱み**：状態**だけ**で絞るクエリは、クラスタリングの先頭の列を飛ばすので、最適化されにくくなります（[Google の説明](https://docs.cloud.google.com/bigquery/docs/clustered-tables)）。

### 効果の確認

`fct_order_items` に、`sum(sale_price)` を求める3本のクエリを書き、実行前に表示される「処理されるバイト数」を比べました。

| クエリ | 絞り込み | 処理されるバイト数 |
|---|---|---|
| 1 | なし | 1.38 MB |
| 2 | `order_month_jst` で1か月 | **70.39 KB**（約 1/20） |
| 3 | `orders_created_at_jst` で、同じ1か月 | 2.76 MB |

- パーティションの列そのもので絞ると、読む量が減りました。別の列だけで絞っても、減りませんでした（クエリ3は、区画を読み飛ばしていません。2列を読むので、クエリ1の約2倍になっています）。
- テーブルの大きさは約15 MiB で、**クラスタリングの効果は、測れませんでした**。Google のドキュメントでは、クラスタリングが効きやすいのは、64 MB を超えるテーブルとされています。
- BigQuery のオンデマンドは、1テーブル・1クエリあたり**最低 10 MB** で計算されます（[料金のページ](https://cloud.google.com/bigquery/pricing)）。このデータの大きさでは、3本とも同じ料金になり、費用の差は出ません。

そのため、このプロジェクトで示せるのは、「設計の判断を説明できること」と、「パーティションが、読む量を減らすことの確認」までです。

### 取り込みと更新の方式

- **全件入れ替え**にしました（差分更新の `incremental` は見送り）。公開データは、過去の注文の状態や出荷日時が、あとから変わっているように見えました（原因は確かめきれていません）。差分で追加するだけでは、古い行が更新されずに残る危険があります。また、4テーブルを同じ世代でそろえる必要もあります（1つだけ新しいと、テストが落ちる）。全件で約18万行、作成は数秒のため、実益も出ません。
- 取り込み → dbt の順番は、**時刻をずらして**守らせています（10:30 に取り込み、15:30 に dbt）。簡単ですが、取り込みが遅れても、dbt は待ちません。弱みです。

## テスト

`dbt build` は、モデル5つとテスト13件、計18件です。

| 対象 | テスト |
|---|---|
| 主キー（`order_item_id`、`order_id`、`product_id`、`user_id`） | `unique`、`not_null` |
| `stg_thelook__orders.user_id` → `stg_thelook__users.user_id` | `relationships` |
| `stg_thelook__order_items.order_id` → `stg_thelook__orders.order_id` | `relationships` |
| `stg_thelook__order_items.product_id` → `stg_thelook__products.product_id` | `relationships` |
| `fct_order_items.order_item_id` | `unique`、`not_null` |

モデルと列の説明文は、各 `.yml` に書いています。`fct_order_items` の説明は、`persist_docs` の設定で、BigQuery のテーブルと列の説明にも反映されます。

## 取り込みと自動実行

| 処理 | 内容 | 期間 |
|---|---|---|
| 取り込み | BigQuery のスケジュールされたクエリ `Daily_thelook`。`create or replace table … as select * from …` で、4テーブルを入れ替え。毎日 10:30（JST） | 2026年10月20日〜10月30日（10月31日 0:00 JST の終了日で停止） |
| 変換 | dbt Cloud のジョブ `Daily build`（`dbt build`）。本番環境 `Production` で、GitHub の `main` を読んで実行。毎日 15:30（JST） | 2026年10月19日〜11月19日（その後、スケジュールを停止） |

- 取り込みの終了後、元データは固定されています。そのあとの dbt のジョブは、変わらないデータに対して動かし続けていたことになります。ポートフォリオ用のため、11月19日を最後に止めました。
- dbt のジョブが失敗したときは、メールで通知されるようにしています。
- 取り込みは、サービスアカウントではなく、自分の認証情報で実行しています。

## 注意点・制限

- **データが小さく、性能の改善は、数字として出にくい**（上の「効果の確認」のとおり）。
- **`dim_` 表は作っていません。** ファクトテーブルへの横持ちで、1表で完結させました。
- **差分更新（`incremental`）は、見送りました。**
- **取り込みを待つ仕組みは、ありません。** 順番は、時刻をずらして守らせています。実務では、依存関係を管理できる仕組みを使うほうがよいと考えます。
- **モデルの説明を、公開用のウェブページにはしていません。** dbt Cloud の画面で見られる形のため、このリポジトリの `.yml` が、説明の元になります。
- **コミット履歴は、公開用に作り直したものです。** 開発は、dbt Cloud の Studio と、非公開の作業用リポジトリで行い、公開用に、ファイルだけをコピーしました。開発の過程は、上の「設計の判断」に書いています。
- 元データの `sale_price` と `cost` の単位は、元データに記載がありません。

## 再現するには

dbt Cloud では、接続情報を画面に登録するため、このリポジトリには、接続の設定ファイル（`profiles.yml`）は入っていません。dbt Core での実行は、試していません。

1. 自分の Google Cloud プロジェクトと、dbt Cloud のアカウントを用意し、BigQuery につなぎます。
2. 公開データを、自分の BigQuery にコピーします。

   ```sql
   create schema if not exists `<your-project-id>.raw_thelook`
   options (location = 'US');

   create or replace table `<your-project-id>.raw_thelook.orders` as
   select * from `bigquery-public-data.thelook_ecommerce.orders`;
   -- order_items / products / users も、同じ形でコピーする
   ```

3. `models/staging/_thelook__sources.yml` の `database:` を、自分のプロジェクト ID に書き換えます。
4. dbt Cloud で `dbt build` を実行します（開発環境で、18件が Pass になるはずです）。

## `fct_order_items` の列

| 列 | 内容 |
|---|---|
| `order_item_id` | 明細ID（主キー） |
| `order_id` | 注文ID。1つの注文に、複数の明細があります |
| `orders_created_at` | 注文日時（UTC。元データのまま） |
| `orders_created_at_jst` | 注文日時（日本時間）。クラスタリングの1番目の列 |
| `order_month_jst` | 注文日の月の初日（日本時間）。パーティションの列 |
| `user_id` | ユーザーID |
| `country` | ユーザーの国（元データ `users` の `country`） |
| `product_id` | 商品ID |
| `product_name` | 商品名（元データ `products` の `name`） |
| `order_items_status` | 明細の状態（Cancelled、Complete、Processing、Returned、Shipped）。クラスタリングの2番目の列 |
| `shipped` | 出荷済みで、返品されていなければ 1、それ以外は 0 |
| `sale_price` | 明細の販売価格（元データのまま） |

使い方の例（月別・国別の販売額）：

```sql
select
    order_month_jst,
    country,
    sum(sale_price) as sales
from `<your-project-id>.dbt_analytics.fct_order_items`
where order_month_jst between '2025-01-01' and '2025-12-01'
  and order_items_status = 'Complete'
group by order_month_jst, country
order by order_month_jst, country;
```

## ライセンス・出典

- このリポジトリのコードは、[MIT ライセンス](LICENSE)です。
- このリポジトリに、**データは含まれていません**。元データは、BigQuery の公開データ `bigquery-public-data.thelook_ecommerce` です。元データの利用条件は、提供元（Google Cloud）の案内を確認してください。
