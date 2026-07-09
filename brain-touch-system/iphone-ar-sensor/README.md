# iPhone AR Sensor

iPhone 12 Proをカメラ + LiDARセンサーとして使うための最小iOSアプリ構成です。

この段階では、ARSessionを起動し、LiDAR対応端末で `sceneDepth` または `smoothedSceneDepth` が利用できるかを画面に表示します。また、MediaPipe Hand Landmarkerでカメラ画像から手の21関節を検出し、PC側WebSocketサーバーへ1秒ごとにJSONを送信できます。

## 方針

Xcodeプロジェクトはこのリポジトリ内に生成済みです。

開くファイル:

```text
BrainTouchARSensor.xcodeproj
```

MediaPipeを有効化した後は、CocoaPodsが生成する次のファイルを開きます。

```text
BrainTouchARSensor.xcworkspace
```

## 想定環境

- Xcode 15以降
- iOS 16以降
- 実機: iPhone 12 Pro
- Frameworks:
  - SwiftUI
  - ARKit
  - RealityKit
  - MediaPipe Tasks Vision

MediaPipe Tasks VisionはCocoaPods経由で導入します。`pod install` を実行するまでは、アプリ上に `MediaPipeTasksVision not installed` と表示され、手検出は行われません。

LiDAR深度はシミュレータでは確認できません。必ずiPhone 12 Pro実機で実行してください。

## Xcodeで開く手順

1. Xcodeを開く
2. MediaPipe導入前は `BrainTouchARSensor.xcodeproj`、導入後は `BrainTouchARSensor.xcworkspace` を開く
3. 左側のプロジェクトナビゲータで `BrainTouchARSensor` プロジェクトを選ぶ
4. `TARGETS > BrainTouchARSensor` を選ぶ
5. `Signing & Capabilities` で自分のTeamを選ぶ
6. Bundle Identifierを自分の環境で一意になる名前にする

## MediaPipe導入

このアプリはApple VisionからMediaPipe Hand Landmarkerへ移行しています。MediaPipe本体はCocoaPodsで追加します。

```sh
cd /Users/home_folder/Documents/sfc/mediaart_jissen/brain-touch-system/iphone-ar-sensor
pod install
open BrainTouchARSensor.xcworkspace
```

もし `pod: command not found` と出る場合は、MacにCocoaPodsが入っていません。CocoaPodsをインストールしてから再度 `pod install` を実行してください。

MediaPipeモデルは `Resources/hand_landmarker.task` として同梱しています。

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
- last settings update
- last sent timestamp
- last sent JSON

## 手の関節検出

MediaPipe Hand Landmarkerを使い、ARKitの `ARFrame.capturedImage` から手のポーズを検出します。Apple Visionによる手検出は使っていません。

現在取得している関節:

- MediaPipeの21関節すべて
- `wrist`
- `thumbTip`
- `indexMCP`
- `indexPIP`
- `indexDIP`
- `indexTip`
- `middleTip`
- `ringTip`
- `littleTip`

最初は1つの手だけを対象にしています。画面には以下を表示します。

- `hand detector`
- `detector status`
- `detected joints`
- `hand inference`
- `handDetected`
- `indexTip normalized x`
- `indexTip normalized y`
- `indexTip depth`
- `depth sample`
- `depth confidence`
- `confidence`

画面上には、MediaPipeが返した21関節を点で表示し、手の骨格線も重ねて表示します。指先は黄色、その他の関節は水色、骨格線はミント色です。

MediaPipeへ渡すカメラ画像は、背面カメラの `ARFrame.capturedImage` を縦向きへ回転済みの画像として渡します。そのためMediaPipeの正規化座標は、まず縦向き画像内の座標として保持します。画面表示時には、ARViewのカメラプレビューがAspect Fillで横方向にクロップされる前提で、`CameraPreviewProjection.aspectFillPoint(...)` により表示座標へ変換します。

深度サンプリングでは、この縦向き画像座標を既存の深度サンプリング用座標へ戻して使います。実際の展示時のiPhone固定向きによって左右反転・回転の調整が必要になる可能性があります。

## LiDAR深度サンプリング

`DepthSampler.sampleIndexFingerDepth(...)` で、MediaPipeから得た人差し指座標に対応するLiDAR深度を取得します。

処理:

1. `ARFrame.smoothedSceneDepth` を優先して取得する
2. なければ `ARFrame.sceneDepth` を使う
3. `indexTip` ちょうどではなく、`indexTip` から `indexDIP` 側へ25%戻した点を深度サンプル点にする
4. MediaPipe表示座標を captured image のネイティブ正規化座標へ変換する
5. captured image正規化座標をdepth mapピクセルへ変換する
6. 周辺7x7ピクセルをサンプリングする
7. confidence map がある場合、最低信頼度のサンプルを除外する
8. 0.10mから2.00mの有効な深度だけを残す
9. 指先が背景より手前にある前提で、中央値ではなく20パーセンタイルを `depthMeters` として使う

深度が取れない場合、`debug.depthMeters` は `null` になります。

送信JSONには、原因分析用に以下も入ります。

- `debug.depthSample2D`
- `debug.rawImageNorm`
- `debug.depthPixel`
- `debug.depthMapSize`
- `debug.capturedImageSize`
- `debug.visionOrientation`
- `debug.depthConfidenceRaw`
- `debug.depthSource`
- `debug.depthStrategy`
- `debug.depthSampleCount`

注意:

現在は縦向き・背面カメラ固定で検証する前提です。iPhone画面で、黄色い点がMediaPipeの指先、骨格線がMediaPipeの手認識、深度サンプル表示が実際にdepthを読む点です。指を画面の左上、右上、左下、右下に動かし、関節点と深度サンプルが同じ方向へ動くか確認してください。全体的に横へズレる場合は `CameraPreviewProjection.aspectFillPoint(...)`、逆方向に動く場合は `MediaPipeHandLandmarker.normalizedLandmarkToDisplayPoint(_:)` または `DepthSampler.visionPointToRawImageNormalizedPortraitBack(_:)` の変換候補を調整します。

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

入力後、`Connect` を押すと1秒ごとに `touch_event` JSONを送信します。PC側ダッシュボードで受信件数が増え、`logs/touch-events-YYYY-MM-DD.jsonl` に保存されれば通信成功です。

PCダッシュボード側でしきい値を変更すると、同じWebSocket経由で `settings_update` がiPhoneへ送られます。iPhone画面の `last settings update` が更新され、Calibration内の `touch threshold`, `strong touch threshold`, `dwell time`, `confidence threshold`, `smoothing frames` に反映されれば受信成功です。受信した設定は `UserDefaults` に保存され、アプリ再起動後も保持されます。

## 送信するテストJSON

送信JSONは `../shared/touch-event.schema.json` の必須フィールドに合わせています。

提示例の `region: "none"`、`surface: "none"`、`contactType: "none"` は現在の共有スキーマでは許可していないため、テスト送信では以下を使います。

- `region: null`
- `surface: null`
- `contactType: "unknown"`

手検出前の状態を表すため、`handDetected` と `isTouching` は `false` です。

MediaPipeで手を検出できた場合は、以下も送信します。

- `handDetected: true`
- `debug.handDetectorSource`
- `debug.handDetectorStatus`
- `debug.handDetectorInferenceMs`
- `debug.handLandmarks2D`
- `debug.detectedJointCount`
- `debug.indexTip2D`
- `debug.fingerTips2D`
- `debug.depthMeters`
- `debug.indexTip3D`
- `debug.indexTip3DSpace`
- `debug.depthSample2D`
- `debug.rawImageNorm`
- `debug.depthPixel`
- `debug.depthConfidenceRaw`
- `debug.depthStrategy`
- `debug.calibration`

## 指先3D座標

`PointUnprojector.unprojectDepthSample(...)` で、depth map上のサンプルピクセルとLiDARの `depthMeters` を使い、指先の3D座標を計算します。

現在送信する `debug.indexTip3D` は `debug.indexTip3DSpace: "arkit_world"` の座標です。単位はメートルです。

ARKitワールド座標系:

- 原点はARSession開始時に決まる
- 単位はメートル
- `x`, `y`, `z` はARKitのワールド空間上の位置
- カメラが動いても同じ実空間上の点は近いワールド座標として扱える

内部では、`ARCamera.intrinsics` をdepth map解像度へスケールし、一度カメラ座標へ戻してから、`ARFrame.camera.transform` でワールド座標へ変換しています。

カメラ座標系の前提:

- `+X`: 画像右方向
- `+Y`: 画像上方向
- `-Z`: カメラ前方

注意:

MediaPipe座標、ARKitカメラ画像、LiDAR深度マップは、実機の向きやマウント方向によって回転・左右反転がずれる可能性があります。現在の変換は縦向きデバッグ表示を前提にしています。最終展示の固定位置で、実際に指先を動かしながら `MediaPipeHandLandmarker`, `DepthSampler`, `PointUnprojector` の対応を確認してください。

`indexTip3D` は直近5サンプルの移動平均で平滑化しています。深度が取れない、または手が検出できない場合は `null` になります。

## 脳模型タッチ判定

現在のタッチ判定は、読み込んだSTL脳モデルのサンプル表面を優先します。STLが読めない場合や最近傍点が取れない場合だけ、従来の楕円体判定へ戻ります。

手側はMediaPipeで検出した人差し指の `indexTip`, `indexDIP`, `indexPIP` をそれぞれLiDAR深度で3D化し、その中でSTL表面に一番近い点を採用します。指先1点だけだと、細い指先の深度が背景や脳表面へ抜けることがあるため、指の第一関節・第二関節側も候補に入れています。これにより、上面だけでなく側面に触れた時の判定が拾いやすくなります。

判定条件:

- STL表面から `touch threshold` cm以内なら接触候補
- STL表面から `strong touch threshold` cm以内なら強い接触候補
- 同じ領域に `dwell time` 秒以上留まり、confidenceが `confidence threshold` 以上なら `isTouching: true`
- 近いSTL表面の法線方向から `上面`, `左側面`, `右側面`, `前方`, `後方` を粗く分類する
- 手が高速移動している時はconfidenceを下げる

まだ三角形面への厳密な最近傍探索やBVHは入れていません。現段階ではSTLのサンプル頂点に対する近似距離です。最終精度を上げる段階で、三角面最近傍探索へ差し替える予定です。

従来の楕円体判定はフォールバックとして残しています。

初期状態の仮モデル:

- 中心座標: `BrainCalibration.defaults`
- 幅: `0.35m`
- 奥行き: `0.25m`
- 高さ: `0.18m`
- 形状: 楕円体

AR画面上では、仮楕円体そのものは表示せず、LiDAR深度差で検出した脳候補を青緑の点群、黄色のbbox、赤い重心マークで表示します。STL投影は緑の点群とオレンジのbboxで表示します。まずは「LiDARがどこを脳として検出しているか」と「STLが現実の脳に重なっているか」を直接確認する方針です。

実空間と仮楕円体の位置が合っていない場合は、指先を置きたい中心位置に持っていき、`Set Center Here` を押してください。現在の `indexTip3D` を楕円体中心として記録します。

## キャリブレーション

デバッグ画面の `Calibration` セクションで以下を調整できます。

- `brain center x`
- `brain center y`
- `brain center z`
- `brain width`
- `brain depth`
- `brain height`
- `touch threshold`
- `strong touch threshold`
- `dwell time`
- `confidence threshold`
- `smoothing frames`

変更した値は `UserDefaults` に保存され、アプリ再起動後も保持されます。`Reset calibration` を押すと初期値に戻ります。現在の設定値はWebSocketの `debug.calibration` にも入ります。

### STLメッシュ読み込み

`Resources/brain_model.stl` に、3Dプリント脳模型用のSTLを同梱しています。起動時にバイナリSTLのtriangle数とbounding boxだけを読み、`STL Mesh` セクションに表示します。

現在確認できる項目:

- `stl status`: STLを読み込めたか
- `stl resource`: ファイル名とtriangle数
- `stl raw size`: STLファイル内の生のbounding boxサイズ
- `stl mm->m size`: STL単位をmmと仮定した場合のサイズ
- `stl scale`: 実物横幅に合わせるためのscale
- `stl world size`: scale適用後の世界空間サイズとyaw
- `stl projection`: 現在のARカメラへ投影できたSTLサンプル点数
- `stl nearest distance`: 検出中の人差し指3D点とSTLサンプル表面の近似距離
- `stl nearest surface`: 近いSTL表面の粗い向き

今回のSTLはraw bounding boxの横幅が約 `0.816 units` で、一般的なmm単位STLより小さい正規化済みデータに見えます。そのため `stl mm->m size` は非常に小さく、`stl scale` は大きく表示されます。実際の判定では `mesh real width` に実物の横幅を入力し、その値を基準に世界空間サイズを決めます。

`Calibration` セクションで以下を調整できます。

- `mesh real width`: 実物の脳模型の横幅m。STL scaleの基準
- `mesh yaw`: 真上から見たSTLの回転角度

画面上では、STLのサンプル頂点を緑の点群、投影boundsと中心をオレンジで表示します。LiDAR差分の青緑点群・黄色bboxと、STL投影の緑/オレンジが重なるほど、現実の脳模型とSTL配置が合っている状態です。

タッチ判定では、STLサンプル頂点との近似距離を優先して使います。画面では `touch mode: stl mesh + index joints` と表示されます。まだ本番用の三角形最近傍探索やBVHは入れていないため、STL表面の凹凸や側面の一部で距離が粗くなる可能性があります。

STL投影は、LiDAR差分デバッグで実物位置に合っていた raw camera -> display 変換と同じ経路へ揃えています。`Calibrate Brain From Depth` を押すと、LiDAR候補の中心だけでなく、検出幅も `mesh real width` へ反映されます。まず「アプリ内でSTLが読める」「STLサイズとscaleが画面で確認できる」「LiDAR候補にSTL投影を重ねられる」「指先とSTL表面の距離感を見られる」状態を作っています。

### LiDAR深度差による粗い自動キャリブレーション

固定したiPhoneの下に何もない状態を先に記録し、そのあと置いた脳模型だけをLiDAR深度差で抽出して、仮楕円体の中心・幅・奥行き・高さへ反映できます。

実機での手順:

1. iPhoneを展示上部に固定する
2. カメラ中心から半径50cm程度の範囲に脳模型・手・ケーブルなどを置かない
3. アプリを起動し、`depth` が `available` になるまで待つ
4. `Capture Empty Baseline` を押す
5. `depth calibration` が `empty baseline captured` になることを確認する
6. 決めておいた向きで脳模型を置く
7. 手を画角に入れずに `Calibrate Brain From Depth` を押す
8. `depth calibration` が `brain calibrated from depth` になり、`depth calib estimate` に幅・奥行き・高さ・中心・検出bboxが表示されることを確認する
9. 画面上の青緑の点群、黄色bbox、赤い重心マークが実物の脳模型に重なるか見る
10. 必要に応じて `brain center x/y/z`, `brain width/depth/height` を手動で微調整する
11. 左側面・右側面・前方・後方を指で触って確認する
12. PCダッシュボードで `regionLabel`, `distanceCm`, `isTouching`, `confidence` が安定して表示されるか確認する

この方式は、空状態との差分で「手前に出てきた物体」を脳模型候補として扱います。キャリブレーション時に手や他の物が画角に入ると推定がずれます。iPhoneを動かした場合は、必ず `Capture Empty Baseline` からやり直してください。詳細は `../docs/depth-based-calibration.md` を参照してください。

### 手動微調整

判定ロジックは `TouchDetector` に分けています。`indexTip3D` と楕円体表面の距離を見て、以下のように判定します。

- 表面から `touch threshold` 以内: 接触候補
- 表面から `strong touch threshold` 以内: 接触強め
- 同じ領域に0.5秒以上留まる: `isTouching: true`
- `confidence threshold` 以上の信頼度で `isTouching: true`
- `smoothing frames`: 指先3D座標の移動平均に使うフレーム数
- 手が高速移動中: `confidence` を下げる
- 深度または3D座標が取れない: 接触判定しない

仮領域:

- `top`: 上面
- `left_side`: 左側面
- `right_side`: 右側面
- `front`: 前方
- `back`: 後方
- `center`: 中央
- `unknown`: 不明

送信JSONでは、`isTouching`, `region`, `regionLabel`, `surface`, `surfaceLabel`, `distanceCm`, `durationSec`, `confidence` がこの仮楕円体判定に基づいて更新されます。これは実際の脳部位ラベルではありません。

## 将来のメッシュ判定

現在は楕円体判定です。将来は、3Dプリントに使ったSTL / OBJ脳モデルを読み込み、指先3D点とメッシュ表面の最近傍点から接触距離と部位ラベルを返すメッシュ判定へ移行します。

その準備として、以下のインターフェースだけを追加しています。

- `BrainSurfaceModel`
- `NearestSurfaceHit`
- `BrainRegionResolver`

現段階では、実際のSTL / OBJパーサーやメッシュ最近傍探索は実装していません。楕円体判定とメッシュ判定は、将来的に `ellipsoid`, `mesh`, `hybrid` のように切り替えられる設計にします。詳細は `../docs/mesh-touch-detection.md` を参照してください。

## LiDAR非対応端末の場合

LiDAR非対応端末やシミュレータでは、画面に以下が表示されます。

```text
LiDAR depth is not available
```

## まだ実装しないこと

- STL / OBJ脳モデルとの本格的な接触判定
- PCからiPhoneへ脳模型中心・サイズを送る機能

これらは次フェーズで追加します。

## ビルドについて

CLIでは、署名なしのビルド確認が通っています。

```sh
xcodebuild -project BrainTouchARSensor.xcodeproj -scheme BrainTouchARSensor -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

実機へインストールするには、Xcode上で自分のApple Account / Teamを選び、iPhone 12 Proを実行先にしてください。
