import AppKit
import EpocharyKit
import SwiftUI

/// Epochary's own license notice, then the licenses of the command-line tools bundled in the app.
struct AcknowledgementsView: View {
    private static let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
    private static let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
    private static let repository = URL(string: "https://github.com/washchuk/Epochary")!
    private static let releases = URL(string: "https://github.com/washchuk/Epochary/releases")!

    @State private var isShowingLicense = false

    private var notices: String? {
        Self.licenses.flatMap { try? String(contentsOf: $0.appendingPathComponent("THIRD-PARTY-NOTICES.txt"),
                                            encoding: .utf8) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Epochary is copyright © 2026 Matt Washchuk. It's free software: you can redistribute it "
                     + "and modify it under the GNU General Public License, version 3 or any later version. "
                     + "It comes with no warranty.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show License") { isShowingLicense = true }
                        .disabled(Self.license == nil)
                    Link("Source Code", destination: Self.repository)
                    Spacer()
                }
            }
            Divider()
            if let notices {
                ScrollView {
                    Text(notices)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Show License Files") {
                        if let licenses = Self.licenses { NSWorkspace.shared.open(licenses) }
                    }
                    Link("Source Code for Each Release", destination: Self.releases)
                    Spacer()
                }
            } else {
                Text("This copy of Epochary doesn't include its own command-line tools. It uses the copies "
                     + "installed on this Mac, which come with their own licenses.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $isShowingLicense) { LicenseSheet(url: Self.license) }
    }
}

/// The full GPL text. LICENSE has no file extension, so it's shown here rather than opened in another app.
private struct LicenseSheet: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 520)
    }
}
