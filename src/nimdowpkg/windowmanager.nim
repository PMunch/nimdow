import
  x11 / [x, xlib, xutil, xatom, xft],
  parsetoml,
  math,
  sugar,
  tables,
  client,
  xatoms,
  monitor,
  statusbar,
  systray,
  tag,
  area,
  config/configloader,
  event/xeventmanager,
  layouts/masterstacklayout,
  keys/keyutils,
  logger

converter intToCint(x: int): cint = x.cint
converter intToCUint(x: int): cuint = x.cuint
converter uintToCuing(x: uint): cuint = x.cuint
converter cintToUint(x: cint): uint = x.uint
converter cintToCUint(x: cint): cuint = x.cuint
converter intToCUchar(x: int): cuchar = x.cuchar
converter clongToCUlong(x: clong): culong = x.culong
converter toXBool(x: bool): XBool = x.XBool
converter toBool(x: XBool): bool = x.bool

const
  wmName = "nimdow"
  tagCount = 9
  minimumUpdateInterval = math.round(1000 / 60).int
  systrayMonitorIndex = 0

  SYSTEM_TRAY_REQUEST_DOCK = 0

  XEMBED_EMBEDDED_NOTIFY = 0
  XEMBED_MAPPED = 1 shl 0
  XEMBED_WINDOW_ACTIVATE = 1
  XEMBED_WINDOW_DEACTIVATE = 2

  VERSION_MAJOR = 0
  VERSION_MINOR = 0
  XEMBED_EMBEDDED_VERSION = (VERSION_MAJOR shl 16) or VERSION_MINOR

type
  MouseState* = enum
    Normal, Moving, Resizing
  WindowManager* = ref object
    display*: PDisplay
    rootWindow*: Window
    systray: Systray
    eventManager: XEventManager
    config: Config
    windowSettings: WindowSettings
    monitors: seq[Monitor]
    selectedMonitor: Monitor
    mouseState: MouseState
    lastMousePress: tuple[x, y: int]
    lastMoveResizeClientState: Area
    lastMoveResizeTime: culong
    moveResizingClient: Client

proc initListeners(this: WindowManager)
proc openDisplay(): PDisplay
proc mapConfigActions*(this: WindowManager)
proc configureRootWindow(this: WindowManager): Window
proc hookConfigKeys*(this: WindowManager)
proc errorHandler(display: PDisplay, error: PXErrorEvent): cint{.cdecl.}
proc destroySelectedWindow*(this: WindowManager)
proc onConfigureRequest(this: WindowManager, e: XConfigureRequestEvent)
proc onClientMessage(this: WindowManager, e: XClientMessageEvent)
proc onMapRequest(this: WindowManager, e: XMapRequestEvent)
proc onUnmapNotify(this: WindowManager, e: XUnmapEvent)
proc onResizeRequest(this: WindowManager, e: XResizeRequestEvent)
proc onMotionNotify(this: WindowManager, e: XMotionEvent)
proc onEnterNotify(this: WindowManager, e: XCrossingEvent)
proc onFocusIn(this: WindowManager, e: XFocusChangeEvent)
proc onPropertyNotify(this: WindowManager, e: XPropertyEvent)
proc onExposeNotify(this: WindowManager, e: XExposeEvent)
proc onDestroyNotify(this: WindowManager, e: XDestroyWindowEvent)
proc handleButtonPressed(this: WindowManager, e: XButtonEvent)
proc handleButtonReleased(this: WindowManager, e: XButtonEvent)
proc handleMouseMotion(this: WindowManager, e: XMotionEvent)
proc renderWindowTitle(this: WindowManager, monitor: Monitor)
proc renderStatus(this: WindowManager)
proc setSelectedMonitor(this: WindowManager, monitor: Monitor)
proc setClientState(this: WindowManager, client: Client, state: int)
proc unmanage(this: WindowManager, window: Window, destroyed: bool)
proc updateSizeHints(this: WindowManager, client: var Client, monitor: Monitor)
proc updateSystray(this: WindowManager)
proc updateSystrayIconGeom(this: WindowManager, icon: Icon, width, height: int)
proc updateSystrayIconState(this: WindowManager, icon: Icon, e: XPropertyEvent)
proc windowToClient(
  this: WindowManager,
  window: Window
): tuple[client: Client, monitor: Monitor]
proc windowToMonitor(this: WindowManager, window: Window): Monitor

proc newWindowManager*(eventManager: XEventManager, config: Config, configTable: TomlTable): WindowManager =
  result = WindowManager()
  result.display = openDisplay()
  result.rootWindow = result.configureRootWindow()
  result.eventManager = eventManager
  discard XSetErrorHandler(errorHandler)

  # Config setup
  result.config = config
  result.config.populateGeneralSettings(configTable)
  result.mapConfigActions()
  result.config.populateKeyComboTable(configTable, result.display)
  result.config.hookConfig()
  result.hookConfigKeys()

  result.windowSettings = result.config.windowSettings
  # Populate atoms
  xatoms.WMAtoms = xatoms.getWMAtoms(result.display)
  xatoms.NetAtoms = xatoms.getNetAtoms(result.display)
  xatoms.XAtoms = xatoms.getXAtoms(result.display)
  result.initListeners()

  # Create monitors
  for area in result.display.getMonitorAreas(result.rootWindow):
    result.monitors.add(
      newMonitor(result.display, result.rootWindow, area, result.config)
    )

  result.renderStatus()

  # Supporting window for NetWMCheck
  let ewmhWindow = XCreateSimpleWindow(result.display, result.rootWindow, 0, 0, 1, 1, 0, 0, 0)

  discard XChangeProperty(
    result.display,
    result.rootWindow,
    $NetSupportingWMCheck,
    XA_WINDOW,
    32,
    PropModeReplace,
    cast[Pcuchar](ewmhWindow.unsafeAddr),
    1
  )

  discard XChangeProperty(
    result.display,
    ewmhWindow,
    $NetSupportingWMCheck,
    XA_WINDOW,
    32,
    PropModeReplace,
    cast[Pcuchar](ewmhWindow.unsafeAddr),
    1
  )

  discard XChangeProperty(
    result.display,
    ewmhWindow,
    $NetWMName,
    XInternAtom(result.display, "UTF8_STRING", false),
    8,
    PropModeReplace,
    cast[Pcuchar](wmName),
    wmName.len
  )

  discard XChangeProperty(
    result.display,
    result.rootWindow,
    $NetWMName,
    XInternAtom(result.display, "UTF8_STRING", false),
    8,
    PropModeReplace,
    cast[Pcuchar](wmName),
    wmName.len
  )

  discard XChangeProperty(
    result.display,
    result.rootWindow,
    $NetSupported,
    XA_ATOM,
    32,
    PropModeReplace,
    cast[Pcuchar](xatoms.NetAtoms.unsafeAddr),
    ord(NetLast)
  )

  # We need to map this window to be able to set the input focus to it
  # when no other window is available to be focused.
  discard XMapWindow(result.display, ewmhWindow)
  var changes: XWindowChanges
  changes.stack_mode = Below
  discard XConfigureWindow(result.display, ewmhWindow, CWStackMode, addr(changes))

  block setNumberOfDesktops:
    let data: array[1, clong] = [9]
    discard XChangeProperty(
      result.display,
      result.rootWindow,
      $NetNumberOfDesktops,
      XA_CARDINAL,
      32,
      PropModeReplace,
      cast[Pcuchar](data.unsafeAddr),
      1
    )

  block setDesktopNames:
    var tags: array[tagCount, cstring] =
      ["1".cstring,
       "2".cstring,
       "3".cstring,
       "4".cstring,
       "5".cstring,
       "6".cstring,
       "7".cstring,
       "8".cstring,
       "9".cstring]
    var text: XTextProperty
    discard Xutf8TextListToTextProperty(
      result.display,
      cast[PPChar](tags[0].addr),
      tagCount,
      XUTF8StringStyle,
      text.unsafeAddr
    )
    XSetTextProperty(result.display,
      result.rootWindow,
      text.unsafeAddr,
      $NetDesktopNames
    )

  block setDesktopViewport:
    let data: array[2, clong] = [0, 0]
    discard XChangeProperty(
      result.display,
      result.rootWindow,
      $NetDesktopViewport,
      XA_CARDINAL,
      32,
      PropModeReplace,
      cast[Pcuchar](data.unsafeAddr),
      2
    )

  result.setSelectedMonitor(result.monitors[0])
  result.updateSystray()

template systrayMonitor(this: WindowManager): Monitor =
  this.monitors[systrayMonitorIndex]

proc reloadConfig*(this: WindowManager) =
  # Remove old config listener.
  this.eventManager.removeListener(this.config.listener, KeyPress)

  this.config = newConfig(this.eventManager)
  logger.enabled = this.config.loggingEnabled

  let configTable = configloader.loadConfigFile()
  this.config.populateGeneralSettings(configTable)
  this.mapConfigActions()
  this.config.populateKeyComboTable(configTable, this.display)
  this.config.hookConfig()
  this.hookConfigKeys()

  this.windowSettings = this.config.windowSettings
  for monitor in this.monitors:
    monitor.setConfig(this.config)

  this.updateSystray()

proc initListeners(this: WindowManager) =
  this.eventManager.addListener((e: XEvent) => onConfigureRequest(this, e.xconfigurerequest), ConfigureRequest)
  this.eventManager.addListener((e: XEvent) => onClientMessage(this, e.xclient), ClientMessage)
  this.eventManager.addListener((e: XEvent) => onMapRequest(this, e.xmaprequest), MapRequest)
  this.eventManager.addListener((e: XEvent) => onUnmapNotify(this, e.xunmap), UnmapNotify)
  this.eventManager.addListener((e: XEvent) => onResizeRequest(this, e.xresizerequest), ResizeRequest)
  this.eventManager.addListener((e: XEvent) => onMotionNotify(this, e.xmotion), MotionNotify)
  this.eventManager.addListener((e: XEvent) => onEnterNotify(this, e.xcrossing), EnterNotify)
  this.eventManager.addListener((e: XEvent) => onFocusIn(this, e.xfocus), FocusIn)
  this.eventManager.addListener((e: XEvent) => onPropertyNotify(this, e.xproperty), PropertyNotify)
  this.eventManager.addListener((e: XEvent) => onExposeNotify(this, e.xexpose), Expose)
  this.eventManager.addListener((e: XEvent) => onDestroyNotify(this, e.xdestroywindow), DestroyNotify)
  this.eventManager.addListener((e: XEvent) => handleButtonPressed(this, e.xbutton), ButtonPress)
  this.eventManager.addListener((e: XEvent) => handleButtonReleased(this, e.xbutton), ButtonRelease)
  this.eventManager.addListener((e: XEvent) => handleMouseMotion(this, e.xmotion), MotionNotify)

proc openDisplay(): PDisplay =
  let tempDisplay = XOpenDisplay(nil)
  if tempDisplay == nil:
    quit "Failed to open display"
  return tempDisplay

proc configureRootWindow(this: WindowManager): Window =
  result = DefaultRootWindow(this.display)

  var windowAttribs: XSetWindowAttributes
  # Listen for events defined by eventMask.
  # See https://tronche.com/gui/x/xlib/events/processing-overview.html#SubstructureRedirectMask
  windowAttribs.event_mask = SubstructureRedirectMask or PropertyChangeMask or PointerMotionMask

  # Listen for events on the root window
  discard XChangeWindowAttributes(
    this.display,
    result,
    CWEventMask or CWCursor,
    addr(windowAttribs)
  )
  discard XSync(this.display, false)

proc focusMonitor(this: WindowManager, monitorIndex: int) =
  if monitorIndex == -1:
    return
  let monitor = this.monitors[monitorIndex]
  if monitor.currTagClients.len == 0:
    let center = monitor.area.center()
    discard XWarpPointer(
      this.display,
      x.None,
      this.rootWindow,
      0,
      0,
      0,
      0,
      center.x.cint,
      center.y.cint,
    )
  else:
    if monitor.currClient != nil:
      this.display.warpTo(monitor.currClient)

proc focusPreviousMonitor(this: WindowManager) =
  let previousMonitorIndex = this.monitors.findPrevious(this.selectedMonitor)
  this.focusMonitor(previousMonitorIndex)

proc focusNextMonitor(this: WindowManager) =
  let nextMonitorIndex = this.monitors.findNext(this.selectedMonitor)
  this.focusMonitor(nextMonitorIndex)

proc setSelectedMonitor(this: WindowManager, monitor: Monitor) =
  ## Sets the selected monitor.
  ## This should be called, NEVER directly assign this.selectedMonitor.
  if this.selectedMonitor != nil:
    this.selectedMonitor.statusBar.setIsMonitorSelected(false)

  this.selectedMonitor = monitor
  this.selectedMonitor.statusBar.setIsMonitorSelected(true)

proc moveClientToMonitor(this: WindowManager, monitorIndex: int) =
  if monitorIndex == -1 or this.selectedMonitor.currClient == nil:
    return

  let client = this.selectedMonitor.currClient
  let nextMonitor = this.monitors[monitorIndex]
  if this.selectedMonitor.removeWindow(client.window):
    this.selectedMonitor.doLayout()
    this.selectedMonitor.redrawStatusBar()

  nextMonitor.currTagClients.add(client)

  if client.isFloating:
    let deltaX = client.x - this.selectedMonitor.area.x
    let deltaY = client.y - this.selectedMonitor.area.y
    client.resize(
      this.display,
      nextMonitor.area.x + deltaX,
      nextMonitor.area.y + deltaY,
      client.width,
      client.height
    )
  elif client.isFullscreen:
    client.resize(
      this.display,
      nextMonitor.area.x,
      nextMonitor.area.y,
      nextMonitor.area.width,
      nextMonitor.area.height
     )
  else:
    nextMonitor.doLayout(false)

  this.setSelectedMonitor(nextMonitor)
  this.selectedMonitor.focusClient(client, true)
  this.selectedMonitor.redrawStatusBar()

proc moveClientToPreviousMonitor(this: WindowManager) =
  let previousMonitorIndex = this.monitors.findPrevious(this.selectedMonitor)
  this.moveClientToMonitor(previousMonitorIndex)

proc moveClientToNextMonitor(this: WindowManager) =
  let nextMonitorIndex = this.monitors.findNext(this.selectedMonitor)
  this.moveClientToMonitor(nextMonitorIndex)

proc increaseMasterCount(this: WindowManager) =
  var layout = this.selectedMonitor.selectedTag.layout
  if layout of MasterStackLayout:
    # This can wrap the uint but the number is crazy high
    # so I don't think it "ruins" the user experience.
    MasterStackLayout(layout).masterSlots.inc
    this.selectedMonitor.doLayout()

proc decreaseMasterCount(this: WindowManager) =
  var layout = this.selectedMonitor.selectedTag.layout
  if layout of MasterStackLayout:
    var masterStackLayout = MasterStackLayout(layout)
    if masterStackLayout.masterSlots.int > 0:
      masterStackLayout.masterSlots.dec
      this.selectedMonitor.doLayout()

proc goToTag(this: WindowManager, tag: var Tag) =
  if this.selectedMonitor.previousTag != nil and this.selectedMonitor.selectedTag.id == tag.id:
    tag = this.selectedMonitor.previousTag
    this.selectedMonitor.previousTag = this.selectedMonitor.selectedTag
  else:
    this.selectedMonitor.previousTag = this.selectedMonitor.selectedTag

  this.selectedMonitor.viewTag(tag)
  this.selectedMonitor.withSomeCurrClient(client):
    this.display.warpTo(client)

template createControl(keycode: untyped, id: string, action: untyped) =
  this.config.configureAction(id, proc(keycode: int) = action)

proc mapConfigActions*(this: WindowManager) =
  ## Maps available user configuration options to window manager actions.
  createControl(keycode, "reloadConfig"):
    this.reloadConfig()

  createControl(keycode, "increaseMasterCount"):
    this.increaseMasterCount()

  createControl(keycode, "decreaseMasterCount"):
    this.decreaseMasterCount()

  createControl(keycode, "moveWindowToPreviousMonitor"):
    this.moveClientToPreviousMonitor()

  createControl(keycode, "moveWindowToNextMonitor"):
    this.moveClientToNextMonitor()

  createControl(keycode, "focusPreviousMonitor"):
    this.focusPreviousMonitor()

  createControl(keycode, "focusNextMonitor"):
    this.focusNextMonitor()

  createControl(keycode, "goToTag"):
    var tag = this.selectedMonitor.keycodeToTag(keycode)
    this.goToTag(tag)

  createControl(keycode, "goToPreviousTag"):
    var previousTag = this.selectedMonitor.previousTag
    if previousTag != nil:
      this.goToTag(previousTag)

  createControl(keycode, "focusNext"):
    this.selectedMonitor.focusNextClient(true)
    if this.selectedMonitor.currClient != nil:
      this.display.warpTo(this.selectedMonitor.currClient)

  createControl(keycode, "focusPrevious"):
    this.selectedMonitor.focusPreviousClient(true)
    if this.selectedMonitor.currClient != nil:
      this.display.warpTo(this.selectedMonitor.currClient)

  createControl(keycode, "moveWindowPrevious"):
    this.selectedMonitor.moveClientPrevious()

  createControl(keycode, "moveWindowNext"):
    this.selectedMonitor.moveClientNext()

  createControl(keycode, "moveWindowToTag"):
    let tag = this.selectedMonitor.keycodeToTag(keycode)
    this.selectedMonitor.moveSelectedWindowToTag(tag)

  createControl(keycode, "toggleFullscreen"):
    this.selectedMonitor.toggleFullscreenForSelectedClient()

  createControl(keycode, "destroySelectedWindow"):
    this.destroySelectedWindow()

  createControl(keycode, "toggleFloating"):
    this.selectedMonitor.toggleFloatingForSelectedClient()

proc hookConfigKeys*(this: WindowManager) =
  ## Grabs key combos defined in the user's config
  updateNumlockMask(this.display)
  let modifiers = [0.cuint, LockMask.cuint, numlockMask, numlockMask or LockMask.cuint]

  discard XUngrabKey(this.display, AnyKey, AnyModifier, this.rootWindow)
  for keyCombo in this.config.keyComboTable.keys:
    for modifier in modifiers:
      discard XGrabKey(
        this.display,
        keyCombo.keycode,
        keyCombo.modifiers or modifier,
        this.rootWindow,
        true,
        GrabModeAsync,
        GrabModeAsync
      )

  # We only care about left and right clicks
  discard XUngrabButton(this.display, AnyButton, AnyModifier, this.rootWindow)
  for button in @[Button1, Button3]:
    discard XGrabButton(
      this.display,
      button,
      AnyModifier,
      this.rootWindow,
      false,
      ButtonPressMask or ButtonReleaseMask or PointerMotionMask,
      GrabModeASync,
      GrabModeASync,
      x.None,
      x.None
    )

proc errorHandler(display: PDisplay, error: PXErrorEvent): cint{.cdecl.} =
  var errorMessage: string = newString(1024)
  discard XGetErrorText(
    display,
    cint(error.error_code),
    errorMessage.cstring,
    errorMessage.len
  )
  # Reduce string length down to the proper size
  errorMessage.setLen(errorMessage.cstring.len)
  log errorMessage, lvlError

proc destroySelectedWindow*(this: WindowManager) =
  let client = this.selectedMonitor.currClient
  if client != nil:
    var
      selectedWin = client.window
      event = XEvent()
      numProtocols: int
      exists: bool
      protocols: PAtom

    if XGetWMProtocols(this.display, selectedWin, protocols.addr, cast[Pcint](numProtocols.addr)) != 0:
      let protocolsArr = cast[ptr UncheckedArray[Atom]](protocols)
      while not exists and numProtocols > 0:
        numProtocols.dec
        exists = protocolsArr[numProtocols] == $WMDelete
      discard XFree(protocols)

    if exists:
      event.xclient.theType = ClientMessage
      event.xclient.window = selectedWin
      event.xclient.message_type = $WMProtocols
      event.xclient.format = 32
      event.xclient.data.l[0] = ($WMDelete).cint
      event.xclient.data.l[1] = CurrentTime
      event.xclient.data.l[2] = 0
      event.xclient.data.l[3] = 0
      event.xclient.data.l[4] = 0
      discard XSendEvent(this.display, selectedWin, false, NoEventMask, addr(event))

    if not exists:
      discard XGrabServer(this.display)
      proc dummy(display: PDisplay, e: PXErrorEvent): cint {.cdecl.} = 0.cint
      discard XSetErrorHandler(dummy)
      discard XSetCloseDownMode(this.display, DestroyAll)
      discard XKillClient(this.display, selectedWin)
      discard XSync(this.display, false)
      discard XSetErrorHandler(errorHandler)
      discard XUngrabServer(this.display)

proc onConfigureRequest(this: WindowManager, e: XConfigureRequestEvent) =
  var (client, monitor) = this.windowToClient(e.window)

  if client != nil:

    if this.moveResizingClient == client:
      return

    if (e.value_mask and CWBorderWidth) != 0 and e.border_width > 0:
      client.borderWidth = e.border_width
    elif client.isFloating:
      if (e.value_mask and CWX) != 0:
        client.oldX = client.x
        client.x = monitor.area.x + e.x
      if (e.value_mask and CWY) != 0:
        client.oldY = client.y
        client.y = monitor.area.y + e.y
      if (e.value_mask and CWWidth) != 0:
        client.oldWidth = client.width.uint
        client.width = e.width.uint
      if (e.value_mask and CWHeight) != 0:
        client.oldHeight = client.height.uint
        client.height = e.height.uint

      if not client.isFixed:
        if client.x == 0:
          client.x = monitor.area.x + (monitor.area.width.int div 2 - (client.width.int div 2))
        if client.y == 0:
          client.y = monitor.area.y + (monitor.area.height.int div 2 - (client.height.int div 2))

      if (client.x + client.width) > monitor.area.x + monitor.area.width:
        # Center in X direction
        client.x = monitor.area.x + (monitor.area.width.int div 2 - client.totalWidth div 2)
      if (client.y + client.height) > monitor.area.y + monitor.area.height:
        # Center in Y direction
        client.y = monitor.area.y + (monitor.area.height.int div 2 - client.totalHeight div 2)

      if (e.value_mask and (CWX or CWY)) != 0 and (e.value_mask and (CWWidth or CWHeight)) == 0:
        client.configure(this.display)
      if monitor == this.selectedMonitor and monitor.currTagClients.contains(client):
        discard XMoveResizeWindow(
          this.display,
          e.window,
          client.x,
          client.y,
          client.width.cint,
          client.height.cint
        )
      else:
        client.needsResize = true
    else:
      client.configure(this.display)
  else:
    var changes: XWindowChanges
    changes.x = e.detail
    changes.y = e.detail
    changes.width = e.width
    changes.height = e.height
    changes.border_width = e.border_width
    changes.sibling = e.above
    changes.stack_mode = e.detail
    discard XConfigureWindow(this.display, e.window, e.value_mask.cuint, changes.addr)

  discard XSync(this.display, false)

proc onClientMessage(this: WindowManager, e: XClientMessageEvent) =
  if e.window == this.systray.window and e.message_type == $NetSystemTrayOP:
    # Add systray icons
    if  e.data.l[1] == SYSTEM_TRAY_REQUEST_DOCK:
      if e.data.l[2] == 0:
        return

      var
        windowAttr: XWindowAttributes
        setWindowAttr: XSetWindowAttributes

      var icon: Icon = newIcon(e.data.l[2])
      this.systray.addIcon(icon)
      if XGetWindowAttributes(this.display, icon.window, windowAttr.addr) == 0:
        # Use sane defaults.
        let barHeight = this.config.barSettings.height
        windowAttr.width = barHeight.cint
        windowAttr.height = barHeight.cint
        windowAttr.border_width = 0

      icon.width = windowAttr.width
      icon.oldwidth = windowAttr.width
      icon.height = windowAttr.height
      icon.oldHeight = windowAttr.height
      icon.oldBorderWidth = windowAttr.border_width
      icon.borderWidth = 0
      icon.isFloating = true
      icon.isMapped = true

      this.updateSizeHints(Client(icon), this.systrayMonitor)
      this.updateSystrayIconGeom(icon, windowAttr.width, windowAttr.height)

      discard XAddToSaveSet(this.display, icon.window)
      discard XSelectInput(
        this.display,
        icon.window,
        StructureNotifyMask or PropertyChangeMask or ResizeRedirectMask
      )

      var classHint: XClassHint
      classHint.res_name = "nimdowsystray"
      classHint.res_class = "nimdowsystray"
      discard XSetClassHint(this.display, icon.window, classHint.addr)

      discard XReparentWindow(
        this.display,
        icon.window,
        this.systray.window,
        0,
        0
      )

      # Use parent's background color
      setWindowAttr.background_pixel = this.systrayMonitor.statusBar.bgColor.pixel
      discard XChangeWindowAttributes(this.display, icon.window, CWBackPixel, setWindowAttr.addr)
      discard sendEvent(
        this.display,
        icon.window,
        $Xembed,
        StructureNotifyMask,
        CurrentTime,
        XEMBED_EMBEDDED_NOTIFY,
        0,
        this.systray.window.clong,
        XEMBED_EMBEDDED_VERSION
      )

      discard XSync(this.display, false)

      this.systrayMonitor.statusBar.resizeForSystray(this.systray.getWidth())
      this.updateSystray()
      this.setClientState(Client(icon), NormalState)

    return

  var (client, monitor) = this.windowToClient(e.window)
  if client != nil:
    if e.message_type == $NetWMState:
      let fullscreenAtom = $NetWMStateFullScreen
      if e.data.l[1] == fullscreenAtom.clong or
        e.data.l[2] == fullscreenAtom.clong:
        # See the end of this section:
        # https://specifications.freedesktop.org/wm-spec/wm-spec-1.3.html#idm45805407959456
          var shouldFullscreen =
            e.data.l[0] == 1 or
            e.data.l[0] == 2 and not client.isFullscreen
          monitor.setFullscreen(client, shouldFullscreen)
    elif e.message_type == $NetActiveWindow:
      let currClient = this.selectedMonitor.currClient
      if currClient != nil:
        if client != currClient and not client.isUrgent:
          client.setUrgent(this.display, true)

proc updateWindowType(this: WindowManager, client: var Client) =
  let
    stateOpt = this.display.getProperty[:Atom](client.window, $NetWMState)
    windowTypeOpt = this.display.getProperty[:Atom](client.window, $NetWMWindowType)

  let state = if stateOpt.isSome: stateOpt.get else: x.None
  let windowType = if windowTypeOpt.isSome: windowTypeOpt.get else: x.None

  if state == $NetWMStateFullScreen:
    let (_, monitor) = this.windowToClient(client.window)
    if monitor != nil:
      monitor.setFullscreen(client, true)

  if windowType == $NetWMWindowTypeDialog:
    client.isFloating = true

proc updateSizeHints(this: WindowManager, client: var Client, monitor: Monitor) =
  var sizeHints = XAllocSizeHints()
  var returnMask: int
  if XGetWMNormalHints(this.display, client.window, sizeHints, returnMask.addr) == 0:
    sizeHints.flags = PSize

  if sizeHints.min_width > 0 and sizeHints.min_width == sizeHints.max_width and
     sizeHints.min_height > 0 and sizeHints.min_height == sizeHints.max_height:

    client.isFloating = true
    client.width = max(client.width, sizeHints.min_width.uint)
    client.height = max(client.height, sizeHints.min_height.uint)

    if not client.isFixed and not client.isFullscreen:
      if monitor == this.selectedMonitor and monitor.currTagClients.find(client.window) != -1:
        let area = monitor.area
        client.x = area.x + (area.width.int div 2 - (client.width.int div 2))
        client.y = area.y + (area.height.int div 2 - (client.height.int div 2))
        discard XMoveWindow(
          this.display,
          client.window,
          client.x,
          client.y
        )
      else:
        client.needsResize = true

proc updateWMHints(this: WindowManager, client: Client) =
  var hints: PXWMHints = XGetWMHints(this.display, client.window)
  if hints != nil:
    this.selectedMonitor.withSomeCurrClient(c):
      if c == client and (hints.flags and XUrgencyHint) != 0:
        hints[].flags = hints[].flags and (not XUrgencyHint)
        discard XSetWMHints(this.display, client.window, hints)
      discard XFree(hints)

proc setClientState(this: WindowManager, client: Client, state: int) =
  var state = [state, x.None]
  discard XChangeProperty(
    this.display,
    client.window,
    $WMState,
    $WMState,
    32,
    PropModeReplace,
    cast[Pcuchar](state.addr),
    2
  )

proc manage(this: WindowManager, window: Window, windowAttr: XWindowAttributes) =
  var
    client: Client
    monitor = this.selectedMonitor

  var (c, m) = this.windowToClient(window)
  if c != nil:
    monitor = m
    client = c
  else:
    client = newClient(window)
    monitor.currTagClients.add(client)
    client.x = this.selectedMonitor.area.x + windowAttr.x
    client.oldX = client.x
    client.y = this.selectedMonitor.area.y + windowAttr.y
    client.oldY = client.y
    client.width = windowAttr.width
    client.oldWidth = client.width
    client.height = windowAttr.height
    client.oldHeight = client.height
    client.oldBorderWidth = windowAttr.border_width

  monitor.updateWindowTagAtom(client.window, monitor.selectedTag.id)
  monitor.addWindowToClientListProperty(window)

  discard XSetWindowBorder(
    this.display,
    window,
    this.windowSettings.borderColorUnfocused
  )

  client.configure(this.display)

  discard XSelectInput(
    this.display,
    window,
    StructureNotifyMask or
    PropertyChangeMask or
    ResizeRedirectMask or
    EnterWindowMask or
    FocusChangeMask
  )

  this.updateWindowType(client)
  this.updateSizeHints(client, monitor)
  this.updateWMHints(client)

  discard XMoveResizeWindow(
    this.display,
    window,
    client.x,
    client.y,
    client.width.cuint,
    client.height.cuint
  )

  this.setClientState(client, NormalState)
  if not client.isFloating and not client.isFixed:
    monitor.setSelectedClient(client)
    monitor.doLayout()

  discard XMapWindow(this.display, window)

proc onMapRequest(this: WindowManager, e: XMapRequestEvent) =
  var windowAttr: XWindowAttributes

  let icon = this.systray.windowToIcon(e.window)
  if icon != nil:
    discard this.display.sendEvent(
      icon.window,
      $Xembed,
      StructureNotifyMask,
      CurrentTime,
      XEMBED_WINDOW_ACTIVATE,
      0,
      this.systray.window.clong,
      XEMBED_EMBEDDED_VERSION
    )
    this.systrayMonitor.statusBar.resizeForSystray(this.systray.getWidth())
    this.updateSystray()

  if XGetWindowAttributes(this.display, e.window, windowAttr.addr) == 0:
    return
  if windowAttr.override_redirect:
    return
  this.manage(e.window, windowAttr)

proc unmanage(this: WindowManager, window: Window, destroyed: bool) =
  let (client, monitor) = this.windowToClient(window)
  if client != nil:
    discard monitor.removeWindow(window)
    if not destroyed:
      var winChanges: XWindowChanges
      winChanges.border_width = client.oldBorderWidth.cint
      discard XGrabServer(this.display)
      proc dummy(display: PDisplay, e: PXErrorEvent): cint {.cdecl.} = 0.cint
      discard XSetErrorHandler(dummy)
      discard XConfigureWindow(this.display, window, CWBorderWidth, winChanges.addr)
      discard XUngrabButton(this.display, AnyButton, AnyModifier, window)
      this.setClientState(client, WithdrawnState)
      discard XSync(this.display, false)
      discard XSetErrorHandler(errorHandler)
      discard XUngrabServer(this.display)

    monitor.doLayout(false)
    monitor.updateClientList()
    monitor.statusBar.redraw()

    if monitor == this.selectedMonitor:
      if monitor.currClient != nil:
        this.selectedMonitor.focusClient(monitor.currClient, true)

proc onDestroyNotify(this: WindowManager, e: XDestroyWindowEvent) =
  let (client, _) = this.windowToClient(e.window)
  if client != nil:
    this.unmanage(e.window, true)
  else:
    let icon = this.systray.windowToIcon(e.window)
    if icon != nil:
      this.systray.removeIcon(icon)
      this.systrayMonitor.statusBar.resizeForSystray(this.systray.getWidth())
      this.updateSystray()

proc onUnmapNotify(this: WindowManager, e: XUnmapEvent) =
  let (client, _) = this.windowToClient(e.window)
  if client != nil:
    if e.send_event:
      this.setClientState(client, WithdrawnState)
    else:
      this.unmanage(client.window, false)
  else:
    let icon = this.systray.windowToIcon(e.window)
    if icon != nil:
      # Sometimes icons unmap their windows but don't destroy them.
      # We map those windows back.
      discard XMapRaised(this.display, icon.window)
      this.updateSystray()

proc selectCorrectMonitor(this: WindowManager, x, y: int) =
  for monitor in this.monitors:
    if not monitor.area.contains(x, y) or monitor == this.selectedMonitor:
      continue
    let previousMonitor = this.selectedMonitor
    this.setSelectedMonitor(monitor)
    # Set old monitor's focused window's border to the unfocused color
    if previousMonitor.currClient != nil:
      discard XSetWindowBorder(
        this.display,
        previousMonitor.currClient.window,
        this.windowSettings.borderColorUnfocused
      )
    # Focus the new monitor's current client
    if this.selectedMonitor.currClient != nil:
      this.selectedMonitor.focusClient(this.selectedMonitor.currClient, false)
    else:
      discard XSetInputFocus(this.display, this.rootWindow, RevertToPointerRoot, CurrentTime)
    break

proc updateSystray(this: WindowManager) =
  var
    setWindowAttr: XSetWindowAttributes
    backgroundColor = this.systrayMonitor.statusBar.bgColor
    x = this.systrayMonitor.area.x + this.systrayMonitor.area.width.int

  let
    backgroundPixel = backgroundColor.pixel
    barHeight = this.config.barSettings.height

  if this.systray == nil:
    this.systray = Systray()

    this.systray.window = XCreateSimpleWindow(
      this.display,
      this.rootWindow,
      x,
      this.systrayMonitor.statusBar.area.y,
      1,
      barHeight,
      0,
      0,
      backgroundPixel
    )

    setWindowAttr.event_mask = ButtonPressMask or ExposureMask
    setWindowAttr.override_redirect = true
    setWindowAttr.background_pixel = backgroundPixel

    discard XSelectInput(this.display, this.systray.window, SubstructureNotifyMask)
    discard XChangeProperty(
      this.display,
      this.systray.window,
      $NetSystemTrayOrientation,
      XA_CARDINAL,
      32,
      PropModeReplace,
      cast[Pcuchar](($NetSystemTrayOrientation).addr),
      1
    )
    discard XChangeWindowAttributes(
      this.display,
      this.systray.window,
      CWEventMask or CWOverrideRedirect or CWBackPixel,
      setWindowAttr.addr
    )
    discard XMapRaised(this.display, this.systray.window)
    discard XSetSelectionOwner(this.display, $NetSystemTray, this.systray.window, CurrentTime)

    if XGetSelectionOwner(this.display, $NetSystemTray) == this.systray.window:
      discard this.display.sendEvent(
        this.rootWindow,
        $Manager,
        StructureNotifyMask,
        CurrentTime,
        ($NetSystemTray).clong,
        this.systray.window.clong,
        0,
        0
      )
      discard XSync(this.display, false)
    else:
      log("Unable to obtain systray", lvlError)
      this.systray = nil
      return

  let barArea = this.systrayMonitor.statusBar.area

  var systrayWidth: int
  for icon in this.systray.icons:
    setWindowAttr.background_pixel = backgroundPixel
    discard XChangeWindowAttributes(this.display, icon.window, CWBackPixel, setWindowAttr.addr)
    discard XMapRaised(this.display, icon.window)
    systrayWidth += systrayIconSpacing
    icon.x = systrayWidth

    let centerY = (barArea.height.float / 2 - icon.height.float / 2).int

    discard XMoveResizeWindow(
      this.display,
      icon.window,
      icon.x,
      centerY,
      icon.width,
      icon.height
    )
    systrayWidth += icon.width.int

  systrayWidth = max(1, systrayWidth + systrayIconSpacing)

  var winChanges: XWindowChanges

  x -= systrayWidth

  discard XMoveResizeWindow(
    this.display,
    this.systray.window,
    x,
    barArea.y,
    systrayWidth,
    barHeight
  )

  winChanges.x = x
  winChanges.y = barArea.y
  winChanges.width = systrayWidth
  winChanges.height = barArea.height.cint
  winChanges.stack_mode = Above
  winChanges.sibling = this.systrayMonitor.statusBar.barWindow

  discard XConfigureWindow(
    this.display,
    this.systray.window,
    CWX or CWY or CWWidth or CWHeight or CWSibling or CWStackMode,
    winChanges.addr
  )

  discard XMapWindow(this.display, this.systray.window)
  discard XMapSubwindows(this.display, this.systray.window)

  discard XSync(this.display, false)

proc updateSystrayIconGeom(this: WindowManager, icon: Icon, width, height: int) =
  if icon == nil:
    return

  let barHeight = this.config.barSettings.height
  icon.height = barHeight
  if width == height:
    icon.width = barHeight
  elif height == barHeight:
    icon.width = width
  else:
    icon.width = int(barHeight.float * (width / height))

  # Force icons into the systray dimensions if they don't want to
  if icon.height > barHeight:
    if icon.width == icon.height:
      icon.width = barHeight
    else:
      icon.width = int(barHeight.float * (icon.width.float / icon.height.float))
    icon.height = barHeight

proc updateSystrayIconState(this: WindowManager, icon: Icon, e: XPropertyEvent) =
  if icon == nil or e.atom != $XembedInfo:
    return

  let
    flagsOpt = this.display.getProperty[:Atom](icon.window, $XembedInfo)
    flags: clong = if flagsOpt.isSome: flagsOpt.get.clong else: 0

  if flags == 0:
    return

  var iconActiveState: int
  if (flags and XEMBED_MAPPED) != 0 and not icon.isMapped:
    # Requesting to be mapped
    icon.isMapped = true
    iconActiveState = XEMBED_WINDOW_ACTIVATE
    discard XMapRaised(this.display, icon.window)
    this.setClientState(Client(icon), NormalState)
  elif (flags and XEMBED_MAPPED) == 0 and icon.isMapped:
    # Requesting to be upmapped
    icon.isMapped = false
    iconActiveState = XEMBED_WINDOW_DEACTIVATE
    discard XUnmapWindow(this.display, icon.window)
    this.setClientState(Client(icon), WithdrawnState)
  else:
    return

  discard this.display.sendEvent(
    icon.window,
    $Xembed,
    StructureNotifyMask,
    CurrentTime,
    iconActiveState,
    0,
    this.systray.window.clong,
    XEMBED_EMBEDDED_VERSION
  )

proc onResizeRequest(this: WindowManager, e: XResizeRequestEvent) =
  let icon = this.systray.windowToIcon(e.window)
  if icon == nil:
    return

  this.updateSystrayIconGeom(icon, e.width, e.height)
  let monitor = this.monitors[systrayMonitorIndex]
  monitor.statusBar.resizeForSystray(this.systray.getWidth())
  this.updateSystray()

proc onMotionNotify(this: WindowManager, e: XMotionEvent) =
  # If moving/resizing a client, we delay selecting the new monitor.
  if this.mouseState == MouseState.Normal:
    this.selectCorrectMonitor(e.x_root, e.y_root)

proc onEnterNotify(this: WindowManager, e: XCrossingEvent) =
  if this.mouseState != MouseState.Normal or e.window == this.rootWindow:
    return
  this.selectCorrectMonitor(e.x_root, e.y_root)
  let clientIndex = this.selectedMonitor.currTagClients.find(e.window)
  if clientIndex >= 0:
    discard XSetInputFocus(this.display, e.window, RevertToPointerRoot, CurrentTime)

proc onFocusIn(this: WindowManager, e: XFocusChangeEvent) =
  if this.mouseState != Normal or e.detail == NotifyPointer or e.window == this.rootWindow:
    if this.selectedMonitor.currClient == nil:
      # Clear the window title (no windows are focused)
      this.selectedMonitor.statusBar.setActiveWindowTitle("")
    return

  var client: Client
  let clientIndex = this.selectedMonitor.currTagClients.find(e.window)
  # If the window is not on the current tag, select the tag's current client.
  if clientIndex < 0:
    if this.selectedMonitor.currClient != nil:
      client = this.selectedMonitor.currClient
    else:
      # If there's no client on the current tag, select the root window.
      # This ensures e.window does not have focus.
      discard XSetInputFocus(this.display, this.rootWindow, RevertToPointerRoot, CurrentTime)
      discard XDeleteProperty(this.display, this.rootWindow, $NetActiveWindow)
      return
  else:
    # e.window is in our current tag.
    client = this.selectedMonitor.currTagClients[clientIndex]

  this.selectedMonitor.setActiveWindowProperty(e.window)
  this.selectedMonitor.setSelectedClient(client)
  client.takeFocus(this.display)
  discard XSetWindowBorder(
    this.display,
    client.window,
    this.windowSettings.borderColorFocused
  )

  var wasPreviousClientFloating = false
  if this.selectedMonitor.selectedTag.previouslySelectedClient != nil:
    let previous = this.selectedMonitor.selectedTag.previouslySelectedClient
    if previous.window != client.window:
      discard XSetWindowBorder(
        this.display,
        previous.window,
        this.windowSettings.borderColorUnfocused
      )
      wasPreviousClientFloating = previous.isFloating

  # Only do this if the last client wasn't floating.
  if client.isFloating and not wasPreviousClientFloating:
    discard XRaiseWindow(this.display, client.window)

  # Render the active window title on the status bar.
  this.renderWindowTitle(this.selectedMonitor)

proc renderWindowTitle(this: WindowManager, monitor: Monitor) =
  ## Renders the title of the active window of the given monitor
  ## on the monitor's status bar.
  monitor.withSomeCurrClient(client):
    let title = this.display.getWindowName(client.window)
    this.selectedMonitor.statusBar.setActiveWindowTitle(title)

proc renderStatus(this: WindowManager) =
  ## Renders the status on all status bars.
  var name: cstring
  if XFetchName(this.display, this.rootWindow, name.addr) == 1:
    let status = $name
    for monitor in this.monitors:
      monitor.statusBar.setStatus(status)

proc windowToMonitor(this: WindowManager, window: Window): Monitor =
  for monitor in this.monitors:
    if window == monitor.statusBar.barWindow:
      return monitor
    for clients in monitor.taggedClients.values():
      for client in clients:
        if client.window == window:
          return monitor
  return this.selectedMonitor

proc windowToClient(
  this: WindowManager,
  window: Window
): tuple[client: Client, monitor: Monitor] =
  ## Finds a client based on its window.
  ## Both the returned values will either be nil, or valid.
  var client: Client
  for monitor in this.monitors:
    client = monitor.find(window)
    if client != nil:
      return (client, monitor)

proc onPropertyNotify(this: WindowManager, e: XPropertyEvent) =
  let icon = this.systray.windowToIcon(e.window)
  if icon != nil:
    if e.atom == XA_WM_NORMAL_HINTS:
      this.updateSystrayIconGeom(icon, icon.width.int, icon.height.int)
    else:
      this.updateSystrayIconState(icon, e)
    this.systrayMonitor.statusBar.resizeForSystray(this.systray.getWidth())
    this.updateSystray()

  if e.window == this.rootWindow and e.atom == XA_WM_NAME:
    this.renderStatus()
  elif e.state == PropertyDelete:
    return
  else:
    var (client, monitor) = this.windowToClient(e.window)
    if client == nil:
      return

    case e.atom:
      of XA_WM_TRANSIENT_FOR:
        var transientWin: Window
        if not client.isFloating and XGetTransientForHint(this.display, client.window, transientWin.addr) != 0:
          let c = this.windowToClient(transientWin)
          client.isFloating = c.client != nil
          if client.isFloating:
            monitor.doLayout()
      of XA_WM_NORMAL_HINTS:
        this.updateSizeHints(client, monitor)
      of XA_WM_HINTS:
        this.updateWMHints(client)
        for monitor in this.monitors:
          monitor.redrawStatusBar()
      else:
        discard

    if e.atom == XA_WM_NAME or e.atom == $NetWMName:
      if monitor.currClient != nil:
        if monitor.currClient == client:
          let name = this.display.getWindowName(client.window)
          monitor.statusBar.setActiveWindowTitle(name)

    if e.atom == $NetWMWindowType:
      this.updateWindowType(client)

proc onExposeNotify(this: WindowManager, e: XExposeEvent) =
  if e.count == 0:
    let monitor = this.windowToMonitor(e.window)
    if monitor != nil:
      monitor.redrawStatusBar()
      if monitor == this.selectedMonitor:
        this.updateSystray()

proc selectClientForMoveResize(this: WindowManager, e: XButtonEvent) =
  if this.selectedMonitor.currClient == nil:
      return
  let client = this.selectedMonitor.currClient
  this.moveResizingClient = client
  this.lastMousePress = (e.x.int, e.y.int)
  this.lastMoveResizeClientState = client.area

proc handleButtonPressed(this: WindowManager, e: XButtonEvent) =
  if e.window == this.systray.window:
    # Clicked systray window, don't do anything.
    return

  let modPressed = (e.state and Mod4Mask) != 0
  if modPressed:
    case e.button:
      of Button1:
        this.mouseState = MouseState.Moving
        this.selectClientForMoveResize(e)
      of Button3:
        this.mouseState = MouseState.Resizing
        this.selectClientForMoveResize(e)
      else:
        this.mouseState = MouseState.Normal
  else:
    # Click happened without mod being pressed
    let (client, monitor) = this.windowToClient(e.subwindow)
    if client != nil and client.isFloating:
      monitor.focusClient(client, false)
      discard XRaiseWindow(this.display, client.window)

proc handleButtonReleased(this: WindowManager, e: XButtonEvent) =
  this.mouseState = MouseState.Normal

  if this.moveResizingClient == nil:
    return

  # Handle moving clients between monitors
  let client = this.moveResizingClient
  # Detect new monitor from area location
  let
    centerX = client.x + client.width.int div 2
    centerY = client.y + client.height.int div 2

  let monitorIndex = this.monitors.find(centerX, centerY)
  if monitorIndex < 0 or this.monitors[monitorIndex] == this.selectedMonitor:
    return
  let
    nextMonitor = this.monitors[monitorIndex]
    prevMonitor = this.selectedMonitor
  # Remove client from current monitor/tag
  discard prevMonitor.removeWindow(client.window)
  nextMonitor.currTagClients.add(client)
  nextMonitor.focusClient(client, false)
  let title = this.display.getWindowName(client.window)
  nextMonitor.statusBar.setActiveWindowTitle(title)

  this.setSelectedMonitor(nextMonitor)
  # Unset the client being moved/resized
  this.moveResizingClient = nil

proc handleMouseMotion(this: WindowManager, e: XMotionEvent) =
  if this.mouseState == Normal or this.moveResizingClient == nil:
    return

  var client = this.moveResizingClient
  if client.isFullscreen:
    return

  # Prevent trying to process events too quickly (causes major lag).
  if e.time - this.lastMoveResizeTime < minimumUpdateInterval:
    return

  # Track the last time we moved or resized a window.
  this.lastMoveResizeTime = e.time

  if not client.isFloating:
    client.isFloating = true
    client.borderWidth = this.windowSettings.borderWidth.int
    this.selectedMonitor.doLayout(false)

  let
    deltaX = e.x - this.lastMousePress.x
    deltaY = e.y - this.lastMousePress.y

  if this.mouseState == Moving:
    client.resize(
      this.display,
      this.lastMoveResizeClientState.x + deltaX,
      this.lastMoveResizeClientState.y + deltaY,
      max(1, this.lastMoveResizeClientState.width.int),
      max(1, this.lastMoveResizeClientState.height.int)
    )
  elif this.mouseState == Resizing:
    client.resize(
      this.display,
      this.lastMoveResizeClientState.x,
      this.lastMoveResizeClientState.y,
      max(1, this.lastMoveResizeClientState.width.int + deltaX),
      max(1, this.lastMoveResizeClientState.height.int + deltaY)
    )

