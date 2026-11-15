extends RefCounted
## Two-language text table. Add a language by adding a column.

const LANGS := ["en", "ja"]
const LANG_NAMES := {"en": "English", "ja": "日本語"}

const T := {
	"tagline": ["YOU HAVE NO WEAPON.  TRADE PLACES.", "武器はない。入れ替われ。"],
	"loading": ["SYNTHESIZING SOUND", "サウンドを合成中"],
	"menu_start": ["START", "スタート"],
	"menu_how": ["HOW TO PLAY", "あそびかた"],
	"menu_rank": ["WORLD RANKING", "世界ランキング"],
	"rk_title": ["WORLD RANKING", "世界ランキング"],
	"rk_rank": ["RANK", "順位"],
	"rk_name": ["NAME", "名前"],
	"rk_date": ["DATE", "記録日"],
	"rk_you": ["YOUR RECORD", "あなたの記録"],
	"rk_world": ["WORLD RANK", "世界順位"],
	"rk_of": ["of %s players", "%s 人中"],
	"rk_best": ["ONLINE BEST", "オンライン自己ベスト"],
	"rk_none": ["No record yet.\nFinish a run to enter.", "まだ記録がありません。\nプレイすると登録されます。"],
	"rk_empty": ["No records yet. Be the first.", "まだ記録がありません。最初の記録を狙おう。"],
	"rk_loading": ["LOADING", "読み込み中"],
	"rk_error": ["Could not reach the ranking server.", "ランキングサーバーに接続できません。"],
	"rk_retry": ["R  TRY AGAIN", "R  再試行"],
	"rk_off": ["Online ranking is not available here.", "ここではオンラインランキングを利用できません。"],
	"rk_nav": ["↑↓ SCROLL     R REFRESH     N NAME     M MY RANK     ESC BACK", "↑↓ スクロール     R 更新     N 名前変更     M 自分の順位     ESC もどる"],
	"rk_updated": ["UPDATED %s", "%s 更新"],
	"rk_pending": ["A run of yours is being verified.", "検証中の記録があります。"],
	"rk_noname": ["NO NAME YET", "名前未設定"],
	"rk_out": ["OUTSIDE TOP 100", "100 位圏外"],
	"on_sending": ["SENDING THE RECORD…", "記録を送信中…"],
	"on_verifying": ["VERIFYING THE REPLAY…   provisional #%d", "リプレイを検証中…   暫定 %d 位"],
	"on_queued": ["Waiting for verification. It will appear on the ranking afterwards.", "検証待ちです。完了後にランキングへ反映されます。"],
	"on_verified": ["WORLD RANK  #%d", "世界順位  %d 位"],
	"on_newbest": ["ONLINE BEST UPDATED", "オンライン自己ベスト更新"],
	"on_notbest": ["Your online best of %s still stands.", "オンライン自己ベスト %s は未更新です。"],
	"on_offline": ["OFFLINE RUN — not eligible for the ranking.", "オフラインのため、この記録はランキング対象外です。"],
	"on_error": ["Could not send the record.     S  SEND AGAIN", "記録を送信できませんでした。     S  再送信"],
	"on_rejected": ["The record was not registered: %s.", "記録は登録されませんでした（%s）。"],
	"on_need_name": ["N  ENTER A NAME TO JOIN THE RANKING", "N  名前を入力してランキングに参加"],
	"why_timing": ["play time does not match", "プレイ時間の不一致"],
	"why_mismatch": ["the replay does not match", "リプレイの不一致"],
	"why_build": ["an old version of the game", "ゲームが旧バージョン"],
	"why_rate": ["too many requests, try later", "送信回数の上限"],
	"why_name": ["the name cannot be used — press N", "名前が使えません。N で変更"],
	"why_long": ["the run is too long to send", "プレイが長すぎて送信できません"],
	"why_env": ["no verifier for this browser or version", "このブラウザー・版を検証できる環境がありません"],
	"why_other": ["it could not be verified", "検証できませんでした"],
	"name_title": ["ENTER YOUR NAME", "名前を入力"],
	"name_rule": ["Up to 12 characters: letters, digits, kana, kanji", "12 文字まで（英数字・かな・漢字）"],
	"name_bad_empty": ["Type a name first, then press ENTER.", "名前を入力してから ENTER を押してください。"],
	"name_bad_long": ["Too long: 12 characters at most.", "長すぎます。12 文字までです。"],
	"name_bad_chars": ["Only letters, digits, kana, kanji and  _ . -  can be used.", "使えない文字があります（英数字・かな・漢字と _ . - のみ）。"],
	"name_privacy": ["Only the name and the run record are sent. No account, no e-mail.", "送信されるのは名前とプレイ記録だけです。登録やメールは不要です。"],
	"name_nav": ["ENTER  OK          ESC  CANCEL", "ENTER  決定          ESC  やめる"],
	"menu_lang": ["LANGUAGE", "言語"],
	"menu_vol": ["VOLUME", "音量"],
	"menu_full": ["FULLSCREEN", "フルスクリーン"],
	"on": ["ON", "オン"],
	"off": ["OFF", "オフ"],
	"nav": ["↑↓ SELECT     ENTER CONFIRM     ←→ CHANGE", "↑↓ えらぶ     ENTER 決定     ←→ 変更"],
	"best": ["BEST", "ベスト"],
	"demo": ["DEMO PLAY", "デモプレイ"],
	"how_title": ["HOW TO PLAY", "あそびかた"],
	"how1_h": ["MOVE", "移動"],
	"how1_b": ["Arrow keys or WASD.", "矢印キー または WASD。"],
	"how2_h": ["HOLD SHIFT", "SHIFT を押す"],
	"how2_b": ["Time slows down.\nAim at an enemy with the arrow keys.", "時間がゆっくりになる。\n矢印キーで敵をねらう。"],
	"how3_h": ["RELEASE", "はなす"],
	"how3_b": ["You and that enemy\ntrade places.", "ねらった敵と\n位置が入れ替わる。"],
	"how4_h": ["EXPOSED", "無防備"],
	"how4_b": ["The shifted enemy turns white.\nIts allies destroy it, and the blast spreads.", "入れ替えた敵は白く光る。\n味方の攻撃で壊れ、爆発が広がる。"],
	"how_note": ["SPACE works the same as SHIFT.     ESC: pause", "SPACE でも SHIFT と同じ操作ができます。     ESC: 一時停止"],
	"how_back": ["ENTER / ESC  BACK", "ENTER / ESC  もどる"],
	"en0": ["SWARMER", "スウォーマー"],
	"en0_b": ["Chases you. Bites anything exposed.", "追ってくる。白い敵にかみつく。"],
	"en1": ["GUNNER", "ガンナー"],
	"en1_b": ["Shoots straight at you.", "こちらをねらって弾を撃つ。"],
	"en2": ["CHARGER", "チャージャー"],
	"en2_b": ["Dashes along the red line.", "赤い線にそって突進する。"],
	"en3": ["LANCER", "ランサー"],
	"en3_b": ["Aims, then fires a laser.", "ねらいを定めてレーザーを撃つ。"],
	"en4": ["BOMBER", "ボマー"],
	"en4_b": ["Explodes near you, or when destroyed.", "近づくと爆発。壊されても爆発。"],
	"hint1": ["HOLD  SHIFT  (or SPACE) — time slows", "SHIFT（または SPACE）を押し続ける — 時間がゆっくりになる"],
	"hint2": ["AIM with the arrow keys, then RELEASE to trade places", "矢印キーでねらい、はなすと入れ替わる"],
	"hint3": ["The shifted enemy is EXPOSED — let its allies destroy it", "入れ替えた敵は無防備 — 味方の攻撃を当てさせろ"],
	"hint4": ["Keep destroying to raise the multiplier", "続けて倒すと倍率が上がる"],
	"score": ["SCORE", "スコア"],
	"wave": ["WAVE", "ウェーブ"],
	"wave_clear": ["WAVE CLEAR", "ウェーブクリア"],
	"repair": ["SHIELD +1", "シールド +1"],
	"chain": ["CHAIN", "チェイン"],
	"shift_kill": ["SHIFT KILL", "シフトキル"],
	"burst": ["%d BURST", "%d 連鎖"],
	"paused": ["PAUSED", "一時停止"],
	"resume": ["RESUME", "つづける"],
	"retry": ["RETRY", "やりなおす"],
	"to_title": ["TITLE", "タイトルへ"],
	"over": ["SHIFT OVER", "シフト終了"],
	"new_record": ["NEW RECORD", "新記録"],
	"r_wave": ["WAVE", "到達ウェーブ"],
	"r_time": ["TIME", "生存時間"],
	"r_kills": ["DESTROYED", "倒した数"],
	"r_shift": ["SHIFT KILLS", "シフトキル"],
	"r_chain": ["BEST CHAIN", "最大チェイン"],
	"r_burst": ["BIGGEST BURST", "最大連鎖"],
	"rank": ["RANK", "ランク"],
	"r_nav": ["ENTER  RETRY        TAB  RANKING        ESC  TITLE", "ENTER  もう一度        TAB  ランキング        ESC  タイトル"],
	"tip0": ["TIP: Lure the swarm close, then shift with a far enemy.", "ヒント: 群れを引きつけてから、遠くの敵と入れ替わろう。"],
	"tip1": ["TIP: Shift with a gunner while its own bullet is in the air.", "ヒント: 弾が飛んでいる間に、撃ったガンナーと入れ替わろう。"],
	"tip2": ["TIP: Stand on a charger's red line, then leave someone else there.", "ヒント: チャージャーの赤い線に立ち、別の敵を身代わりにしよう。"],
	"tip3": ["TIP: A destroyed bomber takes its neighbours with it.", "ヒント: ボマーを壊すと、まわりの敵も巻きこめる。"],
	"tip4": ["TIP: Tap the same direction again to aim at the next enemy.", "ヒント: 同じ方向をもう一度押すと、その先の敵をねらえる。"],
	"tip6": ["TIP: Framed enemies cannot be shifted. Catch them in a blast.", "ヒント: 枠つきの敵とは入れ替われない。爆発に巻きこもう。"],
	"tip5": ["TIP: Destroying enemies refills the SHIFT gauge.", "ヒント: 敵を倒すと SHIFT ゲージが回復する。"],
}

## Words for a player who is using the touch controls (scripts/touch.gd sets `touch`). Only the texts that
## name keys are listed; everything else is shared. "" hides a line whose job a touch button does.
const TOUCH := {
	"nav": ["", ""],
	"rk_nav": ["", ""],
	"how_back": ["", ""],
	"r_nav": ["", ""],
	"rk_retry": ["Tap REFRESH to try again", "「更新」を押して再試行"],
	"on_need_name": ["Tap NAME to join the ranking", "「名前」を押してランキングに参加"],
	"on_error": ["Could not send the record.     Tap SEND AGAIN", "記録を送信できませんでした。     「再送信」を押してください"],
	"why_name": ["the name cannot be used — tap NAME", "名前が使えません。「名前」で変更"],
	"name_bad_empty": ["Type a name first, then tap OK.", "名前を入力してから OK を押してください。"],
	"how1_b": ["Left side of the screen:\nslide your thumb (the stick).", "画面の左側で親指をすべらせる\n（スティック）。"],
	"how2_h": ["HOLD RIGHT", "右側を押し続ける"],
	"how2_b": ["Time slows while you hold\nthe right side of the screen.\nAim with the stick.", "画面の右側を押している間、\n時間がゆっくりになる。\nスティックで敵をねらう。"],
	"how3_h": ["RELEASE", "指をはなす"],
	"how_note": ["Next enemy further away: let the stick return to the centre, then push the same way again.", "その先の敵をねらう: スティックを中央に戻して、同じ方向へ倒し直す。"],
	"hint1": ["HOLD the RIGHT side of the screen — time slows", "画面の右側を押し続ける — 時間がゆっくりになる"],
	"hint2": ["AIM with the left stick, then LIFT your right thumb to trade places", "左のスティックでねらい、右の指をはなすと入れ替わる"],
	"tip4": ["TIP: Centre the stick, then push the same way again to aim at the next enemy.", "ヒント: スティックを中央に戻して同じ方向へ倒し直すと、その先の敵をねらえる。"],
}

var lang := "en"
var touch := false           # true while the player is using the touch controls


func set_lang(code: String) -> void:
	lang = code if code in LANGS else "en"


func next_lang() -> void:
	lang = LANGS[(LANGS.find(lang) + 1) % LANGS.size()]


func t(key: String) -> String:
	if touch and TOUCH.has(key):
		return TOUCH[key][LANGS.find(lang)]
	if not T.has(key):
		return key
	return T[key][LANGS.find(lang)]
