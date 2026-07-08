# Protocol

## 概要

iPhone側は、PC側のWebSocketサーバーへタッチ判定イベントをJSONで送信します。

- Transport: WebSocket
- Encoding: UTF-8 JSON text
- Direction: iPhone to PC
- Schema: `shared/touch-event.schema.json`
- Version: `0.1.0`

PC側は受信したJSONを表示・ログ保存・演出接続に使います。

## 基本イベント

```json
{
  "version": "0.1.0",
  "source": "iphone-12-pro",
  "timestamp": 1720000000000,
  "handDetected": true,
  "isTouching": true,
  "region": "right_temporal_lobe",
  "regionLabel": "右側頭葉",
  "surface": "side",
  "surfaceLabel": "側面",
  "contactType": "index_fingertip",
  "distanceCm": 2.8,
  "durationSec": 0.72,
  "confidence": 0.84,
  "debug": {
    "indexTip2D": { "x": 0.52, "y": 0.43 },
    "indexTip3D": { "x": 0.12, "y": 0.34, "z": -0.81 },
    "depthMeters": 0.81,
    "fps": 30
  }
}
```

## フィールド

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `version` | string | yes | プロトコルバージョン |
| `source` | string | yes | 送信元デバイス |
| `timestamp` | integer | yes | Unix time milliseconds |
| `handDetected` | boolean | yes | 手または指先を検出できているか |
| `isTouching` | boolean | yes | 接触判定中か |
| `region` | string or null | yes | 判定された脳部位ID |
| `regionLabel` | string or null | yes | 表示用の脳部位名 |
| `surface` | string or null | yes | 接触面ID |
| `surfaceLabel` | string or null | yes | 表示用の接触面名 |
| `contactType` | string | yes | 接触に使われた部位 |
| `distanceCm` | number or null | yes | 指先と脳模型表面の距離 |
| `durationSec` | number | yes | 現在の接触継続時間 |
| `confidence` | number | yes | 判定信頼度。0.0から1.0 |
| `debug` | object | yes | デバッグ用情報 |

## `region`

初期候補です。実装が進んだら増減します。

- `left_frontal_lobe`
- `right_frontal_lobe`
- `left_parietal_lobe`
- `right_parietal_lobe`
- `left_temporal_lobe`
- `right_temporal_lobe`
- `left_occipital_lobe`
- `right_occipital_lobe`
- `cerebellum`
- `brainstem`
- `unknown`
- `null`

`null` は手が検出されていない、または判定不能な状態を表します。

## `surface`

初期候補です。

- `front`
- `back`
- `left`
- `right`
- `top`
- `bottom`
- `side`
- `unknown`
- `null`

## `contactType`

初期候補です。

- `index_fingertip`
- `hand_palm`
- `unknown`

最初は `index_fingertip` を主対象にします。

## 送信頻度

初期目標は 15から30 FPS です。

PC側では全イベントをログ保存できますが、演出システムへは状態変化だけ送る設計も検討します。

TODO:

- 常時送信か状態変化送信かを決める
- WebSocket再接続仕様を決める
- PCからiPhoneへ設定を送る双方向プロトコルを検討する

