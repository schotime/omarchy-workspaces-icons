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

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
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
  // emulator's, with the agent CLI running as its child/grandchild).
  function agentDetectScript(pid) {
    return "frontier=" + pid + "; for d in 1 2 3 4 5; do "
      + "frontier=$(pgrep -P \"$frontier\" | tr '\\n' ',' | sed 's/,$//'); "
      + "[ -z \"$frontier\" ] && break; "
      + "for p in $(echo \"$frontier\" | tr ',' ' '); do "
      + "c=$(ps -o comm= -p \"$p\" 2>/dev/null); "
      + "case \"$c\" in " + root.knownAgentBinaries.join("|") + ") echo \"$c\"; exit 0;; esac; "
      + "done; done"
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
  readonly property real cellGap: root.vertical ? 0 : Style.space(3)
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
        readonly property var toplevels: workspace !== null ? workspace.toplevels.values : []
        readonly property bool occupied: toplevels.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property real iconSize: Style.space(10)
        readonly property real leadPad: index === 0 ? 0 : root.cellLeadPad
        readonly property real trailPad: index === root.workspaceIds().length - 1
          ? 0 : root.cellTrailPad

        implicitWidth: row.implicitWidth + leadPad + trailPad
        implicitHeight: row.implicitHeight

        Rectangle {
          anchors.centerIn: row
          width: row.implicitWidth - Style.space(4)
          height: Math.min(parent.height, cell.iconSize + Style.space(4))
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
            bar: root.bar
            // The colon reads as a separator between the number and the icons
            // that follow it, so an empty workspace has nothing to separate -
            // drop it and tighten the box to match the shorter label.
            text: (cell.modelData === 10 ? "0" : String(cell.modelData)) + (cell.occupied ? ":" : "")
            foreground: root.bar ? root.bar.barForeground : Color.foreground
            useActiveColor: false
            fontSize: Style.font.body - 4
            opacity: cell.occupied || cell.focused ? 1 : 0.5
            horizontalMargin: 6
            verticalPadding: 6
            fixedWidth: root.vertical ? root.barSize : (cell.occupied ? Style.space(20) : Style.space(15))
            fixedHeight: root.barSize
            onPressed: function() { root.focusWorkspace(cell.modelData) }
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

                readonly property string windowClass: (modelData.wayland && modelData.wayland.appId)
                  || (modelData.lastIpcObject && modelData.lastIpcObject.class) || ""
                readonly property int windowPid: (modelData.lastIpcObject && modelData.lastIpcObject.pid) || 0
                readonly property bool isAgentWindow: windowClass === "org.omarchy.agent"
                property string detectedAgentBinary: ""
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
                readonly property string overridePath: isAgentWindow
                  ? root.agentIconsPath + root.agentIconNameFor(detectedAgentBinary) + ".svg"
                  : ""

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
                  source: icon.overridePath !== "" ? Util.fileUrl(icon.overridePath)
                    : icon.iconName !== "" ? Quickshell.iconPath(icon.iconName, "application-x-executable") : ""
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                }

                Process {
                  running: icon.isAgentWindow && icon.windowPid > 0
                  command: ["bash", "-c", root.agentDetectScript(icon.windowPid)]
                  stdout: SplitParser {
                    onRead: function(line) {
                      var trimmed = String(line || "").trim()
                      if (trimmed !== "") icon.detectedAgentBinary = trimmed
                    }
                  }
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
