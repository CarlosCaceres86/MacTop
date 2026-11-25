import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testSpanishTranslationsCoverMenuOverlayAlertsAndLiveStatus() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources", isDirectory: true)
        let spanish = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("es.lproj", isDirectory: true)))

        let display = "Studio Display"
        let window = 2
        let total = 4
        XCTAssertEqual(String(localized: "Save Layout for \(display)…", bundle: spanish), "Guardar distribución para Studio Display…")
        XCTAssertEqual(String(localized: "Recovering desktops", bundle: spanish), "Recuperando escritorios")
        XCTAssertEqual(String(localized: "Placing windows", bundle: spanish), "Colocando ventanas")
        XCTAssertEqual(String(localized: "Verifying layout", bundle: spanish), "Comprobando la distribución")
        XCTAssertEqual(String(localized: "Cancel", bundle: spanish), "Cancelar")
        XCTAssertEqual(String(localized: "Restoring window \(window) of \(total)…", bundle: spanish), "Restaurando la ventana 2 de 4…")
        XCTAssertEqual(
            spanish.localizedString(forKey: "NSAccessibilityUsageDescription", value: nil, table: "InfoPlist"),
            "MacTop usa Accesibilidad para devolver las ventanas abiertas a sus escritorios guardados."
        )
    }
}
