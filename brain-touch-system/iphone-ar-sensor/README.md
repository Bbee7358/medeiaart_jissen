# iPhone AR Sensor

iPhone 12 Proをカメラ + LiDARセンサーとして使うための最小iOSアプリ構成です。

この段階では、ARSessionを起動し、LiDAR対応端末で `sceneDepth` または `smoothedSceneDepth` が利用できるかを画面に表示します。また、Apple Visionでカメラ画像から手の関節を検出し、PC側WebSocketサーバーへ1秒ごとにテストJSONを送信できます。

## 方針

Xcodeプロジェクトはこのリポジトリ内に生成済みです。

開くファイル:

```text
BrainTouchARSensor.xcodeproj
```

## 想定環境

- Xcode 15以降
- iOS 16以降
- 実機: iPhone 12 Pro
- Frameworks:
  - SwiftUI
  - ARKit
- RealityKit
  - Vision

LiDAR深度はシミュレータでは確認できません。必ずiPhone 12 Pro実機で実行してください。

## Xcodeで開く手順

1. Xcodeを開く
2. `BrainTouchARSensor.xcodeproj` を開く
3. 左側のプロジェクトナビゲータで `BrainTouchARSensor` プロジェクトを選ぶ
4. `TARGETS > BrainTouchARSensor` を選ぶ
5. `Signing & Capabilities` で自分のTeamを選ぶ
6. Bundle Identifierを自分の環境で一意になる名前にする

## 必要な権限

カメラを使うため、`Info.plist` に `NSCameraUsageDescription` が必要です。

このリポジトリでは `Config/Info.plist` に設定済みです。

Xcodeのターゲット設定で `Info` を開き、以下の項目を追加してください。

```text
Privacy - Camera Usage Description
```

値:

```text
Brain touch detection uses the camera and LiDAR depth sensor to align the AR scene with the physical brain model.
```

日本語にする場合:

```text
脳模型との位置合わせとLiDAR深度確認のためにカメラを使用します。
```

## 実機実行

1. iPhone 12 ProをUSBでMacに接続する
2. iPhone側で「このコンピュータを信頼」を許可する
3. Xcode上部の実行先にiPhone 12 Proを選ぶ
4. `Run` を押す
5. 初回起動時にカメラ権限を許可する

画面に以下が表示されれば最小構成は動作しています。

- AR session status
- depth available / unavailable
- current FPS
- current timestamp
- WebSocket URL
- connection status
- last sent timestamp
- last sent JSON

## 手の関節検出

Apple Visionの `VNDetectHumanHandPoseRequest` を使い、ARKitの `ARFrame.capturedImage` から手のポーズを検出します。

現在取得している関節:

- `wrist`
- `thumbTip`
- `indexTip`
- `middleTip`
- `ringTip`
- `littleTip`

最初は1つの手だけを対象にしています。画面には以下を表示します。

- `handDetected`
- `indexTip normalized x`
- `indexTip normalized y`
- `indexTip depth`
- `confidence`

Visionの正規化座標は左下原点のため、`ARSessionModel.convertVisionPointToNormalizedDisplay(_:)` でデバッグ表示向けに上方向を反転しています。実際の展示時のiPhone固定向きやフロント/バックカメラの見え方によって左右反転・回転の調整が必要になる可能性があるため、該当関数にTODOを残しています。

## LiDAR深度サンプリング

`DepthSampler.sampleDepthMeters(...)` で、Visionから得た `indexTip2D` に対応するLiDAR深度を取得します。

処理:

1. `ARFrame.smoothedSceneDepth` を優先して取得する
2. なければ `ARFrame.sceneDepth` を使う
3. `indexTip2D` の正規化座標を深度マップのピクセル座標へ変換する
4. 周辺5x5ピクセルをサンプリングする
5. confidence map がある場合、最低信頼度のサンプルを除外する
6. 有効な深度値の中央値を `depthMeters` として使う

深度が取れない場合、`debug.depthMeters` は `null` になります。

注意:

深度マップはカメラ画像と解像度が異なります。そのため、カメラ画像のピクセル座標ではなく、0から1の正規化座標を経由して深度マップへ変換しています。ただし、実機の固定向きによって深度マップとVision座標の回転・左右反転がずれる可能性があります。現場で表示を見ながら `DepthSampler` と `convertVisionPointToNormalizedDisplay(_:)` の変換を確認してください。

## PC側との接続手順

iPhoneとPCは同じWi-Fiに接続している必要があります。

PC側でWebSocketサーバーを起動します。

```sh
cd /Users/home_folder/Documents/sfc/mediaart_jissen/brain-touch-system/pc-dashboard
npm run server
```

別ターミナルで、必要に応じてダッシュボードも起動します。

```sh
npm run dev
```

ブラウザで以下を開きます。

```text
http://127.0.0.1:5173/
```

iPhoneから `127.0.0.1` や `localhost` を指定するとiPhone自身を指してしまうため、Mac/PCのローカルIPアドレスを使います。

MacでWi-FiのIPアドレスを確認します。

```sh
ipconfig getifaddr en0
```

例として `192.168.0.10` が表示された場合、iPhoneアプリのWebSocket URLには以下を入力します。

```text
ws://192.168.0.10:8787
```

入力後、`Connect` を押すと1秒ごとにテストJSONを送信します。PC側ダッシュボードで受信件数が増え、`logs/touch-events-YYYY-MM-DD.jsonl` に保存されれば通信成功です。

## 送信するテストJSON

送信JSONは `../shared/touch-event.schema.json` の必須フィールドに合わせています。

提示例の `region: "none"`、`surface: "none"`、`contactType: "none"` は現在の共有スキーマでは許可していないため、テスト送信では以下を使います。

- `region: null`
- `surface: null`
- `contactType: "unknown"`

手検出前の状態を表すため、`handDetected` と `isTouching` は `false` です。

Visionで手を検出できた場合は、以下も送信します。

- `handDetected: true`
- `debug.indexTip2D`
- `debug.fingerTips2D`
- `debug.depthMeters`
- `debug.indexTip3D`
- `debug.indexTip3DSpace`

## 指先3D座標

`PointUnprojector.unprojectPoint(...)` で、Visionの `indexTip2D` とLiDARの `depthMeters` を使い、指先の3D座標を計算します。

現在送信する `debug.indexTip3D` は `debug.indexTip3DSpace: "arkit_world"` の座標です。単位はメートルです。

ARKitワールド座標系:

- 原点はARSession開始時に決まる
- 単位はメートル
- `x`, `y`, `z` はARKitのワールド空間上の位置
- カメラが動いても同じ実空間上の点は近いワールド座標として扱える

内部では一度カメラ座標へ戻してから、`ARFrame.camera.transform` でワールド座標へ変換しています。

カメラ座標系の前提:

- `+X`: 画像右方向
- `+Y`: 画像上方向
- `-Z`: カメラ前方

注意:

Vision座標、ARKitカメラ画像、LiDAR深度マップは、実機の向きやマウント方向によって回転・左右反転がずれる可能性があります。現在の変換は縦向きデバッグ表示を前提にしています。最終展示の固定位置で、実際に指先を動かしながら `convertVisionPointToNormalizedDisplay(_:)`, `DepthSampler`, `PointUnprojector` の対応を確認してください。

`indexTip3D` は直近5サンプルの移動平均で平滑化しています。深度が取れない、または手が検出できない場合は `null` になります。

## LiDAR非対応端末の場合

LiDAR非対応端末やシミュレータでは、画面に以下が表示されます。

```text
LiDAR depth is not available
```

## まだ実装しないこと

- 脳模型との接触判定
- キャリブレーションUI

これらは次フェーズで追加します。

## ビルドについて

CLIでは、署名なしのビルド確認が通っています。

```sh
xcodebuild -project BrainTouchARSensor.xcodeproj -scheme BrainTouchARSensor -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

実機へインストールするには、Xcode上で自分のApple Account / Teamを選び、iPhone 12 Proを実行先にしてください。
