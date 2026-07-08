# Architecture

## 目的

`brain-touch-system` は、展示作品用の「脳模型タッチ判定システム」です。

iPhone 12 Pro のカメラと LiDAR / ARKit を使って、来場者が人間サイズの3Dプリント脳模型のどの部位に触れたかを推定し、PC側のデバッグ画面や演出システムへ判定結果を送ります。

## 全体構成

```text
iPhone 12 Pro
  Swift / SwiftUI / ARKit
  - RGBカメラ入力
  - LiDAR深度
  - ARKit空間座標
  - 手または指先位置の推定
  - 脳模型との接触判定
  - WebSocketでJSON送信

        |
        | JSON over WebSocket
        v

PC
  WebSocket受信
  - デバッグ表示
  - イベントログ保存
  - 判定状態の可視化
  - 演出システムへの接続
```

## 責務分担

### iPhone側

iPhone側はセンサー・認識担当です。

- ARKitセッションを管理する
- カメラ映像と深度情報を取得する
- 手または指先の位置を推定する
- 脳模型座標系へ変換する
- 接触判定を行う
- 判定イベントをJSONとしてPCへ送る

TODO:

- 手検出方式を決める
- ARKitの深度取得方式を検証する
- iPhone 12 Pro実機で安定フレームレートを確認する

### PC側

PC側はデバッグ表示・ログ・演出接続担当です。

- iPhoneからのWebSocket接続を受ける
- 最新のタッチ判定を表示する
- 受信JSONをログとして保存する
- 距離、信頼度、FPSなどを可視化する
- 必要に応じてOSC、MIDI、WebSocket、HTTPなどで演出システムへ送る

TODO:

- 演出システムの接続方式を決める
- ログ形式を決める
- 展示本番用の監視UIを設計する

## 接触判定の段階設計

### Phase 1: 簡易形状

最初は3D脳モデルを使わず、楕円体または箱で接触判定します。

- 脳模型全体を1つの楕円体として近似する
- 左右、前後、上下面などの大まかな領域を判定する
- 距離しきい値で `isTouching` を決める

この段階では、展示体験の大枠、通信、ログ、デバッグ画面を先に安定させます。

### Phase 2: 粗い部位分割

楕円体または箱の上に、脳部位ラベルを簡易的に割り当てます。

- 前頭葉
- 頭頂葉
- 側頭葉
- 後頭葉
- 小脳など

この段階では、厳密なメッシュ衝突ではなく、座標範囲によるラベル判定を使います。

### Phase 3: 実脳モデル

最終的には STL / OBJ の脳モデルと部位ラベルに置き換えます。

- 模型と同じスケールの3Dモデルを読み込む
- 部位ごとのラベルデータを持つ
- 指先3D座標とメッシュ表面の距離を計算する
- 最近傍の部位ラベルを返す

TODO:

- STL / OBJ の入力形式を決める
- 部位ラベルの持ち方を決める
- メッシュ最近傍探索の実装場所を決める

## 座標系

初期設計では、以下の座標系を分けて考えます。

- Camera coordinate: iPhoneカメラ基準
- AR world coordinate: ARKitワールド基準
- Brain model coordinate: 脳模型基準
- Screen coordinate: デバッグ表示基準

iPhone側で Camera / AR world から Brain model coordinate へ変換し、PC側には判定済みイベントを送ります。

## ディレクトリ

```text
brain-touch-system/
  docs/
    architecture.md
    protocol.md
    calibration.md
    roadmap.md
  pc-dashboard/
  iphone-ar-sensor/
  shared/
    touch-event.schema.json
    sample-events/
```

