import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  // How workspace ids map onto monitors, set with "mode" on this widget's entry
  // in ~/.config/omarchy/shell.json:
  //   "blocks" - each monitor owns its own block of workspacesPerMonitor ids
  //              (1-10, 11-20, ...), as ~/.config/hypr/workspaces.lua sets up.
  //              This bar's block is derived from the workspace its monitor is
  //              showing, and cells are labelled by slot within the block.
  //   "shared" - every monitor draws from the same 1..workspacesPerMonitor ids,
  //              as stock Omarchy does. This bar lists the ones on its own
  //              monitor under their real numbers.
  readonly property bool sharedMode: String(setting("mode", "blocks")) === "shared"
  readonly property int workspacesPerMonitor: Math.max(1, Number(setting("workspacesPerMonitor", 10)))
  readonly property int placeholderCount: Math.min(5, workspacesPerMonitor)

  // The bar window isn't attached yet when bindings first evaluate, so resolve
  // this widget's screen name once it is, the same way Bar.qml does.
  property string screenName: ""
  function resolveScreen() {
    var window = root.QsWindow ? root.QsWindow.window : null
    var name = window && window.screen ? String(window.screen.name || "") : ""
    if (name !== "") root.screenName = name
  }
  Timer {
    interval: 250
    repeat: true
    triggeredOnStart: true
    running: root.screenName === ""
    onTriggered: root.resolveScreen()
  }

  readonly property var monitor: {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === root.screenName) return values[i]
    }
    return null
  }
  readonly property int rangeMin: {
    if (sharedMode) return 1
    var active = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
    return Math.floor((Math.max(active, 1) - 1) / workspacesPerMonitor) * workspacesPerMonitor + 1
  }

  // Until the bar's monitor resolves, treat every workspace as this bar's.
  function onThisMonitor(workspace) {
    return !root.monitor || !workspace.monitor || workspace.monitor.name === root.monitor.name
  }

  function workspaceIds() {
    var ids = []
    for (var n = 0; n < root.placeholderCount; n++) {
      var placeholder = root.workspaceById(root.rangeMin + n)
      // A shared id already open on another monitor belongs to that monitor's bar.
      if (root.sharedMode && placeholder && !root.onThisMonitor(placeholder)) continue
      ids.push(root.rangeMin + n)
    }
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id < root.rangeMin || id >= root.rangeMin + root.workspacesPerMonitor || ids.indexOf(id) !== -1) continue
      if (root.sharedMode && !root.onThisMonitor(values[i])) continue
      ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    // A shared workspace that moved to another monitor since this bar last drew
    // is switched to where it is rather than pulled onto this monitor.
    var workspace = root.workspaceById(id)
    if (root.sharedMode && workspace && !root.onThisMonitor(workspace)) {
      root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
      return
    }
    // Focus this bar's monitor first so a not-yet-created workspace opens here.
    var focusMonitor = root.monitor
      ? "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + root.monitor.name + "\" })") + " && "
      : ""
    root.bar.run(focusMonitor + "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\", on_current_monitor = true })"))
  }

  // Window detail (pid, geometry, class) comes from this widget's own
  // `hyprctl -j clients` snapshot, never Hyprland.refreshToplevels(). Quickshell's
  // refresh only ever adds toplevels: when a window closes while that request is
  // in flight, the reply re-creates it after its closewindow event has already
  // removed it, and nothing removes it again. Asking for detail the moment each
  // window opened is exactly when short-lived windows close, so the bar collected
  // ghost icons. The snapshot is also the record of which windows really exist,
  // so ghosts left behind by anything else stay hidden too.
  property var clients: ({})
  property bool clientsLoaded: false
  property string clientsSignature: ""
  property bool clientsRefetch: false

  // Events that can add, remove, move or re-tile a window. Focus changes are in
  // because a swap or resize emits nothing of its own, but is usually followed by one.
  readonly property var clientEvents: ["openwindow", "closewindow", "movewindowv2", "changefloatingmode", "fullscreen", "activewindowv2", "configreloaded"]

  function fetchClients() {
    if (clientsProc.running) {
      root.clientsRefetch = true
      return
    }
    clientsProc.running = true
  }

  function applyClients(text) {
    var list
    try { list = JSON.parse(String(text || "")) } catch (e) { return }
    if (!Array.isArray(list)) return

    var map = {}
    var signature = []
    for (var i = 0; i < list.length; i++) {
      var client = list[i]
      // Quickshell's toplevel.address is bare lowercase hex; hyprctl prefixes 0x.
      var address = String(client.address || "").replace(/^0x/, "").toLowerCase()
      if (address === "") continue
      map[address] = client
      signature.push([address, client.pid, client.class, client.at, client.workspace ? client.workspace.id : "", client.fullscreen].join(":"))
    }

    root.clientsLoaded = true
    // Every new model array rebuilds the icon row, so only publish a snapshot
    // that changed something the row reads.
    var joined = signature.sort().join("|")
    if (joined === root.clientsSignature) return
    root.clientsSignature = joined
    root.clients = map
  }

  function clientFor(toplevel) {
    if (!toplevel || !toplevel.address) return null
    return root.clients[String(toplevel.address).toLowerCase()] || null
  }

  // Hyprland's fullscreen modes: 0 none, 1 maximized (SUPER+ALT+F "Full width"),
  // 2 fullscreen (SUPER+F). Only the maximized variant is flagged; true
  // fullscreen already hides the bar, so there'd be nothing to see.
  readonly property int maximizedMode: 1

  function workspaceMaximized(id) {
    for (var address in root.clients) {
      var client = root.clients[address]
      if (client.workspace && client.workspace.id === id && client.fullscreen === root.maximizedMode) return true
    }
    return false
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClients(text)
    }
    // An event that landed mid-request may describe a window this reply predates.
    onExited: {
      if (!root.clientsRefetch) return
      root.clientsRefetch = false
      clientsDebounce.restart()
    }
  }

  Timer {
    id: clientsDebounce
    interval: 50
    onTriggered: root.fetchClients()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && root.clientEvents.indexOf(String(event.name)) !== -1) clientsDebounce.restart()
    }
  }

  Component.onCompleted: root.fetchClients()

  // Hyprland hands a workspace's toplevels back in the order it happens to hold
  // them, which is creation order until a window is moved, swapped, or pulled in
  // from another workspace - after that the leftmost tile can be the last icon.
  // Sort by where each window actually sits instead, columns left to right and
  // top to bottom within a column, so the icon row reads in the same order as
  // the windows it stands for.
  function toplevelPosition(toplevel) {
    var client = root.clientFor(toplevel)
    var at = client ? client.at : null
    return (at && at.length === 2) ? at : [0, 0]
  }

  // Until the first snapshot lands every toplevel shows; after that, only the
  // ones Hyprland still reports.
  function orderedToplevels(list) {
    var sorted = (list || []).slice().filter(function(toplevel) {
      return !root.clientsLoaded || root.clientFor(toplevel) !== null
    })
    sorted.sort(function(left, right) {
      var a = root.toplevelPosition(left)
      var b = root.toplevelPosition(right)
      return a[0] !== b[0] ? a[0] - b[0] : a[1] - b[1]
    })
    return sorted
  }

  // Dot-separated class segments, lowercased (e.g. "md.Obsidian" -> ["md", "obsidian"]).
  function classSegments(value) {
    return String(value || "").toLowerCase().split(".").filter(function(s) { return s.length > 0 })
  }

  // True if `needle` appears as a contiguous, whole-segment run inside `haystack`.
  // Segment-based so "obs" doesn't match inside "md.obsidian.obsidian" the way a
  // raw substring check would (that's how OBS Studio's StartupWMClass, "obs",
  // used to get matched instead of Obsidian's).
  function segmentsContain(haystack, needle) {
    if (needle.length === 0 || needle.length > haystack.length) return false
    for (var start = 0; start <= haystack.length - needle.length; start++) {
      var match = true
      for (var j = 0; j < needle.length; j++) {
        if (haystack[start + j] !== needle[j]) { match = false; break }
      }
      if (match) return true
    }
    return false
  }

  // Omarchy webapps launch via `omarchy-launch-webapp <url>` (Chrome --app
  // mode), which has no StartupWMClass at all - Chrome instead generates a
  // class embedding the site's hostname (e.g. "chrome-discord.com__..." for
  // https://discord.com/...). Extract that hostname from the entry's Exec so
  // it can be matched against the live window class.
  function webappHostname(entry) {
    var exec = String(entry.execString || "")
    var execMatch = exec.match(/omarchy-launch-(?:or-focus-)?webapp\s+"?(https?:\/\/[^\s"]+)/)
    if (!execMatch) return ""
    var hostMatch = execMatch[1].match(/^https?:\/\/([^\/]+)/)
    if (!hostMatch) return ""
    return hostMatch[1].replace(/^www\./, "").toLowerCase()
  }

  // org.omarchy.agent is a fixed class every coding agent CLI shares (see
  // omarchy-agent), so there's no desktop entry to resolve an icon from.
  // Only Claude and Codex ship a dedicated mark in the agents bar panel's own
  // assets; any other/undetected agent falls back to Claude's, since it's
  // Omarchy's default.
  readonly property string agentIconsPath: "/usr/share/omarchy/shell/plugins/agents/assets/"
  readonly property var knownAgentBinaries: ["claude", "codex", "copilot", "crush", "grok", "omp", "pi"]

  function agentIconNameFor(binary) {
    return binary === "codex" ? "codex" : "claude"
  }

  // omarchy-launch-tui defaults an unlabeled command's class to
  // "org.omarchy.<binary>" (e.g. "org.omarchy.yazi" for `omarchy-launch-tui
  // yazi`) unless the caller passes its own --app-id, as omarchy-agent does.
  // That prefixed class never matches a real desktop entry or icon-theme
  // name, so strip it back to the bare binary name to look up instead.
  function tuiBinaryName(appId) {
    var match = /^org\.omarchy\.(.+)$/.exec(String(appId || ""))
    return match ? match[1] : ""
  }

  // Descend up to 5 levels of children from the window's PID looking for a
  // known agent binary (the window's own PID is usually the terminal
  // emulator's, with the agent CLI running as its child/grandchild), printing
  // "agent:<binary>" on a hit. Otherwise, for a plain terminal, print
  // "fg:<binary>" for the program in the foreground of its tty - the process
  // group the shell handed the terminal to - so any TUI can supply its icon.
  function windowProbeScript(pid, checkForeground) {
    var agentWalk = "frontier=" + pid + "; for d in 1 2 3 4 5; do "
      + "frontier=$(pgrep -P \"$frontier\" | tr '\\n' ',' | sed 's/,$//'); "
      + "[ -z \"$frontier\" ] && break; "
      + "for p in $(echo \"$frontier\" | tr ',' ' '); do "
      + "c=$(ps -o comm= -p \"$p\" 2>/dev/null); "
      + "case \"$c\" in " + root.knownAgentBinaries.join("|") + ") echo \"agent:$c\"; exit 0;; esac; "
      + "done; done"
    if (!checkForeground) return agentWalk
    // comm is capped at 15 characters, so names that long fall back to argv[0].
    return agentWalk + "; for p in $(pgrep -P " + pid + "); do "
      + "fg=$(ps -o tpgid= -p \"$p\" 2>/dev/null | tr -d ' '); "
      + "[ -n \"$fg\" ] && [ \"$fg\" -gt 0 ] || continue; "
      + "c=$(ps -o comm= -p \"$fg\" 2>/dev/null); "
      + "[ ${#c} -ge 15 ] && c=$(basename -- \"$(ps -o args= -p \"$fg\" | awk '{print $1}')\"); "
      + "[ -n \"$c\" ] && { echo \"fg:$c\"; exit 0; }; "
      + "done"
  }

  // A terminal is the one window whose class actively lies about what the user
  // is looking at: an agent CLI started from the shell keeps the emulator's own
  // class, so the cell shows a terminal for what is really a Claude session.
  // Probe these the same way org.omarchy.agent windows are probed, and let the
  // detected binary - not the class - pick the icon.
  readonly property var knownTerminalClasses: ["alacritty", "foot", "kitty", "ghostty", "wezterm"]

  // An idle terminal's foreground program is its shell, and some icon themes
  // ship a "bash" or "fish" icon that would otherwise replace the terminal's own.
  readonly property var knownShells: ["bash", "zsh", "fish", "sh", "dash", "nu", "ksh", "tcsh", "csh", "elvish", "xonsh"]

  function isTerminalClass(appId) {
    var segments = classSegments(appId)
    for (var i = 0; i < segments.length; i++) {
      if (root.knownTerminalClasses.indexOf(segments[i]) !== -1) return true
    }
    return false
  }

  // Match a running window back to the same desktop entry the app launcher
  // menu would show for it, so icons stay consistent with the launcher.
  function findDesktopEntry(appId) {
    if (!appId) return null

    var lower = appId.toLowerCase()
    var appSegments = classSegments(appId)
    var values = DesktopEntries.applications.values || []
    var i, entry, startupClass, hostname

    // 1. Exact StartupWMClass match.
    for (i = 0; i < values.length; i++) {
      startupClass = String(values[i].startupClass || "").toLowerCase()
      if (startupClass !== "" && startupClass === lower) return values[i]
    }

    // 2. StartupWMClass as a contiguous run of segments within the live app
    // id (e.g. Obsidian ships "md.Obsidian" but the live window reports
    // "md.obsidian.Obsidian").
    for (i = 0; i < values.length; i++) {
      startupClass = String(values[i].startupClass || "")
      if (startupClass === "") continue
      var startupSegments = classSegments(startupClass)
      if (segmentsContain(appSegments, startupSegments) || segmentsContain(startupSegments, appSegments))
        return values[i]
    }

    // 3. Omarchy webapp hostname match (Discord, WhatsApp, etc.).
    for (i = 0; i < values.length; i++) {
      hostname = webappHostname(values[i])
      if (hostname !== "" && lower.indexOf(hostname) !== -1) return values[i]
    }

    return DesktopEntries.byId(appId) || DesktopEntries.heuristicLookup(appId) || null
  }

  // Exact-only lookup for a program found inside a terminal. Binary names are
  // short and generic (git, less, top), so the segment, hostname and heuristic
  // passes above would too often hand them an unrelated app's icon.
  function findExactDesktopEntry(binary) {
    if (!binary) return null

    var lower = binary.toLowerCase()
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].startupClass || "").toLowerCase() === lower) return values[i]
    }
    return DesktopEntries.byId(binary) || null
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // GridLayout's columnSpacing is dead space: the bar only dispatches a click
  // that lands on a registered target, and a gap between two cells belongs to
  // neither. Carry the gap as per-cell padding instead, so every pixel between
  // two workspaces belongs to one of them. The split puts the seam exactly
  // where columnSpacing had it, so nothing moves on screen.
  // One gap for every seam. The cells either side already bring their own
  // padding - an empty cell pads its digit inside a fixed box, an occupied one
  // ends in the spacer that balances its focus badge - so the seam only makes
  // up the difference. Sizing a seam from what sits either side of it went
  // wrong: it lands on one side of a cell but not the other, so a focused cell
  // on that boundary drew its badge visibly off-centre between its neighbours.
  readonly property real cellGap: root.vertical ? 0 : Style.space(2)
  readonly property real cellLeadPad: Math.floor(cellGap / 2)
  readonly property real cellTrailPad: cellGap - cellLeadPad

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: 0
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      Item {
        id: cell
        required property int modelData
        required property int index

        readonly property var workspace: root.workspaceById(modelData)
        readonly property var toplevels: workspace !== null ? root.orderedToplevels(workspace.toplevels.values) : []
        readonly property bool occupied: toplevels.length > 0
        readonly property bool maximized: root.workspaceMaximized(modelData)
        readonly property bool focused: root.monitor && root.monitor.activeWorkspace
          ? root.monitor.activeWorkspace.id === modelData
          : Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        // 10px icons are too few pixels to read on a 1x screen; HiDPI screens
        // already get more physical pixels from the same logical size.
        readonly property real iconSize: Style.space(Screen.devicePixelRatio < 1.25 ? 12 : 10)
        readonly property real leadPad: index === 0 ? 0 : root.cellLeadPad
        readonly property real trailPad: index === root.workspaceIds().length - 1
          ? 0 : root.cellTrailPad

        implicitWidth: row.implicitWidth + leadPad + trailPad
        implicitHeight: row.implicitHeight

        Rectangle {
          // Sized to the maximized outline's box (which keeps its geometry while
          // hidden), so the outline always sits flush on the badge with no gap.
          readonly property real normalLeft: row.x + Style.space(2)
          readonly property real outlineLeft: row.x + numberButton.x + maximizedOutline.x
          readonly property real badgeRight: row.x + row.implicitWidth - Style.space(2)
          anchors.verticalCenter: row.verticalCenter
          x: Math.min(normalLeft, outlineLeft)
          // Grow the right edge by the same amount the left edge reached out.
          width: badgeRight + (normalLeft - x) - x
          height: Math.max(maximizedOutline.height, Math.min(parent.height, cell.iconSize + Style.space(4)))
          radius: Style.space(3)
          // Upstream paints this solid. Route it through the same fill system
          // every other control uses so it follows `selected-fill-alpha` from
          // ~/.config/omarchy/shell.toml instead of hardcoding an opacity here.
          // `selected-color` defaults to "foreground", so this stays neutral.
          color: Style.selectedFillFor(root.bar ? root.bar.barForeground : Color.foreground, Color.accent)
          visible: cell.focused
        }

        // The bar only dispatches a click when it lands on a registered
        // WidgetButton, so every other pixel of the cell eats it: the gaps
        // between icons, the trailing pad, and the strip above and below the
        // icon row (icons are iconSize tall in a barSize tall cell). One
        // full-cell button makes the whole workspace block focus that
        // workspace, which is what a stray click in there was aiming at
        // anyway. Declared before the row so it stays underneath the icons
        // and leaves their hover tooltips alone.
        WidgetButton {
          id: cellButton
          anchors.fill: parent
          bar: root.bar
          labelVisible: false
          hasVisualContent: true
          onPressed: function(button) { root.focusWorkspace(cell.modelData) }
        }

        RowLayout {
          id: row
          anchors.fill: parent
          anchors.leftMargin: cell.leadPad
          anchors.rightMargin: cell.trailPad
          spacing: 0

          WidgetButton {
            id: numberButton
            Layout.alignment: Qt.AlignVCenter
            // The maximized outline spills past the button, so push the icons clear of it.
            Layout.rightMargin: cell.maximized && icons.visible ? Style.space(4) : 0
            bar: root.bar
            text: {
              var slot = cell.modelData - root.rangeMin + 1
              return slot === 10 ? "0" : String(slot)
            }
            foreground: root.bar ? root.bar.barForeground : Color.foreground
            useActiveColor: false
            fontSize: Math.round(Style.font.body * 0.8)
            opacity: cell.occupied || cell.focused ? 1 : 0.5
            horizontalMargin: 6
            verticalPadding: 6
            fixedWidth: root.vertical ? root.barSize : Style.space(14)
            fixedHeight: root.barSize
            onPressed: function() { root.focusWorkspace(cell.modelData) }

            // Outline the number while a window on this workspace is maximized.
            Rectangle {
              id: maximizedOutline
              anchors.centerIn: parent
              // Allowed to spill past the button's fixed width into the cell gap,
              // so the number gets breathing room without shifting the layout.
              width: numberButton.labelWidth + Style.space(10)
              height: Math.min(parent.height, cell.iconSize + Style.space(7))
              radius: Style.space(3)
              color: "transparent"
              border.width: Math.max(1, Style.space(1))
              // Neutral: the bar's own text colour, softened.
              readonly property color tint: root.bar ? root.bar.barForeground : Color.foreground
              border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.55)
              visible: cell.maximized
            }
          }

          Row {
            id: icons
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)
            visible: !root.vertical && cell.toplevels.length > 0

            Repeater {
              model: cell.toplevels

              // The bar host lays its own MouseArea over every module slot to
              // drive widget drag-and-drop, and routes clicks from it into the
              // WidgetButton it finds in Bar.clickTargets under the cursor. A
              // plain MouseArea in here is underneath that overlay, so it never
              // sets the pointer cursor and only ever sees the composed click
              // the overlay chooses to let through - which it drops entirely
              // once the pointer drifts past the bar's drag threshold mid-click.
              // Registering each icon as a WidgetButton puts it in that registry,
              // so the hand cursor and the click both come from the same path
              // the workspace numbers already use. Its tooltip wiring replaces
              // the manual showTooltip/tooltipHovered plumbing too.
              WidgetButton {
                id: icon
                required property var modelData

                readonly property var hyprClient: root.clientFor(modelData)
                readonly property string windowClass: (modelData.wayland && modelData.wayland.appId)
                  || (hyprClient && hyprClient.class) || ""
                readonly property int windowPid: (hyprClient && hyprClient.pid) || 0
                readonly property bool isAgentWindow: windowClass === "org.omarchy.agent"
                readonly property bool isTerminalWindow: root.isTerminalClass(windowClass)
                readonly property bool agentDetectable: isAgentWindow || isTerminalWindow
                property string detectedAgentBinary: ""
                // Program in the foreground of a terminal window (see windowProbeScript).
                property string foregroundBinary: ""
                readonly property string windowTitle: modelData.title || ""

                // Unwrap omarchy-launch-tui's "org.omarchy.<binary>" convention
                // (org.omarchy.agent is handled separately, see isAgentWindow) so
                // lookups use the plain binary name a desktop entry or icon
                // theme would actually recognize.
                readonly property string lookupClass: (!isAgentWindow && windowClass.indexOf("org.omarchy.") === 0)
                  ? root.tuiBinaryName(windowClass)
                  : windowClass

                // Resolve through the app's desktop entry first, same as the Omarchy
                // app launcher menu does, since a window's app id often differs from
                // the icon name in its .desktop file (e.g. Slack, Obsidian).
                readonly property var desktopEntry: root.findDesktopEntry(lookupClass)
                readonly property string iconName: (desktopEntry && desktopEntry.icon) || lookupClass
                // org.omarchy.agent windows are agents by definition, so they take
                // the mark even before the probe names which one. A terminal only
                // gives its icon up once a known agent is actually found inside it.
                readonly property string overridePath: (isAgentWindow || detectedAgentBinary !== "")
                  ? root.agentIconsPath + root.agentIconNameFor(detectedAgentBinary) + ".svg"
                  : ""
                // A terminal running any other program takes that program's icon: an
                // exactly matching desktop entry's icon first, else a theme icon named
                // after the binary. Shells, and programs with neither, leave the
                // terminal's own icon.
                readonly property string foregroundIconPath: {
                  if (foregroundBinary === "" || root.knownShells.indexOf(foregroundBinary) !== -1) return ""
                  var entry = root.findExactDesktopEntry(foregroundBinary)
                  return Quickshell.iconPath((entry && entry.icon) || foregroundBinary, true)
                }

                bar: root.bar
                labelVisible: false
                // WidgetButton hides itself unless it has content to paint; the
                // image is that content, so gate on the image having loaded -
                // this keeps the old `visible: status === Image.Ready` behaviour.
                hasVisualContent: image.status === Image.Ready
                tooltipText: windowTitle
                fixedWidth: cell.iconSize
                fixedHeight: cell.iconSize
                onPressed: function(button) { root.focusWorkspace(cell.modelData) }

                Image {
                  id: image
                  anchors.fill: parent
                  // Rasterize at the on-screen pixel size, like the tray and menu do;
                  // otherwise icons load at native size and get crushed down to ~10px.
                  sourceSize.width: cell.iconSize * Screen.devicePixelRatio
                  sourceSize.height: cell.iconSize * Screen.devicePixelRatio
                  source: icon.overridePath !== "" ? Util.fileUrl(icon.overridePath)
                    : icon.foregroundIconPath !== "" ? icon.foregroundIconPath
                    : icon.iconName !== "" ? Quickshell.iconPath(icon.iconName, "application-x-executable") : ""
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                }

                // Unlike an agent window, a terminal outlives the agent run inside
                // it, so a single probe at load would pin the wrong mark for the
                // rest of the window's life. Re-probe on a slow poll, and again the
                // moment the title changes - a terminal rewrites its title when the
                // foreground program changes, which is exactly the event of interest.
                Process {
                  id: agentProbe
                  property bool sawAgent: false
                  property bool sawForeground: false

                  function probe() {
                    // Hyprland's openwindow event carries only address, class and
                    // title, so a freshly opened window has no pid until the next
                    // clients snapshot covers it. onWindowPidChanged probes again
                    // the moment it does.
                    if (icon.windowPid <= 0) return
                    if (running || !icon.agentDetectable) return
                    sawAgent = false
                    sawForeground = false
                    running = true
                  }

                  command: ["bash", "-c", root.windowProbeScript(icon.windowPid, icon.isTerminalWindow)]
                  stdout: SplitParser {
                    onRead: function(line) {
                      var trimmed = String(line || "").trim()
                      if (trimmed.indexOf("agent:") === 0) {
                        agentProbe.sawAgent = true
                        icon.detectedAgentBinary = trimmed.slice("agent:".length)
                      } else if (trimmed.indexOf("fg:") === 0) {
                        agentProbe.sawForeground = true
                        icon.foregroundBinary = trimmed.slice("fg:".length)
                      }
                    }
                  }
                  // A run that named nothing means the program has exited; clearing
                  // here is what hands the terminal its own icon back.
                  onExited: {
                    if (!agentProbe.sawAgent) icon.detectedAgentBinary = ""
                    if (!agentProbe.sawForeground) icon.foregroundBinary = ""
                  }
                }

                onWindowTitleChanged: agentProbe.probe()
                onWindowPidChanged: agentProbe.probe()

                Timer {
                  interval: 4000
                  repeat: true
                  triggeredOnStart: true
                  running: icon.agentDetectable
                  onTriggered: agentProbe.probe()
                }
              }
            }
          }

          // Mirrors the empty space WidgetButton's centered label leaves inside
          // its fixed-width box, so the badge gets the same breathing room after
          // the rightmost icon as it does before the workspace number.
          Item {
            Layout.alignment: Qt.AlignVCenter
            visible: icons.visible
            width: icons.visible ? Math.max(0, (numberButton.width - numberButton.labelWidth) / 2) : 0
          }
        }
      }
    }
  }
}
