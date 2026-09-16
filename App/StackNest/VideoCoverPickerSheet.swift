// SPDX-License-Identifier: MIT
import AVKit
import SwiftUI
import AppCore

/// G50: 動画の表紙にする場面を選ぶシート。
/// 標準のプレイヤー（シークバー付き）で頭出しし、その時刻を呼び出し側へ返す。
/// 実際のフレーム抽出と保存は `AppState.setVideoSceneCover` が行う。
///
/// G54-S4: 場面を選んだだけで終わっていたのを、続けてクロップまで決められる 2 段構えにした。
/// - 段階 1（`.scene`）: 従来どおりプレイヤーで頭出しする。
/// - 段階 2（`.crop`）: 選んだ秒数のフレームをプレビュー用に取り出し `CoverCropPicker` で切り抜きを決める。
///   ここで作るプレビューは UI 表示専用（低優先度のプレビュー）で、実際に表紙として保存するフレームは
///   `AppState.setVideoSceneCover` が同じ秒数で改めて取り出す（二重抽出だが責務は分けたまま）。
/// `onPicked` は秒数に加えてクロップ矩形（切り抜かなかったら `nil`）を返す。
struct VideoCoverPickerSheet: View {
    let url: URL
    let onPicked: (Double, CGRect?) -> Void
    let onCancel: () -> Void

    /// crop 未編集（全体）を表す正規化矩形。`CoverPickerSheet` と同じ規約
    /// （全体のままなら `nil` を渡して DB には NULL で書く）。
    private static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private enum Stage {
        case scene
        case crop
    }

    @State private var player: AVPlayer
    @State private var stage: Stage = .scene
    /// crop 段階へ進む際に確定した秒数。「戻る」で scene に戻っても保持し、
    /// crop 段階から確定するときはこの値を使う。
    @State private var pickedSeconds: Double?
    /// crop 編集用プレビュー（表示専用。保存フレームは AppState 側で別途取り直す）。
    @State private var previewImage: NSImage?
    @State private var cropRect: CGRect = VideoCoverPickerSheet.fullRect
    @State private var cropWidthSlider: Double = 1.0
    @State private var cropHeightSlider: Double = 1.0
    /// フレーム抽出中（scene 段階で進行表示・二重押下防止に使う）。
    @State private var isExtracting = false
    /// 抽出失敗時のメッセージ。非 nil の間は scene 段階に留まる。
    @State private var extractError: String?

    init(url: URL, onPicked: @escaping (Double, CGRect?) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onPicked = onPicked
        self.onCancel = onCancel
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 12) {
            switch stage {
            case .scene:
                sceneStage
            case .crop:
                cropStage
            }
        }
        .padding(16)
        // G54-S4 fixup（レビュー指摘 3）: crop 段階は VideoPlayer の暗黙の幅（640）を失うため、
        // 段階を切り替えるとシートが縮む。両段階を通して最小幅を固定する。
        .frame(minWidth: 640)
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private var sceneStage: some View {
        Text("表紙にする場面を選んでください")
            .font(.headline)
        VideoPlayer(player: player)
            .frame(minWidth: 640, minHeight: 360)
        if let extractError {
            Text(extractError)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        HStack {
            Text("再生・シークして、使いたい場面で止めてください")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("キャンセル") {
                player.pause()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            // G54-S4 fixup（レビュー指摘 4）: 抽出中でもキャンセルだけは押せるようにする
            // （長い動画で待たされている間、シートを閉じる手段が無くなるのを防ぐ）。
            Button {
                beginCrop()
            } label: {
                if isExtracting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("この場面を表紙にする")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isExtracting)
        }
    }

    @ViewBuilder
    private var cropStage: some View {
        Text("切り抜く範囲を選んでください（任意）")
            .font(.headline)
        if let previewImage {
            VStack(spacing: 8) {
                CoverCropPicker(image: previewImage, normalizedRect: $cropRect)
                    .frame(height: 280)
                HStack {
                    Text("幅")
                    Slider(value: $cropWidthSlider, in: 0.1...1.0)
                        .onChange(of: cropWidthSlider) { _, newValue in
                            var r = cropRect
                            r.size.width = newValue
                            r.origin.x = min(r.origin.x, 1 - newValue)
                            cropRect = r
                        }
                }
                HStack {
                    Text("高さ")
                    Slider(value: $cropHeightSlider, in: 0.1...1.0)
                        .onChange(of: cropHeightSlider) { _, newValue in
                            var r = cropRect
                            r.size.height = newValue
                            r.origin.y = min(r.origin.y, 1 - newValue)
                            cropRect = r
                        }
                }
                HStack {
                    Button("リセット (全体)") {
                        cropRect = Self.fullRect
                        cropWidthSlider = 1
                        cropHeightSlider = 1
                    }
                    Spacer()
                }
            }
        } else {
            // 到達しないはずだが（crop 段階は previewImage が取れてからしか遷移しない）、
            // 念のためのフォールバック表示。
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        HStack {
            // G54-S4 fixup（レビュー指摘 2）: crop 段階に .cancelAction が無いと Esc でシートを
            // 閉じられない（「戻る」→「キャンセル」の 2 手が要る）。crop 段階にも直接キャンセルを置く。
            Button("キャンセル") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("戻る") {
                stage = .scene
            }
            Spacer()
            Button("切り抜かずに決定") {
                finish(cropRect: nil)
            }
            Button("この切り抜きで決定") {
                let toSave: CGRect? = (cropRect == Self.fullRect) ? nil : cropRect
                finish(cropRect: toSave)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// scene 段階の「この場面を表紙にする」。フレームを抽出できたら crop 段階へ進む。
    /// 失敗（動画が読めない等）したら crop へは進まず、scene 段階のままエラーを出す。
    private func beginCrop() {
        player.pause()
        let seconds = player.currentTime().seconds
        isExtracting = true
        extractError = nil
        Task {
            do {
                let data = try await VideoFrameExtractor.frameData(url: url, seconds: seconds, maxPixelSize: 1200)
                guard let image = NSImage(data: data) else {
                    await MainActor.run {
                        isExtracting = false
                        extractError = "この場面のプレビューを作れませんでした。場面を選び直してください"
                    }
                    return
                }
                await MainActor.run {
                    pickedSeconds = seconds
                    previewImage = image
                    cropRect = Self.fullRect
                    cropWidthSlider = 1
                    cropHeightSlider = 1
                    isExtracting = false
                    stage = .crop
                }
            } catch {
                await MainActor.run {
                    isExtracting = false
                    extractError = "この場面のフレームを取り出せませんでした。場面を選び直してください"
                }
            }
        }
    }

    private func finish(cropRect: CGRect?) {
        guard let seconds = pickedSeconds else { return }
        onPicked(seconds, cropRect)
    }
}
