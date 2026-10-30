import AppKit
import EpocharyKit
import SwiftUI

/// The licenses of the command-line tools bundled in the app.
struct AcknowledgementsView: View {
    private static let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
    private static let releases = URL(string: "https://github.com/washchuk/Epochary/releases")!

    private var notices: String? {
        Self.licenses.flatMap { try? String(contentsOf: $0.appendingPathComponent("THIRD-PARTY-NOTICES.txt"),
                                            encoding: .utf8) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
    }
}
