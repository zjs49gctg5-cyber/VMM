import XCTest
@testable import VMM

final class DiagnosticLocalizationTests:XCTestCase {
    func testEnglishDiagnosticsRetainUserNamesAndCodes() {
        XCTAssertEqual(VMMLocalization.text("プロジェクト設定が不正です。",language:.english),"Invalid project settings.")
        XCTAssertEqual(VMMLocalization.text("素材「字幕 $1.png」が見つかりません。",language:.english),"Media “字幕 $1.png” is missing.")
        XCTAssertEqual(VMMLocalization.text("AivisSpeech：音声エンジンに接続できません（-1004）。",language:.english),"AivisSpeech: Cannot connect to the speech engine (-1004).")
        XCTAssertEqual(VMMLocalization.text("VOICEVOX：HTTP 500\n音声クエリを読み込めませんでした。",language:.english),"VOICEVOX：HTTP 500\nCould not read the speech query.")
        XCTAssertEqual(VMMLocalization.text("Style-BERT-VITS2を起動してから、再接続してください。\n接続先：http://127.0.0.1:5000\n接続先はmacOSのAirPlayです。音声エンジンを別ポートで起動し、接続先URLを変更してください。",language:.english),"Start Style-BERT-VITS2, then reconnect.\nEndpoint: http://127.0.0.1:5000\nThe endpoint is macOS AirPlay. Start the speech engine on another port and change its URL.")
        XCTAssertEqual(VMMLocalization.text("接続先はmacOSのAirPlayです。音声エンジンを別ポートで起動し、接続先URLを変更してください。",language:.japanese),"接続先はmacOSのAirPlayです。音声エンジンを別ポートで起動し、接続先URLを変更してください。")
    }
    @MainActor func testAPIUsesEnglishDiagnosticsWithoutChangingStoredUserText()throws {
        let s=EditorStore(preferencesDirectory:FileManager.default.temporaryDirectory.appendingPathComponent("vmm-language-\(UUID())")),api=EditorCommands();api.store=s
        defer{VMMLocalization.language = .japanese;try? FileManager.default.removeItem(at:s.directory)}
        VMMLocalization.language = .english
        let result=api.execute(body:Data("{\"command\":\"clip.update\",\"clipID\":\"invalid\"}".utf8))
        let data=try XCTUnwrap(JSONSerialization.jsonObject(with:result.body) as? [String:Any]);XCTAssertEqual(data["error"] as? String,"Specify a valid clipID.")
    }
}
