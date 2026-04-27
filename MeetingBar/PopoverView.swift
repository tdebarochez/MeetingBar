import SwiftUI
import EventKit

struct PopoverView: View {
    @ObservedObject var calendarService: CalendarService
    let onJoin: (URL) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Refresh") { calendarService.refresh() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Quit") { onQuit() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private var content: some View {
        switch calendarService.authorizationStatus {
        case .notDetermined:
            Text("Requesting calendar access…")
                .foregroundStyle(.secondary)

        case .denied, .restricted, .writeOnly:
            VStack(alignment: .leading, spacing: 8) {
                Label("Calendar access needed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Enable access in System Settings → Privacy & Security → Calendars, then quit and reopen MeetingBar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

        case .fullAccess:
            if let meeting = calendarService.nextMeeting {
                meetingView(meeting)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("All clear", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text("No more meetings with a video link today.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        @unknown default:
            Text("Unknown calendar authorization state.")
        }
    }

    private func meetingView(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(timeString(meeting))
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button(action: { onJoin(meeting.joinURL) }) {
                HStack {
                    Image(systemName: iconName(for: meeting.provider))
                    Text("Join \(meeting.provider.rawValue)")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if !meeting.attendees.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Attendees", systemImage: "person.2")
                        .font(.callout.bold())
                    ForEach(meeting.attendees, id: \.name) { attendee in
                        AttendeeRow(attendee: attendee, statusIcon: statusIcon(attendee.status), statusColor: statusColor(attendee.status))
                    }
                }
            }

            if let notes = meeting.notes, !notes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Notes", systemImage: "note.text")
                        .font(.callout.bold())
                    ScrollView {
                        Text(notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

        }
    }

    private func statusIcon(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        case .pending: return "clock.circle"
        default: return "circle"
        }
    }

    private func statusColor(_ status: EKParticipantStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .pending: return .secondary
        default: return .secondary
        }
    }

    private func iconName(for provider: Meeting.VideoProvider) -> String {
        switch provider {
        case .meet: return "video.fill"
        case .zoom: return "video.circle.fill"
        case .teams: return "person.2.fill"
        case .other: return "link"
        }
    }

    private func timeString(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let start = formatter.string(from: meeting.startDate)
        let end = formatter.string(from: meeting.endDate)

        let seconds = Int(meeting.startDate.timeIntervalSinceNow)
        let relative: String
        if seconds <= 0 {
            relative = "in progress"
        } else if seconds < 60 {
            relative = "in \(seconds)s"
        } else if seconds < 3600 {
            relative = "in \(seconds / 60)m"
        } else {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            relative = m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
        }
        return "\(start) – \(end)  ·  \(relative)"
    }
}

private struct AttendeeRow: View {
    let attendee: Meeting.Attendee
    let statusIcon: String
    let statusColor: Color

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(attendee.name)
            if attendee.isCurrentUser {
                Text("(you)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHovered, let email = attendee.email {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopied = false
                    }
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(showCopied ? "Copied!" : email)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
