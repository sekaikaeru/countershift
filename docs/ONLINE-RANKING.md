# COUNTERSHIFT オンライン世界ランキング

状態（2026-11-11）: ローカルで完成・検証済み。Cloudflare へのデプロイ、D1 の作成、外部公開は**していない**（所有者の承認が必要）。
本番公開のコマンドは 8 章。

## 1. 仕組み（ひとことで）

サーバーはスコアを信用しない。プレイヤーは「サーバーが決めた乱数の種」で遊び、**全フレームのキー入力（リプレイ）**を送る。
検証役が**プレイヤーと同じ Web 版ビルド**でそのリプレイを最初から再計算し、同じスコアになった記録だけがランキングに載る。
検証が終わるまでは「検証中」で、公開ランキングには出ない。

```
ゲーム(Web)                 API (Workers + D1)                検証役（Mac などで動く Node + ヘッドレス Chrome）
 起動 ─ POST /v1/player ─────▶ 匿名 ID とトークンを発行
 開始 ─ POST /v1/run ────────▶ チケット（run_id と seed）
        POST /v1/run/start ──▶ 開始時刻を記録
 プレイ（入力を記録。ゲームの計算には一切関与しない）
 終了 ─ POST /v1/submit ─────▶ ヘッダー・時刻・種を検査 → pending で D1 に保存
                                                    ◀── GET /v1/verify/next（HTTPS、Bearer VERIFIER_TOKEN）
                                                         Web 版ビルドでリプレイを再計算
                              verified / rejected ◀──── POST /v1/verify/result
        POST /v1/submission ─▶ 状態と世界順位
        GET  /v1/top ────────▶ TOP100（検証済みだけ）
```

## 2. 本番構成（検証役と API の関係）

Workers の中ではゲームもブラウザーも動かせない（無料枠の CPU は 1 リクエスト 10 ms）。そのため検証は Workers の外で行う。

- **向き**: 検証役から API へ、外向きの HTTPS だけ。API から検証役へは何も送らない。Mac 側でポート開放・固定 IP・トンネルは不要。
- **認証**: `Authorization: Bearer VERIFIER_TOKEN`。トークンは Workers の secret と、検証役を動かすマシンの `server/.prod.secrets.json`（権限 600、git 管理外）だけに置く。ゲームには入れない。secret が 1 つでも欠けていれば API 全体が 503 で閉じる。
- **検証役の中身**: `server/verifier.mjs` が、公開したのと同じビルド（`build/web-prod`）を 127.0.0.1 だけで配信し、ヘッドレス Chrome で `?verify=1` として開く。Chrome との通信はパイプで、待ち受けポートを開かない。
- **待ち行列**: D1 の `submissions`（status = pending）。検証役が止まっていても記録は消えず、ランキングには出ないまま待つ。
- **Mac が停止・スリープしたとき**: 何も失われない。処理中だった 1 件は 120 秒の貸し出しが切れると、次の問い合わせで再び渡される。復帰後は古い順に処理する。
- **再起動後**: 検証役のコマンドをもう一度実行するだけ（自動起動にするなら launchd に登録）。Chrome が落ちた・固まった場合は検証役が自動で起動し直す。
- **版の一致**: リプレイのヘッダーに「プラットフォーム・BUILD・計算の指紋」を入れる。検証役は自分と 3 つとも同じ記録だけを受け取る。合う検証役がいない記録は 7 日待って「検証できる環境がない」として期限切れになる（不正扱いにはしない）。
- **二重検証の防止**: 貸し出し中の記録は他の検証役に渡らない。3 回貸し出して答えが返らない記録は却下する（検証役を止めるリプレイへの対策）。

## 3. チート対策の方式比較と選定

| 方式 | 公平性 | 実装 | サーバー費用 | Godot との相性 | 判定 |
|---|---|---|---|---|---|
| A. サーバーでゲームを進行 | 最高 | 入力遅延が出てアクションにならない。常時接続が必要 | 高い | 悪い | 不採用 |
| B. 入力リプレイを再計算 | 高い（規則に沿った入力で出せるスコアだけ通る） | シミュレーションが決定的なら可能 | 低い（1 件 1 秒未満） | 良い（`sim.gd` はノード非依存） | **採用** |
| C. 署名付きセッション＋行動ログの整合性 | 低い（鍵はクライアントにあり、ログは偽造できる） | 易しい | 低い | 良い | 単独では不採用。チケットと時刻検査として B に併用 |
| D. 統計的な異常検知だけ | 低い | 易しい | 低い | — | 事前のふるい分けにだけ使用 |

### 実測した事実

- **ネイティブ版（Apple Silicon）と Web 版は計算結果が食い違う**（挙動の指紋 3 本中 2 本が不一致）。再計算は Web 版ビルドで行う。
- **Chrome と WebKit（Safari のエンジン）は完全に一致する**（2026-11-11、`tools/xbrowser.mjs`）: ビルドの指紋が同じ、8 ゲーム分の挙動の指紋が同じ、
  WebKit で記録した 4 本を Chrome の検証役が検証、Chrome で記録した 4 本を WebKit 上の検証役が検証、いずれも全件一致。
  Web 版の wasm は数学関数を JavaScript から借りていない（wasm の import に数学関数なし）ので、ブラウザーごとの差が入り込む経路がない。
- **Firefox は未確認**（この Mac に入っていない）。仮に食い違う場合は指紋が変わるので、Chrome の検証役には渡らず「検証待ち → 期限切れ」になる。誤って不正扱いにはならない。

### 実際の保証範囲

保証できること（自動テストで確認）:

- 申告スコア・到達ウェーブ・プレイ時間が、リプレイを Web 版で再計算した結果と少しでも違えば載らない。
- 入力を書き換えたリプレイ、途中で切ったリプレイ、終了後にフレームを足したリプレイ、ありえないフレームを含むリプレイは載らない。
- 他人のリプレイの使い回しはできない（種がチケットごとに違う。チケットは 1 回だけ使える）。
- 早送りはできない（開始からの実時間がプレイ時間より短い記録は拒否）。スロー再生も制限される（実時間がプレイ時間＋15 分を超えると拒否、プレイ 1 秒あたり 400 コマを超える記録も拒否）。
- 検証役・管理用の入口は秘密トークンがないと開かない。
- 本番ビルドでは試験用の URL オプション（自動プレイの記録送信、API の差し替えなど）が無効になる（`tools/prodcheck.mjs`）。

保証できないこと（限界）:

- **人間が操作したかどうかは分からない**。規則どおりの入力を実時間で出す自作ボットや、入力を注入するツールの記録は通る。
- 一時停止は 15 分まで認めているので、こまめに止めて考える遊び方は防げない。
- 記録を捨てて何度もやり直すこと（運のよい種を待つ）は防げない。
- 検証役が止まっている間は、新しい記録は「検証待ち」のままでランキングに出ない。
- ネイティブ版（PC 実行ファイル）の記録は、同じ OS・CPU の検証役がないと検証できない。現状の検証役は Web 用だけ。

上位に不自然な記録が出たときは、管理コマンドで非表示・削除・BAN できる（7 章）。

## 4. API

すべて JSON。CORS は `*`（Cookie は使わない）。エラーは `{ok:false, error:"コード"}`。

| メソッド | パス | 内容 | 制限 |
|---|---|---|---|
| POST | `/v1/player` | 匿名プレイヤーを作る → `player_id`, `token` | 接続元ごとに 3 回/分・20 回/日 |
| POST | `/v1/run` | チケット発行 → `run_id`, `seed`, `build` | プレイヤーごとに 20 回/分（`run/start`・`name` と合算） |
| POST | `/v1/run/start` | 開始時刻を記録（発行から 30 分以内、1 回だけ） | 同上 |
| POST | `/v1/submit` | 記録を送る（`name`, `score`, `wave`, `replay`） | 6 回/分・200 回/日 |
| POST | `/v1/submission` | 送った記録の状態と自分の順位 | 60 回/分 |
| POST | `/v1/name` | 名前の変更 | `run` と合算 |
| GET | `/v1/top?limit=100&player=ID` | TOP100、総数、指定プレイヤーの順位と自己ベスト | 接続元ごとに 60 回/分 |
| GET | `/v1/verify/next?platform=1&fp=指紋` | 検証役: 次の記録を借りる | `VERIFIER_TOKEN` |
| POST | `/v1/verify/result` | 検証役: 再計算の結果 | `VERIFIER_TOKEN` |
| GET/POST | `/v1/admin/*` | 管理（一覧・待ち行列・非表示・改名・BAN・削除・再検証・掃除） | `ADMIN_TOKEN` |

- 1 分あたりの制限は Workers の Rate Limiting 機能で数える（D1 に書かない。拠点ごとの概算で、厳密ではない）。1 日の上限だけ D1 で数える。
  Rate Limiting の設定がない環境（ローカル）では D1 で数える。
- 順位: スコアの高い順。同点は**先に記録した方が上**。同一プレイヤーは最高スコアだけが対象。
- 名前: 1〜12 文字。英数字・ひらがな・カタカナ・漢字と `ー・ _.-`。NFKC で正規化。HTML 記号・絵文字・制御文字・不適切語は拒否。
- SQL はすべてプレースホルダーで束縛。ゲーム側は名前を図形として描くだけで、マークアップとして解釈しない。
- Workers は**リプレイ全体を展開しない**（先頭の 28 バイトのヘッダーだけ読む）。最大サイズ（1.76MB）の送信でも CPU は中央値 5〜8 ms（Node での計測。workerd での実測は未実施）。

## 5. 保存するデータ

| 表 | 内容 |
|---|---|
| `players` | ランダムな ID、トークンの SHA-256、名前、作成時刻、BAN フラグ |
| `runs` | チケット（種、発行・開始時刻、使用済みか）。3 日で削除（cleanup） |
| `submissions` | 送られた記録と検証結果。リプレイ本体は**現在の自己ベストの分だけ**残し、ほかは検証後に消す |
| `scores` | 公開ランキング（1 人 1 行） |
| `meta` | ランキングの人数（トリガーで増減。数え直しのための全件読みをしない） |
| `rate` | 1 日の回数上限のカウンター。キーは日替わりソルト付きハッシュで、IP アドレスそのものは保存しない |

メールアドレス・アカウント・端末情報は集めない。プレイヤー側には ID・トークン・名前・オンライン自己ベストを保存する
（Web ではブラウザーの IndexedDB）。保存データを消すと別人として扱われる（引き継ぎ機能はない）。

## 6. 記録の長さの上限

送信できるリプレイは圧縮後 1.9MB まで（D1 の 1 行 2MB 制限）。超える記録は、送信せずに「プレイが長すぎて送信できません」と表示する。

| 条件 | 1 分あたり | 上限の目安 |
|---|---|---|
| 実測: ヘッドレス Chrome 60fps（フレーム時間がほぼ一定） | 1.1KB | 1,000 分以上 |
| 試算: 60Hz、フレーム時間が 0.1 ms 刻みでばらつく | 5.5KB | 約 340 分 |
| 試算: 144Hz、同上 | 12.7KB | 約 146 分 |
| 試算（最悪）: 144Hz、フレーム時間がほぼ乱数 | 67.6KB | 約 27 分 |

自動プレイの最長は約 20 分なので、通常の環境では上限に届かない見込み。最悪条件の環境が実在するかは未確認。

## 7. 運用

管理コマンド（`server/admin.mjs`。本番は `--api <URL>` を付け、`ADMIN_TOKEN` を環境変数で渡す）:

| コマンド | 内容 |
|---|---|
| `list` / `list pending` / `list rejected` | ランキング / 検証待ち / 却下の一覧 |
| `queue` | 検証待ちの件数を「必要な検証役（プラットフォーム・BUILD・指紋）」ごとに表示。減らない組は検証役がいない |
| `hide <player_id>` / `unhide` | ランキングから隠す / 戻す |
| `rename <player_id> <名前>` | 名前を直す |
| `ban <player_id>` / `unban` | 以後の参加を止め、記録を隠す |
| `delete <player_id>` | そのプレイヤーのデータをすべて消す（削除依頼への対応） |
| `requeue <submission_id>` | 検証をやり直す |
| `cleanup` | 古いチケット・却下記録・回数カウンターを消し、7 日たった検証待ちを期限切れにする（週 1 回程度） |

ゲームの規則を変えたとき: `scripts/replay.gd` と `server/src/api.js` の `BUILD` を同時に上げ、API → Web 版 → 検証役の順に同じ版でそろえる。
古い版からの送信は「旧バージョン」として断られる（ゲーム自体は遊べる）。

## 8. 本番公開の手順（すべて所有者の承認後。上から順に実行）

方針（2026-11-11 決定）: **COUNTERSHIFT 専用の Cloudflare アカウント**を使う。ほかのプロジェクトのアカウントは使わない。
Cloudflare への操作はすべて `tools/cf.mjs` 経由で行い、素の `wrangler` は使わない。

### 8-0. アカウント分離の仕組み

| 仕組み | 内容 |
|---|---|
| 専用の API トークン | 専用アカウントだけが見えるトークンを `server/.cf.env`（git 管理外、権限 600）に置く。wrangler は環境変数のトークンを保存済みログインより先に使う（wrangler 4.160.0 の実装で確認） |
| 設定フォルダーの分離 | `XDG_CONFIG_HOME` を `server/.cf-home` に向けるので、ほかのプロジェクト用のログイン情報は読まれず、その隣に何も書かれない。`wrangler login` / `logout` はこの道具からは実行できない |
| 実行前の確認 | 毎回 Cloudflare に問い合わせ、「トークンが見えるアカウントが 1 つだけ」「それが `.cf.env` のアカウント」「`countershift-` で始まらない名前の Worker・D1 がない」「固定（pin）したアカウントと同じ」を確かめ、違えば止まる |
| 変更操作の二重確認 | 読み取り以外のコマンドは、アカウント ID の下 4 桁を `CF_CONFIRM` で渡さないと実行しない |
| 表示 | アカウント名と ID の下 4 桁、対象の Worker・D1 を表示する。ID の全体とトークンは表示しない |

公式仕様で確認したこと: `CLOUDFLARE_API_TOKEN`（自動化用の認証）と `CLOUDFLARE_ACCOUNT_ID`（対象アカウント）は wrangler の正式な環境変数。
`account_id` は設定ファイルにも書けるが、ID を git に残さないため環境変数だけを使う。
wrangler には名前付きの認証プロファイル（`wrangler auth create` など）もあるが、実験的機能なので使わない。

### 8-1. 所有者が手で行う準備（ブラウザーでの操作）

1. Cloudflare に **COUNTERSHIFT 専用のアカウント**を新規登録する（ほかのプロジェクトとは別のメールアドレス。`+countershift` のような別名でもよい）。二要素認証を有効にする。
   普段のブラウザーでほかのプロジェクトの Cloudflare にログイン中なら、別のブラウザープロファイルかプライベートウィンドウで作業する。
2. ダッシュボードの「Workers & Pages」を一度開き、`workers.dev` のサブドメインを決める（公開 API の住所の一部になる）。
3. 「アカウント API トークン」または「マイプロフィール → API トークン」で**カスタムトークン**を作る:
   - 権限: アカウント / **Workers スクリプト: 編集**、アカウント / **D1: 編集**、アカウント / **アカウント設定: 読み取り**
   - アカウントリソース: **この専用アカウントだけ**を含める（「すべてのアカウント」にしない）
   - ゾーンの権限は付けない。有効期限は任意
4. 専用アカウントのアカウント ID（ダッシュボードの概要に表示される 32 桁）を控える。
5. ターミナルで `server/.cf.env` を作る（値は自分で貼り付ける。チャットやログには出さない）:

```bash
cd ~/Games/countershift && (umask 077; printf 'CLOUDFLARE_API_TOKEN=\nCLOUDFLARE_ACCOUNT_ID=\n' > server/.cf.env) && open -e server/.cf.env
```

   開いたファイルの `=` の後ろにトークンとアカウント ID を貼って保存する。

### 8-2. 分離の確認（読み取りだけ）

```bash
cd ~/Games/countershift && node tools/cf.mjs check
```

期待: 専用アカウントの名前、`Workers (0): none`、`D1 databases (0): none`、最後に `ok`。
ほかのプロジェクトのアカウントや、複数のアカウントが見えるトークンだと `STOP:` で止まる。

表示されたアカウントが正しければ固定する（`xxxx` は表示された ID の下 4 桁）:

```bash
CF_CONFIRM=xxxx node tools/cf.mjs pin
```

ほかのプロジェクト側が無傷であることの確認（任意。そのプロジェクトのフォルダーで、これまでどおりのログインのまま）:

```bash
cd <ほかのプロジェクトのフォルダー> && npx wrangler whoami
```

期待: これまでと同じ、そのプロジェクトのアカウントが表示される（`tools/cf.mjs` は保存済みログインを読み書きしない）。

### 8-3. D1 を作ってスキーマを適用する（2026-11-12 実施済み）

専用アカウントに `countershift-ranking` を作成し、スキーマを適用した（表 6・索引 4・トリガー 3・初期値 1 行。リモートの定義を名前ごとに照合済み）。
やり直す場合のコマンド（どちらも再実行して壊れない）:

```bash
CF_CONFIRM=xxxx node tools/cf.mjs wrangler d1 create countershift-ranking
```

```bash
CF_CONFIRM=xxxx node tools/cf.mjs wrangler d1 execute countershift-ranking --remote --file=schema.sql
```

### 8-4. secret を作る（ローカルだけ。Cloudflare には何も送らない）

API は 3 つの secret がそろわないと動かない。1 つでも欠けている・32 文字未満・仮の値（`dev-salt` など）・互いに同じ値なら、
すべての入口が `503 not_configured` を返す（ゲームはオフライン扱いで遊べる）。

| 名前 | 用途 |
|---|---|
| `RATE_SALT` | 回数制限のために接続元を日替わりのハッシュにするときの塩。IP アドレスそのものを保存しないため |
| `VERIFIER_TOKEN` | 検証役だけが検証待ちの記録を受け取り、結果を返すための鍵 |
| `ADMIN_TOKEN` | 管理コマンド（非表示・削除・BAN など）の鍵 |

```bash
cd ~/Games/countershift && node tools/make_secrets.mjs
```

`server/.prod.secrets.json`（git 管理外、権限 600）にランダムな 64 文字の値が 3 つ作られる。値は表示されず、既存のファイルは上書きしない。
確認（値は出ない）:

```bash
node tools/make_secrets.mjs check
```

### 8-5. 非公開のまま、secret と一緒に初回デプロイする

`server/wrangler.toml` は `workers_dev = false`・`preview_urls = false` になっている。この状態のデプロイでは Worker に公開の住所が付かない。
`--secrets-file` で secret を同じデプロイに含めるので、「secret のない版」が動く瞬間がない。

```bash
node tools/cf.mjs wrangler deploy --dry-run
```

```bash
CF_CONFIRM=xxxx node tools/cf.mjs wrangler deploy --secrets-file .prod.secrets.json
```

確認（読み取りだけ。secret は名前だけ表示される）:

```bash
node tools/cf.mjs wrangler secret list
```

```bash
node tools/cf.mjs wrangler deployments list
```

```bash
node tools/cf.mjs inventory
```

期待: secret が 3 つ、Worker は `countershift-ranking` だけ、D1 は `countershift-ranking` だけ。
この時点では API の住所に接続しても応答しない（非公開）。

### 8-6. 公開用の Web 版を作る（ローカルだけ）

API の住所（公開後に有効になる）を表示する:

```bash
node tools/cf.mjs url
```

その住所を `<API>` として:

```bash
tools/build_web.sh <API>
```

`build/web-prod/`（と `build/countershift-web-prod.zip`）ができ、`files xxxxxxxx` という照合用の値が表示される。
`scripts/api_config.gd` は自動で元に戻る。この時点ではまだ何も公開されていない。

### 8-7. API を公開する

`server/wrangler.toml` の `workers_dev = false` を `workers_dev = true` に書き換えてから:

```bash
CF_CONFIRM=xxxx node tools/cf.mjs wrangler deploy
```

secret は前の版から引き継がれる。直後に確認する:

```bash
curl -s <API>/v1/health
```

```bash
curl -s <API>/v1/top
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' "<API>/v1/verify/next?platform=1&fp=1"
```

期待: `{"ok":true,"build":3}`、`{"ok":true,"entries":[],"total":0,...}`、最後は `401`。
`{"ok":false,"error":"not_configured"}` が返る場合は secret が届いていない。すぐ `workers_dev = false` に戻してデプロイし直す。

### 8-8. 検証役を接続する（この Mac で動かし続ける）

```bash
cd ~/Games/countershift && caffeinate -i node server/verifier.mjs --prod --build-dir build/web-prod --api <API>
```

`--prod` は `VERIFIER_TOKEN` を `server/.prod.secrets.json` から読む（コマンドラインや履歴に値が残らない）。
`VERIFIER READY platform 1 build 3 fp ...` と出れば接続済み。`caffeinate -i` は実行中のスリープを防ぐ（ふたを閉じると止まる）。
止めるときは Ctrl+C。Mac を再起動したら、このコマンドをもう一度実行する。

### 8-9. 公開前の実プレイ確認

公開用ビルドをこの Mac だけで配信し、本番 API に対して 1 回遊ぶ:

```bash
cd ~/Games/countershift/build/web-prod && python3 -m http.server 8780 --bind 127.0.0.1
```

http://127.0.0.1:8780/ を開き、名前入力 →「検証中」→「世界順位」になること、タイトルの「世界ランキング」に出ることを確認する。
確認用の記録を消す場合:

```bash
cd ~/Games/countershift && node server/admin.mjs --prod --api <API> list
```

```bash
cd ~/Games/countershift && node server/admin.mjs --prod --api <API> delete <player_id>
```

### 8-10. ゲームの公開

`build/countershift-web-prod.zip` を配布先（itch.io など）に上げる。配布ページに「名前とプレイ記録を送ること」「削除の依頼先」を書く。
公開後は、検証役が使う `build/web-prod` を作り直さない（作り直すなら公開側も同じものに差し替える）。

## 9. 障害時の復旧とロールバック

| 状況 | 対応 |
|---|---|
| 検証役が止まった | 8-8 のコマンドを再実行。待っていた記録は古い順に処理される。件数は `admin.mjs queue` で確認 |
| ランキングを急いで止めたい | `server/wrangler.toml` の `workers_dev` を `false` に戻して `CF_CONFIRM=xxxx node tools/cf.mjs wrangler deploy`。API が届かなくなり、ゲームは自動でオフライン扱いになる（遊べる。記録は対象外） |
| API の新版に問題がある | `node tools/cf.mjs wrangler deployments list` で前の版の ID を確認し、`CF_CONFIRM=xxxx node tools/cf.mjs wrangler rollback <version-id> -m "理由"`。D1 のデータと secret は戻らない |
| D1 のデータを壊した | Time Travel で巻き戻す（無料プランは過去 7 日）。下のコマンド |
| 無料枠の上限に達した | その日の UTC 0 時まで API がエラーになる。ゲームはオフライン扱いで遊べる。続くなら Workers Paid に上げる |
| 検証役・管理のトークンが漏れた | `server/.prod.secrets.json` を別名で退避して `node tools/make_secrets.mjs` で作り直し、`CF_CONFIRM=xxxx node tools/cf.mjs wrangler secret bulk .prod.secrets.json` で入れ替え、検証役を起動し直す |
| Cloudflare の API トークンが漏れた | ダッシュボードでそのトークンを削除し、新しいトークンを `server/.cf.env` に入れ直す |
| すべて撤去する | `CF_CONFIRM=xxxx node tools/cf.mjs wrangler delete`（Worker）と `CF_CONFIRM=xxxx node tools/cf.mjs wrangler d1 delete countershift-ranking`（D1）。元に戻せない |

D1 の巻き戻し（上書きされる破壊的な操作。実行前に必ず現在位置を控える）:

```bash
node tools/cf.mjs wrangler d1 time-travel info countershift-ranking
```

```bash
CF_CONFIRM=xxxx node tools/cf.mjs wrangler d1 time-travel restore countershift-ranking --timestamp=<UNIX秒 または ISO 8601>
```

手動バックアップ（出力に署名付き URL が出るので、ログを貼らない）:

```bash
node tools/cf.mjs wrangler d1 export countershift-ranking --remote --output=backup-$(date +%Y%m%d).sql
```

## 10. 無料枠と想定コスト

Cloudflare の公式ページで 2026-11-11 に確認した値:

| 項目 | Workers Free | 備考 |
|---|---|---|
| リクエスト | 100,000 / 日（UTC 0 時にリセット） | 超えるとエラー 1027 |
| CPU 時間 | 10 ms / リクエスト | ときどきの超過は許容、続くと打ち切り |
| D1 読み取り | 500 万行 / 日 | 超えるとその日は D1 が使えない |
| D1 書き込み | 10 万行 / 日 | 索引の更新も 1 行と数える |
| D1 容量 | 1 DB 500MB、合計 5GB、DB は 10 個まで | 1 行は 2MB まで |
| D1 Time Travel | 7 日 | Paid は 30 日 |

Rate Limiting 機能の料金は公式ページに記載が見つからなかった（第三者の記事では追加料金なし。**未確認**）。Workers Paid の月額もこの調査では確認していない。

この設計での消費の見積もり（コードから数えた値。実測ではない）:

| 動作 | リクエスト | D1 書き込み |
|---|---|---|
| 検証役の待ち受け（10 秒ごと） | 8,640 / 日 | 0 |
| 記録を送らないプレイ（自己ベスト未更新） | 2 | 約 4 行 |
| 自己ベストを更新するプレイ | 約 8〜10（状態の確認を含む） | 約 15 行 |
| ランキングを開く | 1 | 0 |

目安: 無料枠で 1 日あたり数千プレイまで。先に尽きるのは D1 の書き込み（すべて更新プレイなら約 6,000 回/日）。
読み取りは、自分の順位を数える処理が「自分より上の人数」だけ行を読むため、登録者が数千人を超えると効いてくる
（例: 1 万人・平均 5,000 位なら、ランキング表示 1,000 回で 500 万行）。そこまで育ったら Workers Paid にするか、順位の計算を間引く。

### 検証用 Chrome の稼働方法と費用

検証役は Cloudflare の認証情報を持たない（持つのは `VERIFIER_TOKEN` だけ）。どのアカウントで API を動かしても、動かし方は同じ。

| 方法 | 費用 | 向き・不向き |
|---|---|---|
| A. この Mac で必要なときだけ動かす | 0 円 | 公開直後の様子見向き。動かしていない間の記録は「検証待ち」で残り、次に動かしたときにまとめて処理される |
| B. この Mac で常時動かす（`caffeinate -i`、または launchd で自動起動） | 電気代だけ | ふたを閉じる・電源を切ると止まる。復帰後は自動で追いつく |
| C. 常時稼働の小さなサーバー（Chrome が動く Linux など） | 月額がかかる（金額は未調査） | 安定。ただしそのマシンの Chrome で計算の指紋が一致するかは未確認。一致しなければ記録を受け取れないので、起動時の `fp` の値を Mac の値と比べて確かめる |
| D. Cloudflare の Browser Rendering / Containers | 未調査 | WebGL でゲームが起動するか未確認。Workers の中で直接 Chrome を動かす前提にはしない |

負荷の目安: 1 件の検証は 0.3〜1 秒（3 分のプレイ）。待ち受け中は 10 秒に 1 回 API を見に行くだけで、Mac への負荷は小さい。
公開初期は A か B で始め、検証待ちが日常的にたまるようになったら C を検討する。

## 11. テスト

```bash
node --test server/test/*.test.mjs                               # API 21 件＋アカウント確認 7 件
$GODOT --headless --path . -s tools/replay_test.gd               # 記録 → 再計算の一致、改ざんの検出（24 項目）
$GODOT --headless --path . -s tools/golden.gd | diff - docs/golden-baseline.txt   # ゲームの挙動が v1.0 と同じか
$GODOT --headless --path . -- --flowtest=1                       # キー操作で全画面を一巡
$GODOT --headless --path . -- --uicheck=1                        # 全画面・両言語の文字はみ出し
node tools/e2e.mjs                                               # Web 版＋API＋検証役の通し（約 7 分）
node tools/recovery.mjs                                          # 検証キューの復旧（停止・再起動・リース切れ・Chrome クラッシュ）
node tools/xbrowser.mjs --webkit <webkit_run>                    # Chrome と WebKit の相互検証
tools/build_web.sh http://127.0.0.1:8801 && node tools/prodcheck.mjs   # 本番ビルドの確認（確認後、本番用に作り直すこと）
```

- ヘッドレス Chrome は専用の一時プロファイルで起動する（ふだん使っている Chrome のデータには触れない）。
- WebKit の確認は `tools/webkit_run.swift` をビルドして使う（`swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk tools/webkit_run.swift -o <出力先>`）。
  画面には何も出さず、Safari 本体のデータも読まない。
- ローカルで遊ぶ: `node server/dev.mjs` → http://127.0.0.1:8787/
