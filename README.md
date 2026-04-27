# MeetingBar

A minimal macOS menu bar app that shows a countdown to your next meeting and pops up a "Join" button 2 minutes before it starts.

## Features

- Menu bar countdown: `+2h`, `42m`, `45s`, `now`, `-12m` (time left until meeting ends)
- Calendar icon in the menu bar when no meetings are scheduled
- Reads meetings from the macOS Calendar app (EventKit), so iCloud / Google Calendar / Exchange all work via macOS's Internet Accounts
- Only counts meetings you've **accepted** (or organized)
- Only counts meetings that have a **video link** (Google Meet / Zoom / Teams)
- Auto-popover below the icon 2 minutes before start, with a Join button
- Popover shows **attendees** with acceptance status (accepted, declined, tentative, pending) — hover to copy email addresses
- Popover shows **meeting notes** (scrollable, selectable text) with Google Calendar boilerplate auto-stripped
- One click → opens the Meet/Zoom/Teams URL in your browser
- Zero dependencies, ~2 MB build

## Requirements

- macOS 14 (Sonoma) or later — required for the modern EventKit API
- Xcode 15+
- Your meetings must be accessible via the built-in Calendar app. To add Google Calendar: System Settings → Internet Accounts → Google.

## Build & run

```bash
open MeetingBar.xcodeproj
```

In Xcode:

1. Select the **MeetingBar** target → **Signing & Capabilities** tab
2. Under **Team**, pick your Apple ID (or "None" for unsigned local builds). If you have no Apple ID configured, go to Xcode → Settings → Accounts → `+` → Apple ID.
3. Change **Bundle Identifier** from `com.thomas.MeetingBar` to something unique to you (e.g. `com.yourname.MeetingBar`)
4. `Cmd+R` to build & run

On first launch, macOS will ask for Calendar access. Grant it. The menu bar icon should appear in the top-right within a second or two.

## How the meeting detection works

For each event today that hasn't ended yet:

1. **Accepted filter**: you're the organizer, OR your `participantStatus` is `.accepted`, OR the event has no attendee list (personal events).
2. **Video link extraction**: looks at `event.url`, `event.location`, and `event.notes` in that order, matching:
   - `https://meet.google.com/xxx-xxxx-xxx`
   - `https://*.zoom.us/j/123...` and `/my/...`
   - `https://teams.microsoft.com/l/meetup-join/...`
3. **Next meeting**: the candidate with the earliest `startDate`.

The list refreshes automatically when EventKit posts `EKEventStoreChanged` (someone accepts/declines/reschedules an event in Calendar.app) and every 30 seconds as a backstop.

## Customization pointers

- **Change the 2-minute popover window** → `StatusBarController.checkAutoPopover()`, the `secondsUntilStart <= 120` check
- **Add more providers** → `CalendarService.findVideoURL`, add a regex + case to `Meeting.VideoProvider`
- **Change the countdown format** → `StatusBarController.countdownString(meeting:)`
- **Launch at login** → use `SMAppService.mainApp.register()` from `ServiceManagement` (one-line API on macOS 13+)
- **Notifications instead of popover** → swap `showPopover()` for a `UNUserNotificationCenter` request in `checkAutoPopover()`

## Why not Tauri?

Short version: for a menu bar utility, native wins on bundle size (~2 MB vs ~20 MB), battery (no idle WebView process), and popover positioning (trivial with `NSPopover`, painful with Tauri). All the hard parts would still require calling EventKit from Rust via `objc2`, which is more friction than just using Swift.

## Troubleshooting

- **Icon doesn't appear**: the app is running in accessory mode with no Dock icon. Check Activity Monitor for `MeetingBar`. If it crashed, look in Console.app filtered by `MeetingBar`.
- **"Calendar access needed" stuck**: the Info.plist might not have been embedded. Verify in Xcode: target → Build Phases → the Info.plist setting points to `MeetingBar/Info.plist` and `GENERATE_INFOPLIST_FILE` is `NO`. Re-grant access via System Settings → Privacy & Security → Calendars.
- **No meetings shown but you have some**: either your Google account isn't synced in Calendar.app, your response status isn't `Accepted` on the events, or the events don't have a video link we recognize. Open Calendar.app and double-check.
