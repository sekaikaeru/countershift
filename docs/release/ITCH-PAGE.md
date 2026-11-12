# itch.io ページ用の文章

ページ: <https://useseka.itch.io/countershift>

## 1. 基本情報（入力欄）

| 欄 | 入力する内容 |
|---|---|
| Title | COUNTERSHIFT |
| Short description / tagline (EN) | No weapon. Trade places. Let your enemies shoot each other. |
| 短い説明 (JA) | 武器はない。入れ替われ。敵の攻撃を、敵に当てろ。 |
| Kind of project | HTML |
| Classification | Game |
| Genre | Action |
| Tags | arcade, score-attack, 2d, singleplayer, keyboard, minimalist, leaderboard, godot, game-off |
| Embed size | 1280 × 720、フルスクリーンボタンあり |
| Upload | 公開用 Web ビルドの ZIP（`tools/build_web.sh` の出力。「This file will be played in the browser」） |
| AI generation disclosure | 「AI を使った」を選ぶ。対象: Code、Sound / Music、Text。Graphics は画像生成ではないが、描画コードを AI が書いたため、欄があれば申告する（下の 4 を参照） |

## 2. 紹介文（English）

**COUNTERSHIFT** is a one-screen arena game made for Game Off 2026 (theme: SHIFT).

You have no weapon. The only thing you can do is **shift**: hold SHIFT to slow time, pick an enemy, release to
trade places with it. The enemy you leave behind is suddenly standing where you were — right in front of
everything its allies were about to do to you. For a few seconds it is *exposed*, and its own side destroys it.

An enemy destroyed this way explodes, and the blast spreads to the enemies around it. Line it up well and one shift clears half the screen.

- Five enemy types, each dangerous in a different way — and each a different kind of weapon once you learn to use it
- Chains: keep destroying enemies without a pause and the score multiplier climbs, up to ×9
- Wave after wave, three hit points (one comes back every five waves)
- **World ranking**: every score on the board was re-played and checked by the server. No account, no e-mail — just a name
- English and Japanese (the name field accepts Japanese input)
- No image or sound files: everything is drawn by code, and the sound effects and music are synthesised when the game starts

### Controls

| Key | Action |
|---|---|
| Arrow keys / WASD | Move. While holding SHIFT: aim |
| SHIFT or SPACE (hold) | Slow time and aim at an enemy |
| SHIFT or SPACE (release) | Trade places with that enemy |
| Same direction again | Aim at the next enemy further away |
| ESC / P | Pause |
| TAB (result screen) | World ranking |
| N (result / ranking screen) | Enter or change your name |
| F11 (F in menus) | Fullscreen |

Click the game once so it receives the keyboard.
On Windows, pressing SHIFT five times in a row may bring up the "Sticky Keys" prompt. Use SPACE instead.

### About the world ranking

Your score is not trusted as sent. The game records your inputs, and a verifier replays the whole run in the same
build before the score goes on the board. Normally this finishes shortly after your run.

The verifier runs on the developer's own computer. **When that computer is asleep or off, verification waits.**
Your run is kept and is checked when the verifier comes back — you do not have to do anything or keep the page
open. Until then the result screen shows "Waiting for verification", and the ranking screen shows
"A run of yours is being verified". Runs that were never sent (offline play) cannot be added later.

What is sent: the name you typed, and the record of your run (inputs, score, wave, play time). Nothing else.

## 3. 紹介文（日本語）

**COUNTERSHIFT** は、Game Off 2026（テーマ: SHIFT）のために作った、1 画面のアリーナアクションです。

武器はありません。できるのは **入れ替わること（SHIFT）** だけ。SHIFT を押している間、時間がゆっくりになります。
敵をねらって離すと、その敵と位置が入れ替わります。置き去りにされた敵は、さっきまであなたがいた場所――
味方の弾や突進が飛んでくる場所――に立たされ、数秒間「無防備」になって、味方に壊されます。

こうして壊れた敵は爆発し、爆発はまわりの敵に広がります。うまく並べれば、1 回の入れ替えで画面の半分が消えます。

- 敵は 5 種類。それぞれ違う危険があり、使い方を覚えれば、それぞれ違う武器になります
- 連鎖: 間をあけずに壊し続けると、スコアの倍率が最大 9 倍まで上がります
- 次々に来るウェーブ。耐久は 3（5 ウェーブごとに 1 回復）
- **世界ランキング**: 掲載されるスコアは、すべてサーバー側でプレイを再現して確かめたものです。登録もメールも不要で、名前だけで参加できます
- 日本語・英語対応（名前は日本語で入力できます）
- 画像・音声ファイルは使っていません。絵はすべてコードで描き、効果音と音楽は起動時に合成しています

### 操作

| キー | 動作 |
|---|---|
| 矢印キー / WASD | 移動。SHIFT を押している間は、ねらう方向 |
| SHIFT または SPACE（押し続ける） | 時間がゆっくりになり、敵をねらう |
| SHIFT または SPACE（はなす） | ねらった敵と位置を入れ替える |
| 同じ方向をもう一度押す | その方向の、次に遠い敵をねらう |
| ESC / P | 一時停止 |
| TAB（リザルト画面） | 世界ランキング |
| N（リザルト・ランキング画面） | 名前の入力・変更 |
| F11（メニューでは F も） | フルスクリーン |

最初にゲーム画面を 1 回クリックすると、キーボードが効くようになります。
Windows では SHIFT を 5 回続けて押すと「固定キー」の確認が出ることがあります。その場合は SPACE を使ってください。

### 世界ランキングについて

送られたスコアをそのまま信用することはしていません。ゲームはあなたの入力を記録し、検証役が同じビルドで
プレイ全体を再現して、一致したスコアだけをランキングに載せます。通常は、プレイのすぐあとに終わります。

検証役は、作者の手元のパソコンで動いています。**そのパソコンがスリープ中・停止中の間は、検証が進みません。**
記録は保存されていて、検証役が戻ったときに確認されます。何もする必要はなく、ページを開いたままにする必要も
ありません。それまでの間、リザルト画面には「検証待ちです。完了後にランキングへ反映されます。」、ランキング
画面には「検証中の記録があります。」と表示されます。送信されなかった記録（オフラインでのプレイ）を、あとから
登録することはできません。

送信されるのは、入力した名前と、プレイの記録（入力・スコア・ウェーブ・プレイ時間）だけです。

## 4. AI 利用の申告

### English

**This game was made with generative AI.**
The game design, all of the program code (game, shaders, ranking server, tests), the code that draws the graphics,
the code that synthesises the sound effects and music, and the in-game and store text were written by Claude
(Anthropic's AI model, through Claude Code) under the direction of the developer, who set the goals, made the
decisions, play-tested the game on a real machine and approved every release step.

No AI-generated image, audio or video files are used: the game contains no image or sound files at all.
The only third-party asset is the font Noto Sans JP.

### 日本語

**このゲームは生成 AI を使って制作しました。**
ゲームデザイン、すべてのプログラム（ゲーム本体、シェーダー、ランキングサーバー、テスト）、絵を描くコード、
効果音と音楽を合成するコード、ゲーム内とこのページの文章は、Claude（Anthropic の AI モデル。Claude Code 経由）が
作者の指示のもとで作成しました。作者は目標の設定、判断、実機でのテストプレイ、公開の各段階の承認を行いました。

AI が生成した画像・音声・動画のファイルは使っていません（このゲームには画像・音声ファイルがありません）。
外部の素材は、フォントの Noto Sans JP だけです。

## 5. クレジットとライセンス表記（ページの末尾に載せる）

```
COUNTERSHIFT — made for Game Off 2026 (theme: SHIFT)
© 2026 seka. All rights reserved.
Source code (public for the jam, not open source): https://github.com/sekaikaeru/countershift

Made with Godot Engine 4.7.2 — https://godotengine.org/license
This game uses Godot Engine, available under the following license:
Copyright (c) 2014-present Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
MIT License. Full text and the notices of the third-party components inside the engine:
https://github.com/sekaikaeru/countershift/blob/main/docs/release/THIRD-PARTY-NOTICES.md

Font: Noto Sans JP Bold — Copyright 2014-2021 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.
Licensed under the SIL Open Font License 1.1 (text included with the game: NotoSansJP-LICENSE.txt).
Noto is a trademark of Google Inc.
```

## 6. 画像

itch.io の公式の説明（Getting started）: カバー画像は 315:250 の比率。最小 315×250、推奨 630×500。
スクリーンショットは大きさ自由で、3〜5 枚が推奨。

掲載している画像は `promo/itch/` にある。すべて実際のゲーム画面で、プレイ中の画面はゲーム内蔵のデモ用 AI に
よる自動プレイ。カバーは、入れ替えの瞬間の画面に、タイトル画面から切り出したロゴを重ねたもの。

| 順 | ファイル | 場面 |
|---|---|---|
| カバー | `cover.png`（630×500） | 入れ替えの瞬間 + ロゴ |
| 1 | `screenshot_1_aim_slow_time.png` | SHIFT を押してねらう |
| 2 | `screenshot_2_shift_swap.png` | はなして入れ替わる |
| 3 | `screenshot_3_chain_burst.png` | 連鎖と倍率 |
| 4 | `screenshot_4_wave4_swarm.png` | ウェーブ 4 の群れ |
| 5 | `screenshot_5_howto_en.png` | あそびかたと敵 5 種 |
