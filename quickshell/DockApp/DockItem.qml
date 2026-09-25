import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Effects
import qs.DockApp

// One app in the dock: its icon, a running/focused indicator, a tooltip with
// the app name and a right-click menu to pin or unpin it.
Item {
    id: item

    // { key, appId, desktopEntry, name, iconSource, windows, pinned } — built by
    // DockWindow, which owns the desktop-entry lookup.
    property var entry: null
    property int iconSize: 32
    // The dock window. It owns the (single) context menu, which is drawn inside
    // its own surface — see DockMenu for why it is not a popup window.
    property var dockWindow: null
    // Window addresses and original workspaces hidden by the toggle.
    // This is intentionally per dock item; the dock groups all windows by app.
    property var hiddenWindows: []

    // Whether the open context menu belongs to this item.
    readonly property bool menuOpen: item.dockWindow
        && item.dockWindow.menuItem === item

    signal pinRequested(string key)
    signal unpinRequested(string key)

    readonly property var windows: item.entry ? item.entry.windows : []
    readonly property bool running: item.windows.length > 0
    readonly property bool pinned: item.entry ? item.entry.pinned : false
    readonly property var desktopEntry: item.entry ? item.entry.desktopEntry : null
    readonly property string appName: item.entry ? item.entry.name : ""
    readonly property string iconSource: item.entry ? item.entry.iconSource : ""

    // Whether one of this app's windows is the focused one.
    readonly property bool active: {
        const focused = ToplevelManager.activeToplevel
        if (!focused)
            return false
        for (let i = 0; i < item.windows.length; i++)
            if (item.windows[i] === focused)
                return true
        return false
    }

    readonly property bool highlighted: itemMouse.containsMouse || item.menuOpen

    implicitWidth: item.iconSize + 16
    implicitHeight: item.iconSize + 18

    // --- ACTIONS ---
    function launch(): void {
        if (item.desktopEntry) {
            item.desktopEntry.execute()
            return
        }
        // No desktop entry (e.g. a pinned id inherited from nwg-dock whose app
        // ships none): run the id as a command, which is what that id is.
        if (item.entry && item.entry.appId)
            Quickshell.execDetached(["bash", "-c", item.entry.appId])
    }

    // --- TOGGLE HELPERS ---
    // The dock holds Wayland toplevels, which carry no window address. The
    // Hyprland list carries the address, the workspace and the activation flag
    // for the same windows, so it is the source of truth for the toggle.
    function normalizeAddress(address): string {
        return String(address || "").toLowerCase().replace(/^0x/, "")
    }

    function isSpecial(workspace): bool {
        return !!workspace && String(workspace.name || "").indexOf("special:") === 0
    }

    function owns(window): bool {
        for (let i = 0; i < item.windows.length; i++)
            if (item.windows[i] === window)
                return true
        return false
    }

    function windowByAddress(address): var {
        const wanted = item.normalizeAddress(address)
        if (wanted === "")
            return null
        const toplevels = Hyprland.toplevels.values
        for (let i = 0; i < toplevels.length; i++)
            if (item.normalizeAddress(toplevels[i].address) === wanted)
                return toplevels[i]
        return null
    }

    // The app's focused window, decided from the app's own windows instead of
    // comparing app ids: covering windows, grouped ids and case differences
    // (Hyprland reports "Hermes" for a dock entry pinned as "hermes") all work.
    // The window must belong to this dock item: the globally active window is
    // never used on its own, or clicking an unfocused app would act on whatever
    // window happens to have focus.
    function activeWindow(): var {
        const toplevels = Hyprland.toplevels.values
        for (let i = 0; i < toplevels.length; i++) {
            const toplevel = toplevels[i]
            if (!toplevel.activated || item.isSpecial(toplevel.workspace))
                continue
            if (item.owns(toplevel.wayland))
                return toplevel
        }
        const active = Hyprland.activeToplevel
        item.log("no-active own=" + item.windows.length
            + " activeAddr=0x" + item.normalizeAddress(active ? active.address : "")
            + " activeMine=" + item.owns(active ? active.wayland : null))
        return null
    }

    // A window of this app parked in a special workspace.
    function parkedWindow(): var {
        const toplevels = Hyprland.toplevels.values
        for (let i = 0; i < toplevels.length; i++) {
            const toplevel = toplevels[i]
            if (!item.isSpecial(toplevel.workspace))
                continue
            if (item.owns(toplevel.wayland))
                return toplevel
        }
        return null
    }

    // Escape values embedded in Hyprland's single-quoted Lua expressions.
    function escapeLuaString(value: string): string {
        return String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'")
    }

    // Both dispatches travel in one Lua chunk: two separate hyprctl processes
    // can race and leave the window moved but not focused.
    function restoreCommand(address, workspace): string {
        const addr = item.normalizeAddress(address)
        const target = item.escapeLuaString(workspace)
        return "hl.dispatch(hl.dsp.window.move({ workspace = '" + target
            + "', window = 'address:0x" + addr + "', follow = false })); "
            + "hl.dispatch(hl.dsp.focus({ window = 'address:0x" + addr + "' }))"
    }

    function hideCommand(address): string {
        return "hl.dispatch(hl.dsp.window.move({ workspace = 'special:minimized'"
            + ", window = 'address:0x" + item.normalizeAddress(address)
            + "', follow = false }))"
    }

    // Where a window without a recorded origin comes back to.
    function homeWorkspace(window): string {
        const monitor = window && window.monitor ? window.monitor : Hyprland.focusedMonitor
        const workspace = monitor && monitor.activeWorkspace
            ? monitor.activeWorkspace : Hyprland.focusedWorkspace
        if (workspace && !item.isSpecial(workspace))
            return String(workspace.id)
        return "1"
    }

    function dispatch(command: string): void {
        Quickshell.execDetached(["hyprctl", "eval", command])
    }

    function log(message: string): void {
        console.log("[dock-toggle] " + item.appName + ": " + message)
    }

    // --- LAYOUT POSITION ---
    // Hyprland re-inserts a window at the end of its workspace layout, so a
    // restored window loses its slot (left/right among its neighbours). The
    // geometry a window had before hiding is remembered from the compositor's
    // client list (the dock's Wayland toplevels carry no geometry) and the
    // window is swapped back into place afterwards.
    property var pendingHide: null
    property var pendingRestore: null
    property int restoreRounds: 0

    function queryClients(): void {
        clientsQuery.running = true
    }

    function findClient(list, address): var {
        const wanted = item.normalizeAddress(address)
        for (let i = 0; i < list.length; i++)
            if (item.normalizeAddress(list[i].address) === wanted)
                return list[i]
        return null
    }

    function onClients(list): void {
        if (item.pendingHide) {
            const record = item.pendingHide
            item.pendingHide = null
            const client = item.findClient(list, record.addr)
            if (client) {
                record.x = client.at[0]
                record.y = client.at[1]
                record.w = client.size[0]
                record.h = client.size[1]
                record.monitor = client.monitor
            }
            item.hiddenWindows.push(record)
            item.dispatch(item.hideCommand(record.addr))
            item.log("minimize addr=0x" + record.addr + " ws=" + record.ws
                + " slot=" + record.x + "," + record.y
                + " size=" + record.w + "x" + record.h)
            return
        }
        if (item.pendingRestore)
            item.reorder(list)
    }

    // Swap the restored window back into the slot it had before, in small
    // verified steps. Skipped when the window's size or monitor changed: the
    // layout is not the one the position was recorded from.
    function reorder(list): void {
        const record = item.pendingRestore
        const client = item.findClient(list, record.addr)
        if (!client) {
            item.pendingRestore = null
            return
        }
        const sameSlot = record.w !== undefined
            && client.size[0] === record.w && client.size[1] === record.h
            && client.monitor === record.monitor
        const dx = sameSlot ? client.at[0] - record.x : 0
        const dy = sameSlot ? client.at[1] - record.y : 0
        if (dx === 0 && dy === 0) {
            item.pendingRestore = null
            item.log("reorder ok addr=0x" + record.addr
                + " slot=" + client.at[0] + "," + client.at[1])
            return
        }
        if (item.restoreRounds >= 3) {
            item.pendingRestore = null
            item.log("reorder stopped addr=0x" + record.addr
                + " slot=" + client.at[0] + "," + client.at[1])
            return
        }
        item.restoreRounds += 1
        const stepX = dx > 0 ? "left" : "right"
        const stepY = dy > 0 ? "up" : "down"
        const countX = Math.min(Math.round(Math.abs(dx) / Math.max(1, record.w)), 4)
        const countY = Math.min(Math.round(Math.abs(dy) / Math.max(1, record.h)), 4)
        if (countX === 0 && countY === 0) {
            item.pendingRestore = null
            item.log("reorder skipped addr=0x" + record.addr
                + " size=" + client.size[0] + "x" + client.size[1])
            return
        }
        let chunk = item.focusCommand(record.addr)
        for (let i = 0; i < countX; i++)
            chunk += "; " + item.swapCommand(stepX)
        for (let i = 0; i < countY; i++)
            chunk += "; " + item.swapCommand(stepY)
        item.dispatch(chunk)
        item.log("reorder addr=0x" + record.addr + " " + countX + "x" + stepX
            + " " + countY + "x" + stepY)
        restoreSettle.start()
    }

    function focusCommand(address): string {
        return "hl.dispatch(hl.dsp.focus({ window = 'address:0x"
            + item.normalizeAddress(address) + "' }))"
    }

    function swapCommand(direction): string {
        return "hl.dispatch(hl.dsp.window.swap({ direction = '"
            + direction + "' }))"
    }

    function queueReorder(record): void {
        if (record.w === undefined)
            return
        item.pendingRestore = record
        item.restoreRounds = 0
        restoreSettle.start()
    }

    Process {
        id: clientsQuery
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            id: clientsOutput
            waitForEnd: true
        }
        onExited: {
            let list = []
            try {
                list = JSON.parse(clientsOutput.text)
            } catch (error) {
                list = []
            }
            item.onClients(list)
        }
    }

    Timer {
        id: restoreSettle
        interval: 150
        repeat: false
        onTriggered: item.queryClients()
    }

    // Focus the app, or toggle its focused window into/out of the special
    // minimized workspace. Hyprland 0.56 uses the Lua dispatcher API.
    function activate(): void {
        if (!item.running) {
            item.log("launch")
            item.launch()
            return
        }

        // 1. Windows we hid earlier: bring every one of them back, then put the
        //    first one back into the slot it had in the layout.
        if (item.hiddenWindows.length > 0) {
            let restored = 0
            let firstSlot = null
            while (item.hiddenWindows.length > 0) {
                const hidden = item.hiddenWindows.shift()
                if (!item.windowByAddress(hidden.addr))
                    continue // closed while it was hidden
                const workspace = hidden.ws !== undefined && hidden.ws >= 0
                    ? String(hidden.ws) : "name:" + hidden.wsName
                item.dispatch(item.restoreCommand(hidden.addr, workspace))
                if (firstSlot === null && hidden.w !== undefined)
                    firstSlot = hidden
                restored++
            }
            item.log("restore count=" + restored)
            if (firstSlot)
                item.queueReorder(firstSlot)
            return
        }

        // 2. One of this app's windows is focused: hide it. The slot is read
        //    from the compositor first, so it can be restored afterwards.
        const active = item.activeWindow()
        if (active) {
            const workspace = active.workspace
            item.pendingHide = {
                addr: item.normalizeAddress(active.address),
                ws: workspace ? workspace.id : 1,
                wsName: workspace ? workspace.name : ""
            }
            item.queryClients()
            return
        }

        // 3. A window of this app sits in a special workspace with no record —
        //    the dock restarted while it was minimized.
        const parked = item.parkedWindow()
        if (parked) {
            const workspace = item.homeWorkspace(parked)
            item.dispatch(item.restoreCommand(parked.address, workspace))
            item.log("restore unrecorded addr=0x"
                + item.normalizeAddress(parked.address) + " ws=" + workspace)
            return
        }

        // 4. Otherwise retain the upstream behavior: focus the only window or
        // cycle through multiple windows of the selected application.
        const focused = ToplevelManager.activeToplevel
        if (item.windows.length === 1) {
            item.log("focus single")
            item.windows[0].activate()
            return
        }
        let index = -1
        for (let i = 0; i < item.windows.length; i++)
            if (item.windows[i] === focused)
                index = i
        item.log("focus next index=" + index)
        item.windows[(index + 1) % item.windows.length].activate()
    }

    function closeWindows(): void {
        // Copy first: closing mutates the toplevel list this array comes from.
        const list = item.windows.slice()
        for (let i = 0; i < list.length; i++)
            list[i].close()
    }

    // Entries for the right-click menu, rebuilt each time it opens.
    function menuActions(): var {
        let actions = []
        if (item.pinned)
            actions.push({ "label": "Unpin from Dock",
                           "callback": () => item.unpinRequested(item.entry.key) })
        else
            actions.push({ "label": "Pin to Dock",
                           "callback": () => item.pinRequested(item.entry.key) })
        actions.push({ "label": item.running ? "New Window" : "Launch",
                       "callback": () => item.launch() })
        if (item.running)
            actions.push({ "label": item.windows.length > 1
                               ? "Close All Windows" : "Close Window",
                           "callback": () => item.closeWindows() })
        return actions
    }

    // --- ICON ---
    // Accent circle behind the icon on hover, matching the status bar buttons.
    Rectangle {
        id: hoverBg
        anchors.centerIn: iconImage
        width: item.iconSize + 14
        height: item.iconSize + 14
        radius: width / 2
        color: item.highlighted ? DockTheme.primary : "transparent"
        opacity: item.highlighted ? 0.25 : 0

        Behavior on color {
            ColorAnimation { duration: 500; easing.type: Easing.OutQuint }
        }
        Behavior on opacity {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuint }
        }
    }

    Image {
        id: iconImage
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        // Like nwg-dock, the icon sits a touch above the true centre so the
        // running indicator below it does not feel cramped.
        anchors.verticalCenterOffset: -2
        source: item.iconSource
        width: item.iconSize
        height: item.iconSize
        sourceSize.width: item.iconSize * 2
        sourceSize.height: item.iconSize * 2
        fillMode: Image.PreserveAspectFit
        // Pinned apps that are not running are dimmed, like in nwg-dock.
        opacity: item.running ? 1 : 0.55
        scale: item.highlighted ? 1.12 : 1

        Behavior on opacity {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuint }
        }
        Behavior on scale {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuint }
        }
    }

    // --- RUNNING INDICATOR ---
    // A dot below the icon for a running app; it widens into a short bar while
    // one of its windows has focus. The icon stays centred in the dock, so the
    // indicator sits in the small gap left below it.
    Rectangle {
        id: indicator
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        height: 4
        width: item.active ? 14 : 4
        radius: 2
        color: DockTheme.primary
        opacity: item.running ? 1 : 0

        Behavior on width {
            NumberAnimation { duration: 350; easing.type: Easing.OutQuint }
        }
        Behavior on opacity {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuint }
        }
    }

    MouseArea {
        id: itemMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

        onClicked: (mouse) => {
            if (mouse.button === Qt.LeftButton) {
                item.activate()
            } else if (mouse.button === Qt.MiddleButton) {
                item.launch()
            } else if (mouse.button === Qt.RightButton) {
                if (!item.dockWindow)
                    return
                // A second right click on the same icon closes the menu again.
                if (item.menuOpen) {
                    item.dockWindow.closeMenu()
                    return
                }
                tooltipTimer.stop()
                tooltip.visible = false
                item.dockWindow.openMenuFor(item, item.menuActions())
            }
        }

        onEntered: tooltipTimer.restart()
        onExited: {
            tooltipTimer.stop()
            tooltip.visible = false
        }
    }

    // --- TOOLTIP ---
    Timer {
        id: tooltipTimer
        interval: 400
        onTriggered: {
            if (itemMouse.containsMouse && !item.menuOpen)
                tooltip.visible = true
        }
    }

    PopupWindow {
        id: tooltip

        color: "transparent"
        implicitWidth: tooltipBg.implicitWidth
        implicitHeight: tooltipBg.implicitHeight

        // A partial anchor.rect collapses the anchor rectangle and the popup
        // never shows — the gap has to come from margins (see DockMenu).
        anchor.item: item
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Top
        anchor.margins.bottom: 6

        Rectangle {
            id: tooltipBg
            anchors.centerIn: parent
            implicitWidth: tooltipText.implicitWidth + 20
            implicitHeight: tooltipText.implicitHeight + 12
            radius: 8
            color: DockTheme.surface_container_high
            border.width: 1
            border.color: DockTheme.outline_variant

            Text {
                id: tooltipText
                anchors.centerIn: parent
                text: item.windows.length > 1
                    ? item.appName + " (" + item.windows.length + ")"
                    : item.appName
                color: DockTheme.on_surface
                font.family: DockTheme.fontFamily
                font.pixelSize: 14
            }
        }
    }

}
