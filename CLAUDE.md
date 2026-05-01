# 家族スケジュール管理アプリ — Claude Code 引き継ぎ情報

## プロジェクト概要

Google Calendar API を使ったシングルファイルの家族スケジュール管理Webアプリ。
ローカルで `http-server` などを使い `http://localhost:8080/schedule-app.html` で動作。

**メインファイル:** `C:\Users\tabus\schedule-app\schedule-app.html`（1ファイルで完結）

---

## Google API 設定

| 項目 | 値 |
|------|-----|
| CLIENT_ID | `55276251258-eoumi828hrut2k9jp6b05iia31q4gloq.apps.googleusercontent.com` |
| GEMINI_KEY | `AIzaSyBN3msKNO7HrUsoBZ20J578aOheaCauH20` |
| calendarId | `primary`（ユーザーのメインカレンダー） |
| 認証方式 | Google Identity Services (GIS) + gapi.client |
| スコープ | `https://www.googleapis.com/auth/calendar` |

> **注意:** イベントの挿入・更新は必ず `calendarId: 'primary'` を使う。
> 家族共有カレンダー `family04811132425651718933@group.calendar.google.com` は **使わない**。

---

## アプリ構造（HTML内のJS）

### 主要変数
```javascript
var accessToken;        // Google OAuth2トークン
var events = [];        // 現在表示月のイベント配列
var members = [...];    // localStorage('sc_members')から読み込み
var ym = {y, m};        // 表示中の年月
```

### 主要関数
| 関数 | 役割 |
|------|------|
| `handleSignIn()` | Googleログイン |
| `handleSignOut()` | ログアウト |
| `loadEvents()` | 表示月のイベントをCalendar APIから取得 |
| `saveEvToApi(data)` | 新規イベント登録（insert） |
| `saveEv()` | 詳細モーダルからの保存 |
| `initUI()` | ログイン後のUI初期化 |
| `renderCal()` | カレンダーグリッド描画 |
| `renderMemberSettings()` | 設定タブのメンバー一覧描画 |
| `switchTab(name)` | タブ切り替え（'calendar','today','checklist','settings'） |
| `c2id(hex)` | HEXカラー → Google Calendar colorId変換 |

### colorId マッピング（`c2id`関数）
```javascript
'#7986CB'→'1', '#33B679'→'2', '#8E24AA'→'3', '#E67C73'→'4',
'#F6BF26'→'5', '#F4511E'→'6', '#039BE5'→'7', '#616161'→'8',
'#3F51B5'→'9', '#0B8043'→'10', '#D50000'→'11'
```

---

## メンバー設定（localStorage: `sc_members`）

現在設定済みの10名（TimeTreeのラベルカラーに対応）:

```json
[
  {"id":"fam",    "name":"家族",           "color":"#4CAF50"},
  {"id":"cyan",   "name":"モダーン・サイアン","color":"#00ACC1"},
  {"id":"toto",   "name":"トト",           "color":"#2196F3"},
  {"id":"bisco",  "name":"ビスコ",         "color":"#795548"},
  {"id":"black",  "name":"ミッドナイト・ブラック","color":"#424242"},
  {"id":"red",    "name":"アップル・レッド","color":"#F44336"},
  {"id":"riko",   "name":"リコ",           "color":"#E91E63"},
  {"id":"coral",  "name":"コーラル・ピンク","color":"#FF7043"},
  {"id":"yume",   "name":"ユメ",           "color":"#FFC107"},
  {"id":"kachan", "name":"かーちゃん",     "color":"#9C27B0"}
]
```

---

## イベントのメンバー管理方法

メンバー情報はGoogle Calendarイベントの **descriptionフィールド** と **colorId** に格納される:

```
description: "👥 トト\n"    ← メンバー名（複数時は「👥 名前1、名前2\n」）
colorId: "7"                ← 先頭メンバーの色に対応
```

イベント表示時はdescriptionから `👥` を含む行を読み取ってメンバーを識別する。

---

## 移行済みスケジュール（TimeTree → Google Calendar primary）

**期間:** 2026年9月〜2027年3月（51件挿入 + 既存1件 = 計52件）

### 確定したメンバー割り当て
| メンバー | イベント例 |
|----------|-----------|
| **トト** | 金井南運動会、ごみ回収、金島地区運動会、芸能発表打合わせ、芸能発表会、どんど焼き各種、上毛かるた各種、金井南町ブンカサイ、松葉取り、有紀さんの誕生日、中学生記念品贈呈、総会 |
| **家族** | 弁当持参日、白ばら運動会、運動会、親子運動遊び各種、園外保育もも、わかくさ清掃、保育参観各種、ひょうげん発表会 |
| **ユメ** | 3歳健診 |
| **コーラル・ピンク** | 1歳半健診 |
| **リコ** | マラソン大会、始業式、終業式、修了式 |
| **かーちゃん** | 学習参観 |
| **（未割り当て）** | 中村藍子の誕生日、友紀さん誕生日 |

---

## UI仕様（現在の状態）

- **ヘッダー:** 高さ38px（コンパクト）
- **タブバー:** top:38px、固定表示
- **カレンダー:** スクロールなしで全日表示（`height: calc(100vh - 82px)`）
- **メンバー凡例バー:** 削除済み（カレンダータブには表示しない）
- **チップ:** 12px、`font-size: 12px; padding: 2px 6px`
- **設定タブ:** 開くたびにlocalStorageから再読み込みして描画

---

## localStorage キー一覧

| キー | 内容 |
|------|------|
| `sc_members` | メンバー設定（JSON配列） |
| `sc_bl` | 持ち物リストデータ |
| `sc_notify` | 通知設定 |
| `sc_presets` | 持ち物プリセット |

---

## 既知の注意点

1. **トークン有効期限:** Google OAuth2トークンは1時間で期限切れ。ブラウザで再ログインが必要。
2. **イベント更新:** `gapi.client.calendar.events.patch` で description と colorId を更新。
3. **イベント削除:** 誤って家族共有カレンダーに挿入した場合は `events.delete` で削除すること。
4. **月またぎ表示:** TimeTreeの月表示は前月末の日付も表示するため、イベント取得時は日付で重複確認が必要。
5. **renderMemberSettings:** `switchTab('settings')` 時に毎回 localStorage から再読み込みして呼び出すよう修正済み（line 613-616）。
