# PC Dashboard

iPhone 12 Proから送られてくる脳模型タッチ判定JSONをWebSocketで受信し、Web画面にリアルタイム表示するデバッグダッシュボードです。

まだ映像・音・LED・演出システムとの接続は実装していません。

## Ports

- WebSocket server: `8787`
- Vite dev server: `5173`

## Setup

```sh
npm install
```

## Development

ターミナルを2つ使います。

```sh
npm run server
```

```sh
npm run dev
```

ブラウザで以下を開きます。

```text
http://127.0.0.1:5173/
```

## Mock Events

iPhoneがまだない状態では、別ターミナルでモック送信を起動します。

```sh
npm run mock
```

1秒ごとに `../shared/sample-events/` のサンプルJSONをWebSocketサーバーへ送ります。

## Logs

WebSocketサーバーは、受信した有効なタッチイベントをJSON Lines形式で保存します。

- 保存先: `logs/`
- ファイル名: `touch-events-YYYY-MM-DD.jsonl`
- 形式: 1行に1イベントのJSON
- 不正なJSON: 保存せず、サーバーコンソールに警告を出す
- 必須フィールド不足: `../shared/touch-event.schema.json` の `required` を使って検出し、保存せず警告を出す

例:

```text
logs/touch-events-2026-07-08.jsonl
```

ダッシュボードには以下の集計を表示します。

- 今日の受信件数
- 今日の接触確定件数

接触確定は `isTouching: true` かつ `confidence >= 0.75` のイベントです。

## Threshold Controls

ダッシュボードには、展示中に接触判定の目安を確認するためのしきい値調整パネルがあります。

設定値はブラウザの `localStorage` に保存されます。ダッシュボードがWebSocketサーバーへ接続している場合、変更時に `settings_update` としてiPhone側へ配信されます。

- `touch threshold cm`: 指先と仮脳模型表面の距離が何cm以内なら接触候補と見るか
- `strong touch threshold cm`: 指先と仮脳模型表面の距離が何cm以内なら強い接触候補と見るか
- `dwell time seconds`: 同じ条件を何秒以上満たしたら接触確定と見るか
- `confidence threshold`: 信頼度がどれ以上なら接触確定条件として扱うか
- `smoothing frames`: iPhone側で指先3D座標を移動平均するときに使うフレーム数

パネルでは、現在受信している `distanceCm`, `durationSec`, `confidence` がしきい値を満たしているかを個別に表示します。すべて満たすと「接触確定条件を満たしている」と表示されます。

送信される設定メッセージは以下です。

```json
{
  "type": "settings_update",
  "payload": {
    "touchThresholdCm": 5,
    "strongTouchThresholdCm": 3,
    "dwellTimeSec": 0.5,
    "confidenceThreshold": 0.75,
    "smoothingFrames": 5
  }
}
```

WebSocketサーバーは最新の設定を保持し、後から接続したiPhoneにも送ります。不正な `settings_update` は破棄され、サーバー警告としてダッシュボードのConnection Diagnosticsに表示されます。

## Build

```sh
npm run build
```

## Production-like Server

WebSocketサーバーだけ起動します。

```sh
npm run start
```

ビルド済みWeb UIを配信する本番サーバーはまだ未実装です。展示用には、後続フェーズで静的配信またはPCアプリ化を検討します。

## iPhoneから接続するURL

iPhone側のWebSocket接続先は、PCのローカルIPアドレスを使います。

```text
ws://<PCのIPアドレス>:8787
```

IPアドレスで接続できないが `.local` が開ける環境では、Bonjour名を使います。

```text
ws://WatanabenoMacBook-Air.local:8787
```

Safariで先に以下を開いて確認します。

```text
http://WatanabenoMacBook-Air.local:8787/health
```

例:

```text
ws://192.168.1.23:8787
```

MacでIPアドレスを確認する方法:

```sh
ipconfig getifaddr en0
```

有線LANを使っている場合は、環境によって `en1` などになることがあります。

```sh
ifconfig
```

で `inet 192.168...` や `inet 10...` のような同一ネットワーク上のアドレスを確認してください。

## Connection Diagnostics

WebSocketサーバーは、同じ `8787` 番ポートでHTTP診断も返します。

iPhoneのSafariで以下を開いてください。

```text
http://<PCのIPアドレス>:8787/health
```

例:

```text
http://172.17.1.54:8787/health
```

IP直打ちが失敗して `.local` だけ開ける場合は、`.local` を優先してください。

```text
http://WatanabenoMacBook-Air.local:8787/health
```

このJSONが表示されれば、iPhoneからMacのWebSocketサーバーまで到達できています。その場合、iPhoneアプリのWebSocket URLは同じIPを使って以下にします。

```text
ws://<PCのIPアドレス>:8787
```

`.local` で確認できた場合は以下です。

```text
ws://WatanabenoMacBook-Air.local:8787
```

Safariで `/health` が開けない場合は、アプリ実装ではなくネットワーク到達性の問題です。以下を確認してください。

- iPhoneとMacが同じWi-Fiに接続されている
- iPhoneがモバイル通信や別SSIDを使っていない
- 学内/展示会場Wi-Fiで端末間通信がブロックされていない
- macOSのファイアウォールでNode.jsへの外部接続が許可されている
- VPNやセキュリティソフトがローカル通信を遮断していない

候補IPと確認URLは以下でも表示できます。

```sh
npm run net
```

Node/WebSocketを疑う前に、最小HTTPサーバーでも確認できます。

```sh
npm run http-test
```

`8000` 番が使用中の場合は以下を使います。

```sh
npm run http-test:8001
```

iPhone Safariで、表示されたURLを開きます。

```text
http://<MacのIPアドレス>:8000/
```

これも開けない場合、WebSocketやiPhoneアプリの問題ではなく、iPhoneからMacへのTCP通信が届いていません。

学内/会場Wi-Fiで端末間通信がブロックされる場合は、iPhoneのインターネット共有を使うのが確実です。

1. iPhoneで `設定 > インターネット共有` をオンにする
2. MacをそのiPhoneのインターネット共有に接続する
3. PC側で `npm run net` を実行する
4. `172.20.10.x` のような候補が出たら、iPhone Safariで `http://172.20.10.x:8787/health` を開く
5. 開けたら、iPhoneアプリのWebSocket URLを `ws://172.20.10.x:8787` にする

テザリング中でも `172.17...` など以前のWi-Fi側IPを使うと接続できません。テザリング時は、多くの場合 `172.20.10.x` がMac側の正しいIPになります。

より深く見る場合は、Mac側でiPhoneからのパケットが届いているか確認します。

```sh
sudo tcpdump -ni en0 "tcp port 8787"
```

USBテザリングや別インターフェースの場合は `en0` を `en6` などに変えてください。

- tcpdumpに何も出ない: IP違い、別ネットワーク、Wi-Fiの端末間通信ブロック、VPN/フィルタが原因候補
- SYNは出るがHTTPが成立しない: pf、セキュリティソフト、返り経路の問題が原因候補
- `8000` は開けるが `8787` だけ開けない: Nodeサーバー、8787番、プロセス、ポートフィルタが原因候補

## Message Flow

```text
iPhone 12 Pro or mock sender
  -> ws://PC_IP:8787
  -> Node.js WebSocket server
  -> browser dashboard clients
```
