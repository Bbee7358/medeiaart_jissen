# Mesh Touch Detection

## 目的

現在のiPhoneアプリは、仮の脳模型として楕円体を置き、指先3D座標と楕円体表面の距離で接触候補を判定しています。

将来的には、3Dプリントに使った STL / OBJ 脳モデルを読み込み、実際の模型形状に近い表面最近傍点と三角面ラベルから `regionId` を返す構成へ移行します。このドキュメントは、そのための設計メモです。

この段階では、STL / OBJ読み込みや最近傍探索の実装は行いません。

## 3Dモデル読み込み

将来の入力候補は以下です。

- OBJ: group name / material name に部位IDを持たせやすい
- 複数OBJ: 部位ごとに別ファイルとして管理しやすい
- STL: 三角形形状だけなら扱いやすいが、標準では部位ラベルを持ちにくい
- 複数STL: 部位ごとに別ファイルに分けることでラベルを外部管理しやすい

初期実装では、ラベル管理のしやすさを優先し、OBJの group name または部位ごとの複数メッシュを優先します。STLを使う場合は、別JSONで `triangleId` またはファイル名と `regionId` を対応付けます。

## 座標系の対応

判定では以下の座標系を分けます。

- ARKit world space: `PointUnprojector` が出す `indexTip3D`
- Brain model space: STL / OBJモデルの原点・向き・スケールを基準にした座標
- Mesh local space: ファイル内の頂点座標

基本の流れ:

1. iPhone固定位置でARSessionを開始する
2. キャリブレーションで脳模型中心、スケール、向きを決める
3. `indexTip3D` を ARKit world space から brain model space へ変換する
4. brain model spaceの点をメッシュ最近傍探索に渡す
5. ヒットした表面点を `NearestSurfaceHit` として返す

楕円体判定で使っている `BrainCalibration` は、将来のメッシュ判定でも初期キャリブレーション値として使えます。ただし、メッシュでは回転も必要になるため、中心・サイズに加えて姿勢行列またはクォータニオンを追加する予定です。

## 最近傍点探索

指先3D点とメッシュ表面の距離は、三角形表面への最近傍点で求めます。

想定する処理:

1. 指先点を brain model space に変換する
2. BVH / KD-tree / 空間グリッドなどで候補三角形を絞る
3. 各候補三角形に対して最近傍点を計算する
4. 最短距離の三角形を `triangleId` として返す
5. 最近傍点、距離、法線、信頼度を `NearestSurfaceHit` にまとめる

展示ではリアルタイム性が重要なので、全三角形を毎フレーム総当たりする実装は避けます。最初の実装では、モデルを軽量化するか、事前に空間インデックスを作ります。

## 表面法線による上面/側面分類

メッシュ判定では、部位IDとは別に `surface` / `surfaceLabel` も返します。

分類の目安:

- 法線のY成分が大きく上向き: `top`
- 横向き成分が大きい: `left`, `right`, `side`
- Z方向の前後成分が大きい: `front`, `back`
- 下向きで来場者が触りにくい: `bottom` または `unknown`

最終的な向きは、展示での模型設置方向とbrain model spaceの定義に依存します。法線分類は固定値ではなく、キャリブレーション後の座標系に合わせて調整します。

## triangleId から regionId への変換

`triangleId` から `regionId` へ変換する責務は `BrainRegionResolver` に分けます。

想定する入力:

- `triangleId`
- OBJ group name
- material name
- メッシュファイル名
- 外部JSONの三角形範囲

想定する出力:

- `regionId`
- `regionLabel`
- `surface`
- `surfaceLabel`
- `confidence`

表示名や色は `shared/brain-regions.json` を正とします。Swift側に日本語ラベルを重複して埋め込むのは避け、将来は共有JSONを読み込むか、ビルド時に生成する方針です。

## 楕円体判定との切り替え

当面は楕円体判定を維持します。将来的に以下のような切り替えを想定します。

- `ellipsoid`: 現在の安定デバッグ用
- `mesh`: STL / OBJモデルによる本番候補
- `hybrid`: メッシュ判定が失敗したときだけ楕円体へフォールバック

iPhone側には、この切り替えに備えて以下のインターフェースだけを追加します。

- `BrainSurfaceModel`
- `NearestSurfaceHit`
- `BrainRegionResolver`

これらは契約だけであり、STL / OBJの読み込みはまだ行いません。

## TODO

- OBJ group / material と `regionId` の対応仕様を決める
- STLを使う場合の外部ラベルJSON仕様を決める
- brain model space の軸方向を展示模型に合わせて確定する
- 回転を含むキャリブレーションUIを追加する
- メッシュ軽量化と空間インデックス方式を検証する
- `shared/brain-regions.json` をiPhone側で参照する方法を決める
