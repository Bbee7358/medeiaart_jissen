# Protocol

## 概要

iPhone側は、PC側のWebSocketサーバーへタッチ判定イベントをJSONで送信します。PC側は、同じWebSocket接続を使ってiPhone側へ判定設定を送信できます。

- Transport: WebSocket
- Encoding: UTF-8 JSON text
- Direction: bidirectional
- Schema: `shared/touch-event.schema.json`
- Version: `0.1.0`

PC側は受信したJSONを表示・ログ保存・演出接続に使います。

## メッセージ種別

すべての新規メッセージは、原則として `type` と `payload` を持つラッパー形式で送ります。

- `touch_event`: iPhoneからPCへ送るタッチ判定イベント
- `settings_update`: PCからiPhoneへ送る判定設定
- `hello` / `hello_ack`: `iphone_sensor` または `dashboard` の役割登録
- `settings_forwarded`: サーバーが設定をiPhoneへ転送した通知
- `settings_applied`: iPhoneが設定を保存・適用した通知
- `ping`: 接続確認
- `pong`: `ping` への応答

後方互換のため、PCサーバーは `type` なしの従来タッチイベントJSONも受け取れます。

## touch_event

```json
{
  "type": "touch_event",
  "payload": {
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
      "indexTip3DSpace": "arkit_world",
      "depthMeters": 0.81,
      "fps": 30
    }
  }
}
```

## 従来タッチイベント形式

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
    "indexTip3DSpace": "arkit_world",
    "depthMeters": 0.81,
    "fps": 30
  }
}
```

## settings_update

PCダッシュボードでしきい値を変更すると、PC側WebSocketサーバー経由で接続中のiPhoneへ以下を送ります。サーバーは最新設定を保持し、後から接続したiPhoneにも同じ設定を送ります。

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

| Field | Type | Description |
| --- | --- | --- |
| `touchThresholdCm` | number | 表面から何cm以内なら接触候補とするか |
| `strongTouchThresholdCm` | number | 表面から何cm以内なら強い接触候補とするか |
| `dwellTimeSec` | number | 接触候補が何秒継続したら接触確定とするか |
| `confidenceThreshold` | number | 接触確定に必要な信頼度。0.0から1.0 |
| `smoothingFrames` | integer | 指先3D座標の移動平均に使うフレーム数 |

不正な `settings_update` は無視し、PCサーバー側の警告として表示します。

## ping / pong

```json
{ "type": "ping" }
```

```json
{ "type": "pong", "timestamp": 1720000000000 }
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

## `debug`

| Field | Type | Description |
| --- | --- | --- |
| `indexTip2D` | object or null | Visionで検出した人差し指先の正規化2D座標。0から1 |
| `indexTip3D` | object or null | 人差し指先の3D座標。単位はメートル |
| `indexTip3DSpace` | string | `indexTip3D` の座標系。現在は `arkit_world` |
| `depthMeters` | number or null | 人差し指先位置でサンプリングしたLiDAR深度 |
| `fingerTips2D` | object | 各指先の正規化2D座標 |
| `fps` | number | iPhone側の推定FPS |
| `selectedFinger` | string or null | 実際にSTLへ最も近かった指 |
| `selectedFingerTip3D` | object or null | 判定に使用した平滑化済み指先3D |
| `selectedFingerDIP3D` | object or null | 選択指のDIP 3D |
| `surfaceApproachAlignment` | number or null | 指方向と表面法線の整合度 |
| `reprojectionErrorPixels` | number or null | 3D点を画像へ戻したときの誤差 |
| `calibrationValid` | boolean | 現ARSessionでキャリブレーション済みか |

`indexTip3D` の現在の座標系は `arkit_world` です。ARKitワールド座標は、ARSession開始時に決まる原点を基準にしたメートル単位の座標です。脳模型との距離判定に使うには、別途キャリブレーションで脳模型座標系へ変換する必要があります。

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
- `middle_fingertip`
- `ring_fingertip`
- `hand_palm`
- `unknown`

最初は `index_fingertip` を主対象にします。

## 送信頻度

センサー認識は最大30Hz、PCへのイベント送信は10Hzです。

PC側では全イベントをログ保存できますが、演出システムへは状態変化だけ送る設計も検討します。

TODO:

- 常時送信か状態変化送信かを決める
- WebSocket再接続仕様を決める
- `settings_update` のACK仕様を決める
