import SwiftUI

let navoBrandGradient = LinearGradient(
    colors: [Color(red: 0.55, green: 0.40, blue: 1.0), Color(red: 0.20, green: 0.72, blue: 1.0)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

struct HubView: View {
    @EnvironmentObject private var router: HubRouter

    var body: some View {
        NavigationSplitView {
            List(selection: $router.section) {
                Section {
                    ForEach(HubSection.allCases) { section in
                        Label(section.title, systemImage: section.icon)
                            .tag(section)
                    }
                } header: {
                    BrandHeader()
                        .padding(.bottom, 8)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                EngineStatusChip()
                    .padding(12)
            }
        } detail: {
            Group {
                switch router.section ?? .home {
                case .home:
                    HomeView()
                case .record:
                    RecordView()
                case .files:
                    FilesView()
                case .clipboard:
                    ClipboardView()
                case .dictionary:
                    DictionaryView()
                case .settings:
                    SettingsView()
                }
            }
            // A page gets the space the window gives it. What does not fit is cut off at the
            // edge (pages scroll their long parts) instead of forcing the layout out of shape,
            // which left the sidebar and lists blank.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        // The window's size never depends on the page it shows: it can always be resized down
        // to its minimum and opens at the size it was left at.
        .frame(
            minWidth: HubView.minimumSize.width,
            idealWidth: HubView.minimumSize.width,
            maxWidth: .infinity,
            minHeight: HubView.minimumSize.height,
            idealHeight: HubView.minimumSize.height,
            maxHeight: .infinity
        )
    }

    static let minimumSize = CGSize(width: 900, height: 560)
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(navoBrandGradient)
            Text("Navo")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
        }
        .padding(.top, 6)
    }
}

struct EngineStatusChip: View {
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var router: HubRouter
    @EnvironmentObject private var settings: AppSettings

    private var color: Color {
        switch engine.state {
        case .ready: return .green
        case .sleeping: return .blue
        case .failed: return .red
        case .notInstalled: return .gray
        default: return .orange
        }
    }

    private var subtitle: String {
        let name = settings.dictationEngine.shortName
        guard engine.state.canDictate, let memory = engine.details?.memoryBytes else { return "\(name), \(engine.state.label)" }
        return "\(name), \(engine.state.label), \(ProcessMemory.format(memory))"
    }

    var body: some View {
        Button {
            router.section = .settings
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local engine")
                        .font(.system(size: 11, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
