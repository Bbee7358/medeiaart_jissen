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

## Message Flow

```text
iPhone 12 Pro or mock sender
  -> ws://PC_IP:8787
  -> Node.js WebSocket server
  -> browser dashboard clients
```
