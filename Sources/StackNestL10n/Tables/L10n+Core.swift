// SPDX-License-Identifier: MIT

extension L10nTable {
    /// AppCore・LibraryStore・アダプタ・サーバの文言（G55 U6）。
    /// UI に出ない値（パーサの字句・保存値）は各ソースファイル側で許可リスト／`l10n:ignore` にする。
    static let core: [String: L10nEntry] = [
        // MARK: - AppCore/AppError.swift
        "ライブラリ DB を開けませんでした: %@": L10nEntry("Couldn't open the library database: %@"),
        "取り込みに失敗しました: %@": L10nEntry("Import failed: %@"),
        "\"%@\"を開けませんでした: %@": L10nEntry("Couldn't open \"%@\": %@"),
        "タイトルは必須項目です": L10nEntry("Title is required"),
        "予期しないエラー: %@": L10nEntry("Unexpected error: %@"),

        // MARK: - AppCore/BookCategory.swift
        "アーカイブ": L10nEntry("Archive"),
        "画像": L10nEntry("Image"),
        "フォルダ": L10nEntry("Folder"),
        "動画": L10nEntry("Video"),
        "テキスト": L10nEntry("Text"),
        "(ディレクトリ書籍)": L10nEntry("(directory book)"),

        // MARK: - AppCore/BookColumn.swift, LibrarySettings.swift, StampField.swift (shared field labels)
        "タイトル": L10nEntry("Title"),
        "レート": L10nEntry("Rating"),
        "作者": L10nEntry("Author"),
        "ジャンル": L10nEntry("Genre"),
        "登録日": L10nEntry("Date Added"),
        "読んだ日": L10nEntry("Date Read"),
        "未読": L10nEntry("Unread"),
        "種類": L10nEntry("Type"),
        "関連": L10nEntry("Related"),
        "キーワード A": L10nEntry("Keyword A"),
        "キーワード B": L10nEntry("Keyword B"),
        "キーワード C": L10nEntry("Keyword C"),
        "メモ": L10nEntry("Memo"),
        "シリーズ": L10nEntry("Series"),
        "巻数": L10nEntry("Volume"),

        // MARK: - AppCore/BookContent.swift
        "⚠ このファイルは破損しています。%lld ページまで読み込みました":
            L10nEntry(one: "⚠ This file is damaged. Loaded up to %lld page", other: "⚠ This file is damaged. Loaded up to %lld pages"),

        // MARK: - AppCore/BookRenameExecutor.swift
        "手動確認が必要: ファイルが %@ のまま残っている可能性があります（%@）":
            L10nEntry("Manual check needed: the file may still be at %@ (%@)"),

        // MARK: - AppCore/EPUBProgressDisplay.swift
        "計測中…": L10nEntry("Measuring…"),

        // MARK: - AppCore/FilenameFormat.swift (BookTypeLabel.displayLabel only; canonical @type values stay Japanese; glossary §6)
        "厚い本": L10nEntry("Thick Book"),
        "薄い本": L10nEntry("Thin Book"),
        "本の一部": L10nEntry("Part of Book"),
        "画像セット": L10nEntry("Image Set"),
        "ムービー": L10nEntry("Movie"),

        // MARK: - AppCore/FilenameFormatPreset.swift (display only; stored seed name stays "既定")
        "既定": L10nEntry("Default"),

        // MARK: - AppCore/GrantStore.swift (display only; stored seed labels stay Japanese)
        "(既定) 閲覧": L10nEntry("(Default) View"),
        "(既定) 編集": L10nEntry("(Default) Edit"),

        // MARK: - StackNestL10n/L10nSeed.swift (display only; the favorites shelf's stored name stays "お気に入り")
        "お気に入り": L10nEntry("Favorites"),

        // MARK: - AppCore/GrantManagementLogic.swift
        "全ライブラリ": L10nEntry("All Libraries"),
        "%lld 庫": L10nEntry(one: "%lld Library", other: "%lld Libraries"),

        // MARK: - AppCore/HelperLauncher.swift
        "書籍にパスが設定されていません。": L10nEntry("The book has no path set."),
        "ファイルが見つかりません。": L10nEntry("The file could not be found."),
        "電子書籍": L10nEntry("E-Book"),
        "%@ 用の外部ビューアが未設定です。設定 (⌘,) で選択してください。":
            L10nEntry("No external viewer is set for %@. Choose one in Settings (⌘,)."),
        "外部ビューアが見つかりません: %@\n設定 (⌘,) で再選択してください。":
            L10nEntry("The external viewer could not be found: %@\nChoose one again in Settings (⌘,)."),

        // MARK: - AppCore/LibraryOpenError.swift
        "このライブラリは読み取り専用のため開けません。Finder の「ロック」を解除するか、書き込み可能な場所にコピーしてからお試しください。":
            L10nEntry("This library is read-only and can't be opened. Unlock it in Finder, or copy it to a writable location and try again."),
        "データベースが破損しています。": L10nEntry("The database is corrupted."),
        "操作はキャンセルされました。": L10nEntry("The operation was cancelled."),

        // MARK: - AppCore/LoupeOptions.swift
        "円": L10nEntry("Circle"),
        "正方形": L10nEntry("Square"),
        "小": L10nEntry("Small"),
        "中": L10nEntry("Medium"),
        "大": L10nEntry("Large"),

        // MARK: - AppCore/OfflineStore.swift
        "不正な libraryUUID です": L10nEntry("Invalid libraryUUID."),
        "不正なファイル拡張子です": L10nEntry("Invalid file extension."),

        // MARK: - AppCore/ServerStartError.swift
        "ポート %lld は使用中です。別のアプリ/サービスが使用している可能性があります。ポート番号を変更するか「ランダム」を押して再起動してください。":
            L10nEntry("Port %lld is already in use. Another app or service may be using it. Change the port number or click \u{201C}Random\u{201D} and restart."),

        // MARK: - AppCore/UndoableCommand.swift
        "%lld 件のライブラリから削除": L10nEntry(one: "Remove %lld Item from Library", other: "Remove %lld Items from Library"),
        "%lld 件のメタデータ編集": L10nEntry(one: "Edit Metadata for %lld Item", other: "Edit Metadata for %lld Items"),

        // MARK: - AppCore/ViewerActionDisplay.swift
        "ページ送り": L10nEntry("Next Page"),
        "ページ戻し": L10nEntry("Previous Page"),
        "左方向へ": L10nEntry("Move Left"),
        "右方向へ": L10nEntry("Move Right"),
        "先頭ページ": L10nEntry("First Page"),
        "末尾ページ": L10nEntry("Last Page"),
        "ズームイン": L10nEntry("Zoom In"),
        "ズームアウト": L10nEntry("Zoom Out"),
        "ウィンドウに合わせる": L10nEntry("Fit to Window"),
        "全画面 切替": L10nEntry("Toggle Full Screen"),
        "閉じる": L10nEntry("Close"),
        "見開き 切替": L10nEntry("Toggle Two-Page Spread"),
        "表紙オフセット 切替": L10nEntry("Toggle Cover Offset"),
        "スライドショー 開始/停止": L10nEntry("Start/Stop Slideshow"),
        "横長レイアウト 巡回": L10nEntry("Cycle Landscape Layout"),
        "次の巻": L10nEntry("Next Volume"),
        "前の巻": L10nEntry("Previous Volume"),
        "巻末挙動 切替": L10nEntry("Cycle End-of-Volume Behavior"),
        "ヘルプ表示": L10nEntry("Show Help"),
        "位置ジャンプ 0%": L10nEntry("Jump to 0%"),
        "位置ジャンプ 10%": L10nEntry("Jump to 10%"),
        "位置ジャンプ 20%": L10nEntry("Jump to 20%"),
        "位置ジャンプ 30%": L10nEntry("Jump to 30%"),
        "位置ジャンプ 40%": L10nEntry("Jump to 40%"),
        "位置ジャンプ 50%": L10nEntry("Jump to 50%"),
        "位置ジャンプ 60%": L10nEntry("Jump to 60%"),
        "位置ジャンプ 70%": L10nEntry("Jump to 70%"),
        "位置ジャンプ 80%": L10nEntry("Jump to 80%"),
        "位置ジャンプ 90%": L10nEntry("Jump to 90%"),
        "ページスキップ（進む）": L10nEntry("Skip Pages (Forward)"),
        "ページスキップ（戻る）": L10nEntry("Skip Pages (Backward)"),
        "ページ方向 切替（この本）": L10nEntry("Toggle Page Direction (This Book)"),
        "ルーペ": L10nEntry("Magnifier"),
        "ナビゲーション": L10nEntry("Navigation"),
        "ズーム": L10nEntry("Zoom"),
        "見開き・スライドショー": L10nEntry("Spread & Slideshow"),
        "巻移動": L10nEntry("Volume Navigation"),
        "その他": L10nEntry("Other"),

        // MARK: - AppCore/VolumeHandover.swift
        "次の巻を開けません": L10nEntry("Can't open the next volume"),
        "前の巻を開けません": L10nEntry("Can't open the previous volume"),
        "次の巻を開けません（ファイルが見つかりません）": L10nEntry("Can't open the next volume (file not found)"),
        "前の巻を開けません（ファイルが見つかりません）": L10nEntry("Can't open the previous volume (file not found)"),

        // MARK: - ArchiveAdapter/LibarchiveVersion.swift
        "libarchive のヘッダ（%lld）と実行時ライブラリ（%lld）の版が違います。\n次を実行してヘッダを取得し直してください:\n  ./Scripts/fetch-libarchive-headers.sh":
            L10nEntry("The libarchive header (%lld) and the runtime library (%lld) are different versions.\nRun this to re-fetch the headers:\n  ./Scripts/fetch-libarchive-headers.sh"),

        // MARK: - EPUBAdapter/EPUBAdapterError.swift
        "EPUB を開けません: %@": L10nEntry("Couldn't open the EPUB: %@"),

        // MARK: - LibraryServer/LibraryServerCore.swift
        "mode は unchecked/all/damaged のいずれかです（受信: %@）":
            L10nEntry("mode must be one of unchecked/all/damaged (received: %@)"),
        "監視フォルダのパスが無効です: %@": L10nEntry("The watched folder path is invalid: %@"),
        "各プリセットに format が必要です": L10nEntry("Each preset requires a format."),
        "プリセットは最低 1 個必要です": L10nEntry("At least one preset is required."),
        "本の実ファイルが見つかりません": L10nEntry("The book's file could not be found."),
        "この形式（.%@）は表紙を自動生成できません": L10nEntry("This format (.%@) doesn't support automatic cover generation."),
        "この本には表紙画像がありません": L10nEntry("This book has no cover image."),
    ]
}
