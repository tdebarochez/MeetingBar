import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem (menu bar icon + title) and the NSPopover
/// that appears below it with the "Join now" CTA.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let calendarService: CalendarService

    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // True once we've shown the pre-meeting popover for the current
    // meeting. Reset when the meeting changes. Prevents the popover
    // from re-showing every single second during the 2-minute window.
    private var hasShownJoinPopover = false
    private var lastPopoverMeetingID: String?

    init() {
        self.calendarService = CalendarService()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient // dismisses on click outside
        self.popover.animates = true

        setupButton()
        observeCalendarChanges()
        startTicking()

        // Kick off permission request on first launch.
        Task {
            await calendarService.requestAccess()
        }
    }

    // MARK: - Button

    private func setupButton() {
        guard let button = statusItem.button else { return }
        // SF Symbol gives us a crisp template-rendered icon that adapts
        // to light/dark menu bars automatically.
        button.image = NSImage(
            systemSymbolName: "calendar",
            accessibilityDescription: "Next meeting"
        )
        button.imagePosition = .imageLeft
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Observation

    private func observeCalendarChanges() {
        // When the "next meeting" pointer changes, reset our popover flag
        // so we'll show the join prompt for the new meeting when it's close.
        calendarService.$nextMeeting
            .sink { [weak self] meeting in
                guard let self else { return }
                if meeting?.id != self.lastPopoverMeetingID {
                    self.hasShownJoinPopover = false
                    self.lastPopoverMeetingID = meeting?.id
                }
                self.updateStatusItemTitle()
            }
            .store(in: &cancellables)

        calendarService.$authorizationStatus
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)
    }

    // MARK: - Ticking

    /// One timer at 1Hz drives both the countdown label and the
    /// "2 minutes before start" popover trigger. Simpler than two timers.
    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemTitle()
                self?.checkAutoPopover()
            }
        }
        RunLoop.current.add(tickTimer!, forMode: .common)
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }

        switch calendarService.authorizationStatus {
        case .notDetermined:
            button.title = "  …"
            return
        case .denied, .restricted, .writeOnly:
            button.title = "  ⚠︎"
            return
        case .fullAccess:
            break
        @unknown default:
            button.title = "  ?"
            return
        }

        guard let meeting = calendarService.nextMeeting else {
            button.image = NSImage(
                systemSymbolName: "calendar",
                accessibilityDescription: "No meetings"
            )
            button.title = ""
            return
        }

        button.image = nil
        button.title = countdownString(meeting: meeting)
    }

    /// "+2h" / "42m" / "45s" / "now" / "-12m"
    private func countdownString(meeting: Meeting) -> String {
        let secondsToStart = Int(meeting.startDate.timeIntervalSinceNow)

        if secondsToStart > 0 {
            if secondsToStart < 60 {
                return "\(secondsToStart)s"
            }
            let minutes = secondsToStart / 60
            if minutes < 60 {
                return "\(minutes)m"
            }
            return "+\(minutes / 60)h"
        }

        let secondsToEnd = Int(meeting.endDate.timeIntervalSinceNow)
        if secondsToEnd <= 0 {
            return "now"
        }
        let minutesLeft = secondsToEnd / 60
        if minutesLeft < 60 {
            return "-\(minutesLeft)m"
        }
        return "-\(minutesLeft / 60)h"
    }

    // MARK: - Popover auto-trigger

    /// Shows the popover automatically when the meeting is ≤2 minutes away,
    /// exactly once per meeting. Won't interrupt if the popover is already open.
    private func checkAutoPopover() {
        guard let meeting = calendarService.nextMeeting else { return }
        guard !hasShownJoinPopover else { return }

        let secondsUntilStart = meeting.startDate.timeIntervalSinceNow
        // Window: from 2 minutes before start until the meeting actually starts.
        // If the user launched the app mid-meeting, we don't auto-popup;
        // they can click the icon themselves.
        if secondsUntilStart <= 120 && secondsUntilStart > 0 {
            hasShownJoinPopover = true
            showPopover()
        }
    }

    // MARK: - Popover show/hide

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        // Rebuild the content view each time so it reflects the current state.
        let content = PopoverView(
            calendarService: calendarService,
            onJoin: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.popover.performClose(nil)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: 320, height: 400)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Transient popovers dismiss on outside click, but we also want
        // the app to briefly activate so keyboard focus works inside.
        NSApp.activate(ignoringOtherApps: true)
    }
}
