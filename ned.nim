# NEd (NimEd) -- a GTK3/GtkSourceView Nim editor with nimsuggest support
# S. Salewski, 2017-NOV-21
# v 0.4.4
#
# Note: for resetting gsettings database:
# gsettings --schemadir "." reset-recursively "org.gtk.ned"
#
# And for making gsettings available system wide one method is, as root
# https://developer.gnome.org/gio/stable/glib-compile-schemas.html
# echo $XDG_DATA_DIRS
# /usr/share/gnome:/usr/local/share:/usr/share:/usr/share/gdm
# cd /usr/local/share/glib-2.0/schemas
# cp org.gtk.ned.gschema.xml .
# glib-compile-schemas .
#
# TODO: remove proc int() from gtk3 and gobject module

import oldgtk3/[gobject, gtk, gdk, gio, glib, gtksource, gdk_pixbuf, pango]
import osproc, streams, os, net, strutils, sequtils, parseutils, locks, times #, strscans, logging

{.deadCodeElim: on.}
{.link: "resources.o".}
{.push warning[SmallLshouldNotBeUsed]: off.}

const
  # ProgramName = "NEd"
  MaxErrorTags = 16
  NullStr = cstring(nil)
  ErrorTagName = "error"
  HighlightTagName = "high"
  NSPort = Port(6000)
  StyleSchemeSettingsID = cstring("styleschemesettingsid") # must be lower case
  FontSettingsID = cstring("fontsettingsid") # must be lower case
  UseCat = "UseCat"

type
  LogLevel {.pure.} = enum
    debug, log, warn, error

var nsProcess: Process # nimsuggest

type # for channel communication
  StatusMsg = object
    filepath: string
    dirtypath: string
    line: int
    column: int

type
  NimEdAppWindow = ptr NimEdAppWindowObj
  NimEdAppWindowObj = object of gtk.ApplicationWindowObj
    grid: gtk.Grid
    settings: gio.GSettings
    gears: MenuButton
    searchentry: SearchEntry
    entry: Entry
    searchcountlabel: Label
    statuslabel: Label
    headerbar: Headerbar
    statusbar: Statusbar
    savebutton: Button
    searchMatchBg: string
    searchMatchFg: string
    openbutton: Button
    buffers: GList
    views: GList
    target: Notebook # where to open "Goto Definition" view
    statusID1: cuint
    statusID2: cuint
    messageID: cuint
    timeoutEventSourceID: cuint
    msgThreadSourceID: cuint
    logLevel: LogLevel

  NimEdAppWindowClass = ptr NimEdAppWindowClassObj
  NimEdAppWindowClassObj = object of gtk.ApplicationWindowClassObj

gDefineType(NimEdAppWindow, applicationWindowGetType())

template typeNimEdAppWindow(): untyped = nimEdAppWindowGetType()

proc nimEdAppWindow(obj: GPointer): NimEdAppWindow =
  gTypeCheckInstanceCast(obj, typeNimEdAppWindow, NimEdAppWindowObj)

# proc isNimEdAppWindow(obj: GPointer): GBoolean =
#   gTypeCheckInstanceType(obj, typeNimEdAppWindow)

var thread: Thread[NimEdAppWindow]
var channel: system.Channel[StatusMsg]

type
  NimViewError = tuple
    gs: GString
    line, col, id: int

type
  NimView = ptr NimViewObj
  NimViewObj = object of gtksource.ViewObj
    errors: GList
    idleScroll: cuint
    searchSettings: SearchSettings
    searchContext: SearchContext
    label: Label

  NimViewClass = ptr NimViewClassObj
  NimViewClassObj = object of gtksource.ViewClassObj

gDefineType(NimView, viewGetType())

# template typeNimView(): untyped = nimViewGetType()

proc nimView(obj: GPointer): NimView =
  gTypeCheckInstanceCast(obj, nimViewGetType(), NimViewObj)

# proc isNimView(obj: GPointer): GBoolean =
#   gTypeCheckInstanceType(obj, typeNimView)

proc nimViewDispose(obj: GObject) {.cdecl.} =
  let view = nimView(obj)
  if view.idleScroll != 0:
    discard sourceRemove(view.idleScroll)
    view.idleScroll = 0
  gObjectClass(nimViewParentClass).dispose(obj)

proc freeNVE(data: Gpointer) {.cdecl.} =
  let e = cast[ptr NimViewError](data)
  discard glib.free(e.gs, freeSegment = true)
  glib.free(data)

proc freeErrors(v: NimView) {.cdecl.} =
  glib.freeFull(v.errors, freeNVE)
  v.errors = nil

proc nimViewFinalize(gobject: GObject) {.cdecl.} =
  nimView(gobject).freeErrors
  gObjectClass(nimViewParentClass).finalize(gobject)

proc nimViewClassInit(klass: NimViewClass) =
  klass.dispose = nimViewDispose
  klass.finalize = nimViewFinalize

proc nimViewInit(self: NimView) =
  discard

proc newNimView(buffer: gtksource.Buffer): NimView =
  nimView(newObject(nimViewGetType(), "buffer", buffer, nil))

# return errorID > 0 when new error position, or 0 for old position
proc addError(v: NimView, s: cstring; line, col: int): int =
  var
    el: ptr NimViewError
    p: GList = v.errors
  while p != nil:
    el = cast[ptr NimViewError](p.data)
    if el.line == line and el.col == col:
      el.gs.appendPrintf("\n%s", s)
      return 0
    p = p.next
  let i = system.int(v.errors.length) + 1
  if i > MaxErrorTags: return 0
  el = cast[ptr NimViewError](glib.malloc(sizeof(NimViewError)))
  el.gs = glib.newGString(s)
  el.line = line
  el.col = col
  el.id = i
  v.errors = glib.prepend(v.errors, el)
  return i

proc appendError(v: NimView, s: cstring) =
  let p: GList = v.errors
  if p != nil:
    let el = cast[ptr NimViewError](p.data)
    el.gs.appendPrintf("\n%s", s)

type
  NimViewBuffer = ptr NimViewBufferObj
  NimViewBufferObj = object of gtksource.BufferObj
    path: cstring
    defView: bool # buffer is from "Goto Definition", we may replace it
    handlerID: culong # from notify::cursor-position callback

  NimViewBufferClass = ptr NimViewBufferClassObj
  NimViewBufferClassObj = object of gtksource.BufferClassObj

gDefineType(NimViewBuffer, gtksource.bufferGetType())

# template typeNimViewBuffer(): untyped = nimViewBufferGetType()

proc nimViewBuffer(obj: GPointer): NimViewBuffer =
  gTypeCheckInstanceCast(obj, nimViewBufferGetType(), NimViewBufferObj)

# proc isNimViewBuffer(obj: GPointer): GBoolean =
#   gTypeCheckInstanceType(obj, typeNimViewBuffer)

proc nimViewBufferDispose(obj: GObject) {.cdecl.} =
  gObjectClass(nimViewBufferParentClass).dispose(obj)

proc nimViewBufferFinalize(gobject: GObject) {.cdecl.} =
  free(nimViewBuffer(gobject).path)
  gObjectClass(nimViewBufferParentClass).finalize(gobject)

proc nimViewBufferClassInit(klass: NimViewBufferClass) =
  klass.dispose = nimViewBufferDispose
  klass.finalize = nimViewBufferFinalize

proc setPath(buffer: NimViewBuffer; str: cstring) =
  free(buffer.path)
  buffer.path = str

proc nimViewBufferInit(self: NimViewBuffer) = # {.cdecl.}  is in forward declaration
  discard

proc newNimViewBuffer(language: gtksource.Language): NimViewBuffer =
  nimViewBuffer(newObject(nimViewBufferGetType(), "tag-table", nil, "language", language, nil))

proc buffer(view: NimView): NimViewBuffer =
  nimViewBuffer(view.getBuffer)

proc showmsg1(win: NimEdAppWindow; t: cstring) =
  win.statusbar.removeAll(win.statusID2)
  if t != nil:
    discard win.statusbar.push(win.statusID2, t)

# this hack is from gedit 3.20
proc scrollToCursor(v: GPointer): GBoolean {.cdecl.} =
  let v = nimView(v)
  #let buffer = v.buffer
  v.scrollToMark(v.buffer.insert, withinMargin = 0.25, useAlign = false, xalign = 0, yalign = 0)
  v.idleScroll = 0
  return G_SOURCE_REMOVE

type
  ThreadMsg = object
    win: NimEdAppWindow
    msg: cstring

proc showMsgFromThread(tm: GPointer): GBoolean {.cdecl.} =
  let tm = cast[ptr ThreadMsg](tm)
  showmsg1(tm.win, tm.msg)
  tm.win.msgThreadSourceID = 0
  return G_SOURCE_REMOVE

type
  Provider = ptr ProviderObj
  ProviderObj = object of CompletionProviderObj
    proposals, filteredProposals: GList
    priority: cint
    win: NimEdAppWindow
    name: cstring
    icon: GdkPixbuf

  ProviderPrivate = ptr ProviderPrivateObj
  ProviderPrivateObj = object

  ProviderClass = ptr ProviderClassObj
  ProviderClassObj = object of GObjectClassObj

proc providerIfaceInit(iface: CompletionProviderIface) {.cdecl.}

# typeIface: The GType of the interface to add
# ifaceInit: The interface init function
proc gImplementInterfaceStr(typeIface, ifaceInit: string): string =
  """
var gImplementInterfaceInfo = GInterfaceInfoObj(interfaceInit: cast[GInterfaceInitFunc]($2),
                                                     interfaceFinalize: nil,
                                                     interfaceData: nil)
addInterfaceStatic(gDefineTypeId, $1, addr(gImplementInterfaceInfo))

""" % [typeIface, ifaceInit]

gDefineTypeExtended(Provider, objectGetType(), 0,
  gImplementInterfaceStr("completionProviderGetType()", "providerIfaceInit"))

#template typeProvider(): untyped = providerGetType()

proc provider(obj: GObject): Provider =
  gTypeCheckInstanceCast(obj, providerGetType(), ProviderObj)

# proc isProvider(obj: untyped): bool =
#   gTypeCheckInstanceType(obj, typeProvider)

proc providerGetName(provider: CompletionProvider): cstring {.cdecl.} =
  dup(provider(provider).name) # we really need the provider() cast here and below...

proc providerGetPriority(provider: CompletionProvider): cint {.cdecl.} =
  provider(provider).priority

proc providerGetIcon(provider: CompletionProvider): GdkPixbuf =
  let tp  = provider(provider)
  var error: GError
  if tp.icon.isNil:
    let theme = gtk.iconThemeGetDefault()
    tp.icon = gtk.loadIcon(theme, "dialog-information", 16, cast[IconLookupFlags](0), error)
  return tp.icon

## returns dirtypath or nil for failure
proc saveDirty(filepath: string; text: cstring): string =
  var gerror: GError
  var stream: GFileIOStream
  let filename = filepath.splitFile[1] & "XXXXXX.nim"
  let gfile = newFile(filename, stream, gerror)
  if gfile.isNil:
    #error(gerror.message)
    #error("Can't create nimsuggest dirty file")
    return
  let h = gfile.path
  result = $h
  free(h)
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.PRIVATE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  if not res:
    #error(gerror.message)
    result = nil

type
  NimEdApp = ptr NimEdAppObj
  NimEdAppObj = object of ApplicationObj
    lastActiveView: NimView

  NimEdAppClass = ptr NimEdAppClassObj
  NimEdAppClassObj = object of ApplicationClassObj

gDefineType(NimEdApp, gtk.applicationGetType())

proc nimEdAppInit(self: NimEdApp) = discard

template typeNimEdApp(): untyped = nimEdAppGetType()

proc nimEdApp(obj: GPointer): NimEdApp =
  gTypeCheckInstanceCast(obj, nimEdAppGetType(), NimEdAppObj)

# proc isNimEdApp(obj: GPointer): GBoolean =
#   gTypeCheckInstanceType(obj, typeNimEdApp)

proc lastActiveViewFromWidget(w: Widget): NimView =
  nimEdApp(gtk.window(w.toplevel).application).lastActiveView

proc goto(view: NimView; line, column: int)

proc onSearchentrySearchChanged(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  let win = nimEdAppWindow(entry.toplevel)
  var view: NimView = entry.lastActiveViewFromWidget
  let text = $entry.text
  var line: int
  #if scanf(text, ":$i$.", line):# and line >= 0: # will work for Nim > 0.14.2 only
  #  echo "mach", line
  if text[0] == ':' and text.len < 9: # avoid overflow trap
    let parsed = parseInt(text, line, start = 1)
    if parsed > 0 and parsed + 1 == text.len:# and line >= 0:
      goto(view, line - 1, 0)
      return
  for i in LogLevel:
    if text == "--" & $i:
      win.loglevel = i
      return
  view.searchSettings.setSearchText(entry.text)
  let buffer = view.buffer
  var startIter, endIter, iter: TextIterObj
  buffer.getIterAtMark(iter, buffer.insert)
  if view.searchContext.forward(iter, startIter, endIter):
    discard view.scrollToIter(startIter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)

proc removeMessageTimeout(p: GPointer): GBoolean {.cdecl.} =
  let win = nimEdAppWindow(p)
  win.statusbar.remove(win.statusID1, win.messageID)
  win.timeoutEventSourceID = 0
  return G_SOURCE_REMOVE

proc showmsg(win: NimEdAppWindow; t: cstring) =
  if win.timeoutEventSourceID != 0:
    discard sourceRemove(win.timeoutEventSourceID)
    win.timeoutEventSourceID = 0
    win.statusbar.remove(win.statusID1, win.messageID)
  win.messageID = win.statusbar.push(win.statusID1, t)
  win.timeoutEventSourceID = timeoutAddSeconds(7, removeMessageTimeout, win)

# 1.0. >> abs, int, biggestInt, ...
# current problem is, that we may get a lot of templates, see
# http://forum.nim-lang.org/t/2258#13769
# so we allow a few, but supress templates when too many...
# as docs tell us, we have to always call addProposals() with finished = true
proc getMethods(completionProvider: CompletionProvider; context: CompletionContext) {.cdecl.} =
  var startIter, endIter, iter: TextIterObj
  var proposals, filteredProposals: GList
  var templates = 0
  if context.activation == CompletionActivation.NONE:
    doassert false # should never happen
  if context.activation == CompletionActivation.INTERACTIVE: # happens when RETURN key is pressed -- how to avoid?
    addProposals(context, completionProvider, proposals, finished = true) # clean exit
    # echo "CompletionActivation.INTERACTIVE"
    return
  if context.activation == CompletionActivation.USER_REQUESTED:
    if not (context.getIter(iter) and iter.backwardChar and iter.getChar == utf8GetChar(".")):
      addProposals(context, completionProvider, proposals, finished = true) # clean exit
      #echo "fast return"
      return
    else:
      let provider = provider(completionProvider)
      let view: NimView = provider.win.lastActiveViewFromWidget
      let buffer= view.buffer
      if buffer.path.isNil or not buffer.path.hasSuffix(".nim") or nsProcess.isNil: # when editor is started without a nim file
        showmsg(provider.win, "File is still unsaved or has no .nim suffix -- action ignored.")
        addProposals(context, completionProvider, proposals, finished = true)
        return
      buffer.getStartIter(startIter)
      buffer.getEndIter(endIter)
      let text = buffer.text(startIter, endIter, includeHiddenChars = true)
      let filepath: string = $view.buffer.path
      let dirtypath = saveDirty(filepath, text)
      free(text)
      if dirtypath != nil:
        let socket = newSocket()
        let ln = iter.line + 1
        let col = iter.lineIndex + 1#2 # 1 works too
        socket.connect("localhost", NSPort)
        socket.send("sug " & filepath & ";" & dirtypath & ":" & $ln & ":" & $col & "\c\L")
        let icon = providerGetIcon(provider)
        var line = newString(240)
        while true:
          socket.readLine(line)
          if line.len == 0: break
          if line.find('\t') < 0: continue
          var com, sk, sym, sig, path, lin, col, doc, percent: string
          (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
          #echo line#"sig: " & sig
          let unqualifiedSym = substr(sym, sym.find('.') + 1)
          let item: CompletionItem = newCompletionItemWithLabel(sym, unqualifiedSym, icon, sig)
          proposals = prepend(proposals, item)
          if sk == "skTemplate":
            inc(templates)
          else:
            filteredProposals = prepend(filteredProposals, item)
        socket.close
        freeFull(provider.proposals, objectUnref)
        free(provider.filteredProposals)
        provider.filteredProposals = filteredProposals
        provider.proposals = proposals
  if templates > 3:
    proposals = filteredProposals
  addProposals(context, completionProvider, proposals, finished = true)

proc providerIfaceInit(iface: CompletionProviderIface) =
  iface.getName = providerGetName
  iface.populate = getMethods
  iface.getPriority = providerGetPriority

proc providerDispose(obj: GObject) {.cdecl.} =
  var self = provider(obj)
  freeFull(self.proposals, objectUnref)
  free(self.filteredProposals)
  self.proposals = nil
  self.filteredProposals = nil
  var hhh = gobject(self.icon)
  clearObject(hhh)
  self.icon = nil
  gObjectClass(providerParentClass).dispose(obj)

proc providerFinalize(gobject: GObject) {.cdecl.} =
  let self = provider(gobject)
  free(self.name)
  self.name = nil
  gObjectClass(providerParentClass).finalize(gobject)

proc providerClassInit(klass: ProviderClass) =
  klass.dispose = providerDispose
  klass.finalize = providerFinalize

proc providerInit(self: Provider) = discard

proc initCompletion(view: NimView; completion: gtksource.Completion; win: NimEdAppWindow) {.cdecl.} =
  var error: GError
  let wordProvider = newCompletionWords(name = nil, icon = nil)
  register(wordProvider, view.buffer)
  discard addProvider(completion, wordProvider, error)
  objectSet(wordProvider, "priority", 10, nil)
  objectSet(wordProvider, "activation", CompletionActivation.USER_REQUESTED, nil)
  let nsProvider = provider(newObject(providerGetType(), nil))
  nsProvider.priority = 5
  nsProvider.win = win
  nsProvider.name = dup("Nim suggests:")
  discard addProvider(completion, nsProvider, error)

proc nimEdAppWindowSmartOpen(win: NimEdAppWindow; file: gio.GFile): NimView {.discardable.}

proc initSuggest(win: NimEdAppWindow; path: string)

proc open(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let dialog = newFileChooserDialog("Open File", nimEdAppWindow(app), FileChooserAction.OPEN,
                                    "Cancel", ResponseType.CANCEL, "Open", ResponseType.ACCEPT, nil);
  if dialog.run == ResponseType.ACCEPT.ord:
    let filename = fileChooser(dialog).filename
    if nsProcess.isNil:
      initSuggest(nimEdAppWindow(app), $filename)
    let file: GFile = newFileForPath(filename)
    nimEdAppWindowSmartOpen(nimEdAppWindow(app), file)
    objectUnref(file)
    free(filename)
  dialog.destroy

proc fixUnnamed(buffer: NimViewBuffer; name: cstring) =
  let language: gtksource.Language = languageManagerGetDefault().guessLanguage(name, nil)
  buffer.setLanguage(language)

proc saveBuffer(buffer: NimViewBuffer) =
  var startIter, endIter: TextIterObj
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  var gerror: GError
  let gfile: GFile = newFileForPath(buffer.path) # never fails
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.NONE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  if res:
    buffer.modified = false

proc saveAsAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  var dialog = newFileChooserDialog("Save File", nimEdAppWindow(app), FileChooserAction.SAVE,
                                    "Cancel", ResponseType.CANCEL, "SAVE", ResponseType.ACCEPT, nil);
  if dialog.run == ResponseType.ACCEPT.ord:
    free(view.buffer.path)
    view.buffer.path = fileChooser(dialog).filename
    view.label.text = glib.basename(view.buffer.path)
    saveBuffer(view.buffer)
    fixUnnamed(view.buffer, view.label.text)
    if nsProcess.isNil:
      initSuggest(nimEdAppWindow(app), $view.buffer.path)
  dialog.destroy

proc save(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  let buffer = view.buffer
  if buffer.path.isNil or buffer.path == "Unsaved":
    saveAsAction(action, parameter, app)
  else:
    saveBuffer(buffer)

proc markTargetAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(win.getApplication).lastActiveView
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  win.target = notebook

proc findViewWithBuffer(views: GList; buffer: NimViewBuffer): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer == buffer:
      return nimView(p.data)
    p = p.next

proc closetabAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  #let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  notebook.remove(scrolled)

proc showErrorTooltip(w: Widget; x, y: cint; keyboardMode: GBoolean; tooltip: Tooltip; data: GPointer): GBoolean {.cdecl.} =
  var bx, by, trailing: cint
  var iter: TextIterObj
  if keyboardMode: return GFALSE
  let view: NimView = nimView(w)
  view.windowToBufferCoords(TextWindowType.Widget, x, y, bx, by)
  let table: TextTagTable = view.buffer.tagTable
  var tag: TextTag = table.lookup(ErrorTagName)
  assert(tag != nil)
  discard view.getIterAtPosition(iter, trailing, bx, by)
  if iter.hasTag(tag):
    var e: ptr NimViewError
    var p: GList = view.errors
    while p != nil:
      e = cast[ptr NimViewError](p.data)
      tag = table.lookup($e.id)
      if tag != nil:
        if iter.hasTag(tag):
          tooltip.text = e.gs.str
          return GTRUE
      p = p.next
  return GFALSE

proc onGrabFocus(widget: Widget; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  let view = nimView(widget)
  win.headerbar.subtitle = view.buffer.path
  win.headerbar.title = view.label.text
  nimEdApp(gtk.window(widget.toplevel).application).lastActiveView = view

proc closeTab(button: Button; userData: GPointer) {.cdecl.} =
  #let win = nimEdAppWindow(button.toplevel)
  let notebook: Notebook = notebook(button.parent.parent)
  let scrolled: ScrolledWindow = scrolledWindow(userData)
  notebook.remove(scrolled)

proc onBufferModified(textBuffer: TextBuffer; userData: GPointer) {.cdecl.} =
  var s: string
  let view = nimView(userdata)
  let win = nimEdAppWindow(view.toplevel)
  let l: Label = view.label
  let h = nimViewBuffer(textBuffer).path
  s = if h.isNil: "Unsaved" else: ($h).extractFilename
  #if h.isNil:
  #  s = "Unsaved"
  #else:
  #  s = ($h).extractFilename
  if textBuffer.modified:
    s.insert("*")
  l.text = s
  win.headerbar.title = s

proc advanceErrorWord(ch: GUnichar, userdata: Gpointer): GBoolean {.cdecl.} = gNot(isalnum(ch))

proc removeMarks(view: NimView) =
  var startIter, endIter: TextIterObj
  let buffer = view.buffer
  view.freeErrors
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  buffer.removeTagByName(ErrorTagName, startIter, endIter)
  for i in 0 .. MaxErrorTags:
    buffer.removeTagByName($i, startIter, endIter)
  buffer.removeSourceMarks(startIter, endIter, NullStr)
  view.showLinemarks = false

proc setErrorAttr(view: NimView) =
  var attrs = newMarkAttributes()
  var color = RGBAObj(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.3)
  attrs.background = color
  attrs.iconName = "list-remove"
  view.setMarkAttributes(ErrorTagName, attrs, priority = 1)
  objectUnref(attrs)

proc setErrorMark(view: NimView; ln, cn: int) =
  var iter: TextIterObj
  let buffer = view.buffer
  buffer.getIterAtLineIndex(iter, ln.cint, cn.cint)
  discard iter.backwardLine
  if ln > 0:
    discard iter.forwardLine
  discard buffer.createSourceMark(NullStr, ErrorTagName, iter)

# can not remember why we did it in this way...
proc setErrorTag(view: NimView; ln, cn, id: int) =
  var startIter, endIter, iter: TextIterObj
  let buffer = view.buffer
  buffer.getIterAtLineIndex(startIter, ln.cint, cn.cint)
  let tag: TextTag = buffer.tagTable.lookup(ErrorTagName)
  assert(tag != nil)
  discard startiter.backwardChar # separate adjanced error tags
  if startIter.hasTag(tag):
    discard startIter.forwardToTagToggle(tag) # same as forwardChar?
  discard startiter.forwardChar
  endIter = startIter
  iter = startIter
  discard iter.forwardToLineEnd
  discard endIter.forwardChar # check
  discard endIter.forwardFindChar(advanceErrorWord, userData = nil, limit = iter)
  buffer.applyTag(tag, startIter, endIter)
  buffer.applyTagByName($id, startIter, endIter)

# settings parameter is unused
proc loadContent(file: GFile; buffer: NimViewBuffer; settings: GSettings) =
  var
    contents: cstring
    length: Gsize
    error: GError
  if file != nil and loadContents(file, cancellable = nil, contents, length, etagOut = nil, error):
    buffer.setText(contents, length.cint)
    free(contents)
    buffer.setPath(file.path) # no free() needed, setPath is using the string
  buffer.modified = false

proc getMapping(value: var GValueObj; variant: GVariant; userData: GPointer): GBoolean {.cdecl.} =
  let b = variant.getBoolean
  setEnum(value, b.cint)
  return GTRUE

proc updateLabelOccurrences(label: Label; pspec: GParamSpec; userData: GPointer) {.cdecl.} =
  var selectStart, selectEnd: TextIterObj
  var text: cstring
  let context = searchContext(userData)
  let buffer = context.buffer
  let occurrencesCount = context.getOccurrencesCount
  discard buffer.getSelectionBounds(selectStart, selectEnd)
  let occurrencePos = context.getOccurrencePosition(selectStart, selectEnd)
  if occurrencesCount <= 0:
    text = dup("")
  elif occurrencePos == -1:
    text = dupPrintf("%d occurrences", occurrencesCount)
  else:
    text = dupPrintf("%d of %d", occurrencePos, occurrencesCount)
  label.text = text
  free(text)

proc findLogView(views: GList): NimView =
  var p: GList = views
  while p != nil:
    let buffer = nimView(p.data).buffer
    if buffer.path == "log.txt":
      return nimView(p.data)
    elif buffer.path.isNil and buffer.charCount == 0:
      buffer.path = "log.txt"
      return nimView(p.data)
    p = p.next

proc log(win: NimEdAppWindow; msg: cstring; level = LogLevel.log) =
  if level.ord < win.logLevel.ord: return
  let view = findLogView(win.views)
  if not view.isNil:
    let buffer = view.buffer
    var iter: TextIterObj
    buffer.getEndIter(iter)
    buffer.insert(iter, msg, -1)
    buffer.insert(iter, "\n", -1)
    discard view.scrollToIter(iter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)

proc onDestroyNimView(obj: Widget; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  let app = nimEdApp(win.getApplication)
  let v = nimView(obj)
  let b = v.buffer
  win.views = win.views.remove(v)
  if not app.isNil: # yes this happens for last view!
    if app.lastActiveView == obj:
      app.lastActiveView = if win.views.isNil: nil else: nimView(win.views.data)
  if findViewWithBuffer(win.views, b).isNil:
    win.buffers = win.buffers.remove(b)

proc onCursorMoved(obj: GObject; pspec: GParamSpec; userData: Gpointer) {.cdecl.} =
  if nsProcess.isNil: return
  let win = nimEdAppWindow(userData)
  let buffer = nimViewBuffer(obj)
  if buffer.path.isNil or not buffer.path.hasSuffix(".nim"): return
  var last {.global.}: cstring = nil
  var lastline {.global.}: cint = -1
  var text: cstring
  var msg: StatusMsg
  var startIter, endIter, iter: TextIterObj
  #obj.signalHandlerBlock(buffer.handlerID) # this will crash for fast backspace, even with gSignalConnectAfter()
  #while gtk.eventsPending(): echo "mainIteration"; discard gtk.mainIteration()
  #obj.signalHandlerUnblock(buffer.handlerID)
  buffer.getIterAtMark(iter, buffer.insert)
  text = dupPrintf("%d, %d", iter.line + 1, iter.lineIndex)
  win.statuslabel.text = text
  free(text)
  text = nil
  msg.line = iter.line + 1
  msg.column = iter.lineIndex# + 1 # we need this + 1
  if not iter.insideWord or iter.getBytesInLine < 3:
    msg.filepath = ""
    channel.send(msg)
    lastline = -1
    return
  startIter = iter
  endIter = iter
  if not startIter.startsWord: discard startIter.backwardWordStart
  if not endIter.endsWord: discard endIter.forwardWordEnd
  text = getText(startIter, endIter)
  if iter.line == lastline and text == last:
    free(text)
    return
  lastline = iter.line
  free(last)
  last = text
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  text = buffer.text(startIter, endIter, includeHiddenChars = true)
  msg.filepath = $buffer.path
  msg.dirtypath = saveDirty(msg.filepath, text)
  free(text)
  if not msg.dirtyPath.isNil:
    channel.send(msg)

proc addViewToNotebook(win: NimEdAppWindow; notebook: Notebook; file: gio.GFile = nil, buf: NimViewBuffer = nil): NimView =
  var
    buffer: NimViewBuffer
    view: NimView
    name: cstring
  if not file.isNil:
    name = file.basename # we have to call free!
  let scrolled: ScrolledWindow = newScrolledWindow(nil, nil)
  scrolled.hexpand = true
  scrolled.vexpand = true
  let language: gtksource.Language = if file.isNil: nil else: languageManagerGetDefault().guessLanguage(name, nil)
  buffer = if buf.isNil: newNimViewBuffer(language) else: buf
  view = newNimView(buffer)
  win.views = glib.prepend(win.views, view)
  setErrorAttr(view)
  discard gSignalConnect(view, "destroy", gCallback(onDestroyNimView), win)
  `bind`(win.settings, "showlinenumbers", view, "show-line-numbers", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "showrightmargin", view, "show-right-margin", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "spacetabs", view, "insert-spaces-instead-of-tabs", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "smartbackspace", view, "smart-backspace", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "linespace", view, "pixels-below-lines", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "tabwidth", view, "tab-width", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "rightmargin", view, "right-margin-position", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "indentwidth", view, "indent-width", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "scrollbaroverlay", scrolled, "overlay-scrolling", gio.GSettingsBindFlags.GET)
  bindWithMapping(win.settings, "scrollbarautomatic", scrolled, "vscrollbar-policy", gio.GSettingsBindFlags.GET, getMapping, nil, nil, nil)
  bindWithMapping(win.settings, "scrollbarautomatic", scrolled, "hscrollbar-policy", gio.GSettingsBindFlags.GET, getMapping, nil, nil, nil)
  let fontDesc = fontDescriptionFromString(getString(win.settings, "font"))
  view.modifyFont(fontDesc)
  free(fontDesc)
  if buf.isNil:
    win.buffers = glib.prepend(win.buffers, buffer)
    discard buffer.createTag(ErrorTagName, "underline", pango.Underline.Error, nil)
    if win.searchMatchBg != nil and win.searchMatchFg != nil:
      discard buffer.createTag(HighlightTagName, "background", win.searchMatchBg, "foreground", win.searchMatchFg, nil)
    elif win.searchMatchBg != nil:
      discard buffer.createTag(HighlightTagName, "background", win.searchMatchBg, nil)
    elif win.searchMatchFg != nil:
      discard buffer.createTag(HighlightTagName, "foreground", win.searchMatchFg, nil)
    else:
      discard buffer.createTag(HighlightTagName, "background", "#cc0", "foreground", "#000", nil)
    for i in 0 .. MaxErrorTags:
      discard buffer.createTag($i, nil)
    if not file.isNil:
      buffer.setPath(file.path)
  view.hasTooltip = true
  discard gSignalConnect(view, "query-tooltip", gCallback(showErrorTooltip), nil)
  discard gSignalConnect(view, "grab_focus", gCallback(onGrabFocus), win)
  let completion: Completion = getCompletion(view)
  initCompletion(view, completion, win)
  scrolled.add(view)
  scrolled.showAll # we need this
  # from 3.20 gedit-documents-panel.c
  let closeButton = button(newObject(typeButton, "relief", ReliefStyle.NONE, "focus-on-click", false, nil))
  let context = closeButton.getStyleContext
  context.addClass("flat")
  context.addClass("small-button")
  let icon = newThemedIconWithDefaultFallbacks("window-close-symbolic")
  let image: Image = newImage(icon, IconSize.MENU)
  objectUnref(icon)
  closeButton.add(image)
  discard gSignalConnect(closeButton, "clicked", gCallback(closeTab), scrolled)
  let label = newLabel(if file.isNil: "Unsaved".cstring else: name)
  view.label = label
  label.ellipsize = pango.EllipsizeMode.END
  label.halign = Align.START
  label.valign = Align.CENTER
  discard gSignalConnect(buffer, "modified-changed", gCallback(onBufferModified), view)
  if buf.isNil:
    buffer.handlerID = gSignalConnect(buffer, "notify::cursor-position", gCallback(onCursorMoved), win)
  let box = newBox(Orientation.HORIZONTAL, spacing = 0)
  box.packStart(label, expand = true, fill = false, padding = 0)
  box.packStart(closeButton, expand = false, fill = false, padding = 0)
  box.showAll # we need this
  let pageNum = notebook.appendPage(scrolled, box)
  notebook.setTabReorderable(scrolled, true)
  notebook.setTabDetachable(scrolled, true)
  notebook.setGroupName("NEdTabGroup")
  notebook.currentPage = pageNum
  notebook.childSet(scrolled, "tab-expand", true, nil)
  if buf.isNil:
    loadContent(file, buffer, win.settings)
    let scheme: cstring  = getString(win.settings, StyleSchemeSettingsID)
    if scheme != nil:
      let manager = styleSchemeManagerGetDefault()
      let style = getScheme(manager, scheme)
      buffer.setStyleScheme(style)
  view.searchSettings = newSearchSettings()
  view.searchContext = newSearchContext(buffer, view.searchSettings)
  `bind`(win.settings, "casesensitive", view.searchSettings, "case-sensitive", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "regexenabled", view.searchSettings, "regex-enabled", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "wraparound", view.searchSettings, "wrap-around", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "wordboundaries", view.searchSettings, "at-word-boundaries", gio.GSettingsBindFlags.GET)
  discard gSignalConnectSwapped(view.searchContext, "notify::occurrences-count", gCallback(updateLabelOccurrences), win.searchcountlabel)
  free(name)
  let app = nimEdApp(win.getApplication)
  if app.lastActiveView.isNil:
    app.lastActiveView = view
    var iter: TextIterObj
    buffer.getIterAtLineIndex(iter, 0, 0) # put cursor somewhere, so search entry works from the beginning
    buffer.placeCursor(iter)
  return view

proc pageNumChanged(notebook: Notebook; child: Widget; pageNum: cuint; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  win.statuslabel.text = ""
  notebook.showTabs = notebook.getNPages > 1 or getBoolean(win.settings, "showtabs")
  if notebook.nPages == 0:
    let parent = container(notebook.parent)
    if not isPaned(parent):
      let h = win.getApplication
      if h != nil: # can it be nil?
        quit(h)
      return
    var c1 = paned(parent).child1
    var c2 = paned(parent).child2
    if notebook == c1: swap(c1, c2)
    discard c1.objectRef
    parent.remove(c1)
    parent.remove(c2)
    let pp = container(parent.parent)
    pp.remove(parent)
    pp.add(c1)
    if isPaned(pp):
      pp.childSet(c1, "shrink", false, nil)
    c1.objectUnref

proc getMappingTabs(value: var GValueObj; variant: GVariant; userData: GPointer): GBoolean {.cdecl.} =
  let notebook = notebook(userData)
  let b = variant.getBoolean or notebook.getNPages > 1
  setBoolean(value, b)
  return GTRUE

proc switchPage(notebook: Notebook; page: Widget; pageNum: cuint; userData: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  win.statuslabel.text = ""
  win.showmsg1("")

proc split(app: Gpointer; o: Orientation) =
  let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(win.getApplication).lastActiveView
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  var allocation: AllocationObj
  notebook.getAllocation(allocation)
  let posi = (if o == Orientation.HORIZONTAL: allocation.width else: allocation.height) div 2
  let parent = container(notebook.parent)
  discard notebook.objectRef
  parent.remove(notebook)
  let paned: Paned = newPaned(o)
  paned.pack1(notebook, resize = true, shrink = false)
  let newbook = newNotebook()
  discard gSignalConnect(newbook, "page-added", gCallback(pageNumChanged), win)
  discard gSignalConnect(newbook, "page-removed", gCallback(pageNumChanged), win)
  discard gSignalConnect(newbook, "switch-page", gCallback(switchPage), win)
  bindWithMapping(win.settings, "showtabs", newbook, "show-tabs", gio.GSettingsBindFlags.GET, getMappingTabs, nil, newbook, nil)
  discard addViewToNotebook(win = nimEdAppWindow(app), notebook = newbook, file = nil)
  paned.pack2(newbook, resize = true, shrink = false)
  paned.position = posi
  parent.add(paned)
  parent.show_all
  notebook.objectUnref

proc hsplit(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  split(app, Orientation.HORIZONTAL)

proc vsplit(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  split(app, Orientation.VERTICAL)

var winAppEntries = [
  gio.GActionEntryObj(name: "hsplit", activate: hsplit, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "vsplit", activate: vsplit, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "save", activate: save, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "closetabAction", activate: closetabAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "saveAsAction", activate: saveAsAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "markTargetAction", activate: markTargetAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "open", activate: ned.open, parameterType: nil, state: nil, changeState: nil)]

proc settingsChanged(settings: gio.GSettings; key: cstring; win: NimEdAppWindow) {.cdecl.} =
  let manager = styleSchemeManagerGetDefault()
  let style = getScheme(manager, getString(settings, key))
  if style != nil:
    var p: GList = win.buffers
    while p != nil:
      gtksource.buffer(p.data).setStyleScheme(style)
      p = p.next

proc fontSettingChanged(settings: gio.GSettings; key: cstring; win: NimEdAppWindow) {.cdecl.} =
  let fontDesc = fontDescriptionFromString(getString(win.settings, key))
  var p: GList = win.views
  while p != nil:
    nimView(p.data).modifyFont(fontDesc)
    p = p.next
  free(fontDesc);

proc nimEdAppWindowInit(self: NimEdAppWindow) =
  initTemplate(self)
  self.settings = newSettings("org.gtk.ned")
  discard gSignalConnect(self.settings, "changed::styleschemesettingsid",
                   gCallback(settingsChanged), self)
  discard gSignalConnect(self.settings, "changed::fontsettingsid",
                   gCallback(fontSettingChanged), self)
  let builder = newBuilder(resourcePath = "/org/gtk/ned/gears-menu.ui")
  let menu = gMenuModel(getObject(builder, "menu"))
  setMenuModel(self.gears, menu)
  objectUnref(builder)
  addActionEntries(gio.gActionMap(self), addr winAppEntries[0], cint(len(winAppEntries)), self)
  objectSet(settingsGetDefault(), "gtk-shell-shows-app-menu", true, nil)
  setShowMenubar(self, true)

proc nimEdAppWindowDispose(obj: GObject) {.cdecl.} =
  let win = nimEdAppWindow(obj)
  if win.timeoutEventSourceID != 0:
    discard sourceRemove(win.timeoutEventSourceID)
    win.timeoutEventSourceID = 0
  if win.msgThreadSourceID != 0:
    discard sourceRemove(win.msgThreadSourceID)
    win.msgThreadSourceID = 0
  gObjectClass(nimEdAppWindowParentClass).dispose(obj)

proc nimEdAppWindowClassInit(klass: NimEdAppWindowClass) =
  klass.dispose = nimEdAppWindowDispose
  setTemplateFromResource(klass, "/org/gtk/ned/window.ui")
  widgetClassBindTemplateChild(klass, NimEdAppWindow, gears)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, searchentry)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, entry)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, searchcountlabel)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, statuslabel)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, headerbar)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, statusbar)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, savebutton)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, openbutton)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, grid)

proc nimEdAppWindowNew(app: NimEdApp): NimEdAppWindow =
  nimEdAppWindow(newObject(typeNimEdAppWindow, "application", app, nil))

# Here we use a type with private component. This is mainly to test and
# demonstrate that it works. Generally putting new fields into
# NedAppPrefsObj as done for the types above is simpler.
type
  NedAppPrefs = ptr NedAppPrefsObj
  NedAppPrefsObj = object of gtk.DialogObj

  NedAppPrefsClass = ptr NedAppPrefsClassObj
  NedAppPrefsClassObj = object of gtk.DialogClassObj

  NedAppPrefsPrivate = ptr NedAppPrefsPrivateObj
  NedAppPrefsPrivateObj = object
    settings: gio.GSettings
    font: gtk.Widget
    showtabs: gtk.Widget
    showlinenumbers: gtk.Widget
    showrightmargin: gtk.Widget
    spacetabs: gtk.Widget
    smartbackspace: gtk.Widget
    linespace: gtk.Widget
    tabwidth: gtk.Widget
    rightmargin: gtk.Widget
    indentwidth: gtk.Widget
    casesensitive: gtk.Widget
    regexenabled: gtk.Widget
    wraparound: gtk.Widget
    wordboundaries: gtk.Widget
    reusedefinition: gtk.Widget
    scrollbarautomatic: gtk.Widget
    scrollbaroverlay: gtk.Widget
    style: gtk.Widget
    styleScheme: gtksource.StyleScheme

gDefineTypeWithPrivate(NedAppPrefs, dialogGetType())

template typeNedAppPrefs(): untyped = nedAppPrefsGetType()

proc nedAppPrefs(obj: GObject): NedAppPrefs =
  gTypeCheckInstanceCast(obj, nedAppPrefsGetType(), NedAppPrefsObj)

# proc isNedAppPrefs(obj: GObject): GBoolean =
#   gTypeCheckInstanceType(obj, typeNedAppPrefs)

proc styleSchemeChanged(sscb: StyleSchemeChooserButton, pspec: GParamSpec, settings: gio.GSettings) {.cdecl.} =
  discard settings.setString(StyleSchemeSettingsID, styleSchemeChooser(sscb).getStyleScheme.id)

proc fontChanged(fbcb: FontButton, pspec: GParamSpec, settings: gio.GSettings) {.cdecl.} =
  discard settings.setString(FontSettingsID, fontButton(fbcb).getFontName)

proc nedAppPrefsInit(self: NedAppPrefs) =
  let priv: NedAppPrefsPrivate = nedAppPrefsGetInstancePrivate(self)
  initTemplate(self)
  priv.settings = newSettings("org.gtk.ned")
  `bind`(priv.settings, "font", priv.font, "font", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, StyleSchemeSettingsID, priv.style, "label", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "showtabs", priv.showtabs, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "reusedefinition", priv.reusedefinition, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "showlinenumbers", priv.showlinenumbers, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "showrightmargin", priv.showrightmargin, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "spacetabs", priv.spacetabs, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "smartbackspace", priv.smartbackspace, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "linespace", priv.linespace, "value", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "tabwidth", priv.tabwidth, "value", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "rightmargin", priv.rightmargin, "value", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "indentwidth", priv.indentwidth, "value", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "casesensitive", priv.casesensitive, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "regexenabled", priv.regexenabled, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "wordboundaries", priv.wordboundaries, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "wraparound", priv.wraparound, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "scrollbaroverlay", priv.scrollbaroverlay, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "scrollbarautomatic", priv.scrollbarautomatic, "active", gio.GSettingsBindFlags.DEFAULT)
  discard gSignalConnect(priv.style, "notify::style-scheme", gCallback(styleSchemeChanged), priv.settings)
  discard gSignalConnect(priv.font, "notify::font", gCallback(fontChanged), priv.settings)

proc nedAppPrefsDispose(obj: gobject.GObject) {.cdecl.} =
  var priv: NedAppPrefsPrivate = nedAppPrefsGetInstancePrivate(nedAppPrefs(obj))
  var hhh = gobject(priv.settings)
  clearObject(hhh)
  priv.settings = nil # https://github.com/nim-lang/Nim/issues/3449
  gObjectClass(nedAppPrefsParentClass).dispose(obj)

proc nedAppPrefsClassInit(klass: NedAppPrefsClass) =
  klass.dispose = nedAppPrefsDispose
  setTemplateFromResource(klass, "/org/gtk/ned/prefs.ui")
  # we may replace function call above by this code to avoid use of resource:
  #var
  #  buffer: cstring
  #  length: gsize
  #  error: glib.GError = nil
  #  gbytes: glib.GBytes = nil
  #if not gFileGetContents("prefs.ui", buffer, length, error):
  #  gCritical("Unable to load prefs.ui \'%s\': %s", gObjectClassName(klass), error.message)
  #  free(error)
  #  return
  #gbytes = gBytesNew(buffer, length)
  #setTemplate(klass, gbytes)
  #gFree(buffer)
  # done
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, font)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, showtabs)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, reusedefinition)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, showlinenumbers)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, showrightmargin)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, spacetabs)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, smartbackspace)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, linespace)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, tabwidth)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, rightmargin)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, indentwidth)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, casesensitive)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, regexenabled)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, wordboundaries)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, wraparound)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, scrollbaroverlay)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, scrollbarautomatic)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, style)

proc nedAppPrefsNew(win: NimEdAppWindow): NedAppPrefs =
  nedAppPrefs(newObject(typeNedAppPrefs, "transient-for", win, "use-header-bar", true, nil))

proc preferencesActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win: gtk.Window = getActiveWindow(application(app))
  let prefs: NedAppPrefs = nedAppPrefsNew(nimEdAppWindow(win))
  present(prefs)

#proc setVisibleChild(nb: Notebook; c: Widget): bool =
#  var i: cint = 0
#  var w: Widget
#  while true:
#    w = nb.getNthPage(i)
#    if w.isNil: break
#    if w == c:
#      nb.setCurrentPage(i)
#      return true
#    inc(i)
#  return false

proc findViewWithPath(views: GList; path: cstring): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer.path == path:
      return nimView(p.data)
    p = p.next

proc findViewWithDef(views: GList): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer.defView:
      return nimView(p.data)
    p = p.next

proc nimEdAppWindowDefOpen(win: NimEdAppWindow; file: gio.GFile): NimView =
  var
    view: NimView
    notebook: Notebook
  let path = file.path
  view = findViewWithPath(win.views, path)
  free(path)
  if not view.isNil:
    return view
  if win.settings.getBoolean("reusedefinition"):
    view = findViewWithDef(win.views)
  if view.isNil:
    view = findViewWithPath(win.views, nil) # "Unused" buffer
    if view.isNil or view.buffer.charCount > 0:
      view = nil
    else:
      let h = file.basename
      fixUnnamed(view.buffer, h)
      free(h)
  if not view.isNil:
    loadContent(file, view.buffer, win.settings)
  else:
    if win.target.isNil:
      let lastActive: NimView = nimEdApp(win.getApplication).lastActiveView
      notebook = gtk.notebook(lastActive.parent.parent)
    else:
      notebook = win.target
    view = addViewToNotebook(win, notebook, file, buf = nil)
  view.buffer.defView = true
  return view

# support new view for old buffer
proc nimEdAppWindowSmartOpen(win: NimEdAppWindow; file: gio.GFile): NimView =
  var
    view: NimView
    buffer: NimViewBuffer
    notebook: Notebook
  let path = file.path
  view = findViewWithPath(win.views, path)
  free(path)
  if not view.isNil:
    buffer = view.buffer # multi view
  let lastActive: NimView = nimEdApp(win.getApplication).lastActiveView
  if lastActive.isNil:
    let grid: Grid = win.grid
    notebook = gtk.notebook(grid.childAt(0, 1))
  else:
    notebook = gtk.notebook(lastActive.parent.parent)
  if not lastActive.isNil and lastActive.buffer.path.isNil and lastActive.buffer.charCount == 0:
    view = lastActive
    let h = file.basename
    fixUnnamed(view.buffer, h)
    free(h)
    if buffer.isNil:
      loadContent(file, view.buffer, win.settings)
    else:
      view.setBuffer(buffer)
      view.label.text = basename(buffer.path)
      discard gSignalConnect(buffer, "modified-changed", gCallback(onBufferModified), view)
  else:
    view = addViewToNotebook(win, notebook, file, buffer)
  return view

proc quitActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  quit(application(app))

proc winFromApp(app: Gpointer): NimEdAppWindow =
  let windows: GList = application(app).windows
  if not windows.isNil: return nimEdAppWindow(windows.data)

proc gotoMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; forward: bool) =
  let win = nimEdAppWindow(getActiveWindow(application(app)))
  let w = winFromApp(app)
  assert win == w
  if win.isNil: return
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: NimViewBuffer = view.buffer
  var iter: TextIterObj
  buffer.getIterAtMark(iter, buffer.insert)
  win.searchcountlabel.text = ""
  win.entry.text = ""
  let cat = NullStr # UseCat, ErrorCat
  let wrap = win.settings.getBoolean("wraparound")
  if forward:
    if not buffer.forwardIterToSourceMark(iter, cat):
      if wrap: buffer.getStartIter(iter)
  else:
    if not buffer.backwardIterToSourceMark(iter, cat):
      if wrap: buffer.getEndIter(iter)
  buffer.placeCursor(iter)
  discard view.scrollToIter(iter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
  ### view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5) # work also

proc gotoNextMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  gotoMark(action, parameter, app, true)

proc gotoPrevMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  gotoMark(action, parameter, app, false)

proc onmatch(entry: SearchEntry; userData: GPointer; nxt: bool) =
  var iter, matchStart, matchEnd: TextIterObj
  let view = lastActiveViewFromWidget(entry)
  let win = nimEdAppWindow(view.toplevel)
  let buffer = view.buffer
  buffer.getIterAtMark(iter, buffer.insert)
  if (if nxt: view.searchContext.forward(iter, matchStart, matchEnd) else: view.searchContext.backward(iter, matchEnd, matchStart)):
    buffer.selectRange(matchEnd, matchStart)
    view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
    updateLabelOccurrences(win.searchcountlabel, nil, view.searchContext)

proc onnextmatch(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  onmatch(entry, userData, true)

proc onprevmatch(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  onmatch(entry, userData, false)

proc searchentryactivate(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  let view = lastActiveViewFromWidget(entry)
  view.grabFocus

proc activateSearchEntry(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win = winFromApp(app)
  win.searchEntry.grabFocus

proc findNP(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; next: bool) =
  var iter, matchStart, matchEnd: TextIterObj
  let view: NimView = nimEdApp(app).lastActiveView
  let win = nimEdAppWindow(view.toplevel)
  let buffer = view.buffer
  buffer.getIterAtMark(iter, buffer.insert)
  if next and view.searchContext.forward(iter, matchStart, matchEnd) or
    not next and view.searchContext.backward(iter, matchStart, matchEnd):
    if next: # we need this condition -- for this next/prev works
      buffer.selectRange(matchEnd, matchStart)
    else:
      buffer.selectRange(matchStart, matchEnd)
    view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
    updateLabelOccurrences(win.searchcountlabel, nil, view.searchContext)

proc findNext(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  findNP(action, parameter, app, true)

proc findPrev(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  findNP(action, parameter, app, false)

proc find(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var startIter, endIter: TextIterObj
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer = view.buffer
  if not buffer.getSelectionBounds(startIter, endIter):
    buffer.getIterAtMark(startIter, buffer.insert)
    endIter = startIter
    if not startIter.startsWord: discard startIter.backwardWordStart
    if not endIter.endsWord: discard endIter.forwardWordEnd
  let text: cstring = getText(startIter, endIter)
  if text == view.searchSettings.searchText:
    view.searchSettings.setSearchText(nil)
  else:
    view.searchSettings.setSearchText(text)
  free(text)

proc jumpto(view: NimView; line, column: int) =
  var iter: TextIterObj
  let buffer = view.buffer
  buffer.getIterAtLineIndex(iter, line.cint, column.cint)
  buffer.placeCursor(iter)
  view.scrollToMark(buffer.insert, withinMargin = 0.25, useAlign = false, xalign = 0, yalign = 0)

proc goto(view: NimView; line, column: int) =
  var iter: TextIterObj
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  let buffer = view.buffer
  notebook.setCurrentPage(notebook.pageNum(scrolled))
  buffer.getIterAtLineIndex(iter, line.cint, column.cint)
  buffer.placeCursor(iter)
  if view.idleScroll == 0:
    view.idleScroll = idleAdd(GSourceFunc(scrollToCursor), view)

proc pushTm(tm: var ThreadMsg; s: string) =
  if tm.win.msgThreadSourceID == 0:
    free(tm.msg)
    tm.msg = if s.isNil: nil else: dup(s)
    #if s.isNil:
    #  tm.msg = nil
    #else:
    #  tm.msg = dup(s)
    tm.win.msgThreadSourceID = threadsAddIdle(showMsgFromThread, addr tm)

# no logging currently
# https://developer.gnome.org/gdk3/stable/gdk3-Threads.html
# So GTK is not thread safe, and we have to be really careful. We use the threadsAddIdle() function now to show messages.
proc showData(win: NimEdAppWindow) {.thread.} =
  var line = newStringOfCap(240)
  var msg, h: StatusMsg
  var tm: ThreadMsg
  tm.win = win
  sleep(3000) # wait until nimsuggest process is ready -- will not help when editor is started without a Nim file!
  while true:
    msg = channel.recv
    var b: bool
    while true: # only process last message in queue, ignore earlier ones
      (b, h) = channel.tryRecv
      if b:
        if not msg.dirtypath.isNil:
          msg.dirtypath.removeFile
        msg = h
      else:
        break
    if msg.filepath.isNil: break # this is the termination indicator
    if msg.filepath == "":
      pushTm(tm, nil)
      continue
    let socket = newSocket()
    socket.connect("localhost", NSPort)
    var com, sk, sym, sig, path, lin, col, doc, percent: string
    socket.send("def " & msg.filepath & ";" & msg.dirtypath & ":" & $msg.line & ":" & $msg.column & "\c\L")
    sym = nil
    while true:
      socket.readLine(line)
      if line.len == 0: break
      if line.find('\t') < 0: continue
      (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
    if sym.isNil:
      pushTm(tm, nil)
    else:
      if doc == "\"\"": doc = ""
      if path == msg.filepath: path = ""
      pushTm(tm, sk[2..^1] & ' ' & sym & ' ' & sig & " (" & path & ' ' & lin & ", " & col & ") " & doc)
    socket.close
    msg.dirtypath.removeFile
    sleep(500)

proc con(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  if nsProcess.isNil: return
  var lines {.global.}: array[8, string] # yes the 8 should be named
  var linecounter {.global.}: int = 0
  var totallines {.global.}: int
  var startIter, endIter, iter: TextIterObj
  let win = nimEdAppWindow(getActiveWindow(application(app)))
  assert win != nil
  if linecounter == 0:
    let view: NimView = nimEdApp(app).lastActiveView
    let buffer = view.buffer
    if buffer.path.isNil or not buffer.path.hasSuffix(".nim"):
      showmsg(win, "File is still unsaved or has no .nim suffix -- action ignored.")
      return
    buffer.getStartIter(startIter)
    buffer.getEndIter(endIter)
    let text = buffer.text(startIter, endIter, includeHiddenChars = true)
    let filepath: string = $view.buffer.path
    let dirtypath = saveDirty(filepath, text)
    free(text)
    if dirtyPath.isNil: return
    var line = newStringOfCap(240)
    let socket = newSocket()
    socket.connect("localhost", NSPort)
    buffer.getIterAtMark(iter, buffer.insert)
    let ln = iter.line + 1
    let column = iter.lineIndex# + 1
    socket.send("con " & filepath & ";" & dirtypath & ":" & $ln & ":" & $column & "\c\L")
    var com, sk, sym, sig, path, lin, col, doc, percent: string
    while true:
      socket.readLine(line)
      if line.len == 0: break
      if line.find('\t') < 0: continue
      log(win, line, LogLevel.debug) # log only valid lines
      (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
      if linecounter < 8:
        lines[linecounter] = sym & ' ' & sig & ' ' & path & " (" & lin & ", " & col & ")"
        inc linecounter
    socket.close
    dirtypath.removeFile
    totallines = linecounter
  if linecounter > 0:
    let h = if totallines > 1: $(totallines - linecounter + 1) & '/' & $totallines else: ""
    showmsg1(win, lines[totallines - linecounter] & ' ' & h)
    dec linecounter

proc gotoDef(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  if nsProcess.isNil: return
  var startIter, endIter, iter: TextIterObj
  let win = nimEdAppWindow(getActiveWindow(application(app)))
  assert win != nil
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer = view.buffer
  if buffer.path.isNil or not buffer.path.hasSuffix(".nim"):
    showmsg(win, "File is still unsaved or has no .nim suffix -- action ignored.")
    return
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  let filepath: string = $buffer.path
  let dirtypath = saveDirty(filepath, text)
  free(text)
  if dirtyPath.isNil: return
  var line = newStringOfCap(240)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  buffer.getIterAtMark(iter, buffer.insert)
  let ln = iter.line + 1
  let column = iter.lineIndex# + 1
  socket.send("def " & filepath & ";" & dirtypath & ":" & $ln & ":" & $column & "\c\L")
  var com, sk, sym, sig, path, lin, col, doc, percent: string
  while true:
    socket.readLine(line)
    if line.len == 0: break
    if line.find('\t') < 0: continue
    log(win, line, LogLevel.debug) # log only valid lines
    (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
  socket.close
  dirtypath.removeFile
  if path.isNil: return # no result
  let file: GFile = newFileForPath(path)
  let newView = nimEdAppWindowDefOpen(win, file)
  objectUnref(file)
  goto(newView, strutils.parseInt(lin) - 1, strutils.parseInt(col))
  setErrorMark(newView, strutils.parseInt(lin) - 1, 0)
  newView.showLinemarks = true

proc check(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  if nsProcess.isNil: return
  var ln, cn: int
  var nerrors, nwarnings: int
  var startIter, endIter: TextIterObj
  let win = nimEdAppWindow(getActiveWindow(application(app)))
  assert win != nil
  var view: NimView = nimEdApp(app).lastActiveView
  let buffer = view.buffer
  if buffer.path.isNil or not buffer.path.hasSuffix(".nim"):
    showmsg(win, "File is still unsaved or has no .nim suffix -- action ignored.")
    return
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  removeMarks(view)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  let filepath: string = $buffer.path
  let filename = filepath.splitFile[1]
  let dirtypath = saveDirty(filepath, text)
  free(text)
  if dirtyPath.isNil: return
  var line = newStringOfCap(240)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  socket.send("chk " & filepath & ";" & dirtypath & ":1:1\c\L")
  var last: string
  var com, sk, sym, sig, path, lin, col, doc, percent: string
  while true:
    var isError: bool
    socket.readLine(line)
    if line.len == 0: break
    if line == "\c\l" or line == last: continue
    #echo ">>> ", line
    (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t') # sym is empty
    if path != filepath: continue
    if doc[0] == '"' : doc = doc[1 .. ^2]
    doc = doc.replace("\\'", "'")
    doc = doc.replace("\\x0A", "\n")
    log(win, line, LogLevel.debug)
    var show: bool
    if sig == "Error":
      isError = true
      show = true
    else:
      if  nwarnings > MaxErrorTags div 2: continue
      isError = false
      show = sig == "Hint" or sig == "Warning"
    if show:
      last = line
      cn = col.parseInt
      ln = lin.parseInt
      if cn < 0 or ln < 0: continue
      ln -= 1
      let id = view.addError(doc, ln, cn)
      if id > 0:
        if isError:
          inc nerrors
          setErrorMark(view, ln, cn)
          if nerrors == 1:
            buffer.signalHandlerBlock(buffer.handlerID) # without showmsg() is overwritten
            jumpto(view, ln, cn)
            buffer.signalHandlerUnblock(buffer.handlerID)
        else:
          inc nwarnings
        setErrorTag(view, ln, cn, id)
  socket.close
  view.showLinemarks = nerrors > 0
  dirtypath.removeFile
  showmsg(win, "Errors: " & $nerrors & ", Hints/Warnings: " & $nwarnings)

proc useorrep(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; rep: bool) =
  if nsProcess.isNil: return
  let win = winFromApp(app)
  if win.isNil: return
  let entry = win.entry
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer = view.buffer
  if buffer.path.isNil or not buffer.path.hasSuffix(".nim"):
    showmsg(win, "File is still unsaved or has no .nim suffix -- action ignored.")
    return
  let tag: TextTag = buffer.tagTable.lookup(HighlightTagName)
  var startIter, endIter, iter: TextIterObj
  var ln, cn: int
  var fix: string
  var replen {.global.}: int
  var pathcheck: string
  var multiMod: bool
  win.searchEntry.text = "" # may be confusing when not empty
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  iter = startIter
  if buffer.forwardIterToSourceMark(iter, UseCat) or buffer.backwardIterToSourceMark(iter, UseCat): # marks set
    buffer.removeTag(tag, startIter, endIter)
    if rep and replen > 0: # we intent to replace, and have prepaired for that
      let sub = entry.getText
      let subLen = sub.len.cint
      buffer.signalHandlerBlock(buffer.handlerID)
      while buffer.forwardIterToSourceMark(startIter, UseCat) or startIter.isStart:
        iter = startIter
        discard iter.forwardChars(replen.cint)
        buffer.delete(startIter, iter)
        buffer.insert(startIter, sub, subLen)
      buffer.getStartIter(startIter)
      buffer.getEndIter(endIter) # endIter is invalid after delete/insert
      buffer.signalHandlerUnblock(buffer.handlerID)
      showmsg(win, "Replaced by " & $sub)
    buffer.removeSourceMarks(startIter, endIter, UseCat)
    win.searchcountlabel.text = ""
    entry.text = ""
  else: # set marks
    var occurences: int
    buffer.getIterAtMark(iter, buffer.insert)
    if iter.insideWord:
      let text = buffer.text(startIter, endIter, includeHiddenChars = true)
      let filepath: string = $view.buffer.path
      let dirtypath = saveDirty(filepath, text)
      free(text)
      if dirtyPath.isNil: return
      var line = newStringOfCap(240)
      let socket = newSocket()
      socket.connect("localhost", NSPort)
      ln = iter.line + 1
      cn = iter.lineIndex# + 1
      socket.send("use " & filepath & ";" & dirtypath & ":" & $ln & ":" & $cn & "\c\L")
      var com, sk, sym, sig, path, lin, col, doc, percent: string
      while true:
        socket.readLine(line)
        if line.len == 0: break
        if line.find('\t') < 0: continue
        inc(occurences)
        (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
        if pathcheck.isNil: pathcheck = path
        if pathcheck != path: multiMod = true
        cn = parseInt(col)
        ln = parseInt(lin) - 1
        let h = sym.split('.')[^1]
        if fix.isNil: fix = h else: assert fix == h
        buffer.getIterAtLineIndex(startIter, ln.cint, cn.cint)
        endIter = startIter
        discard endIter.forwardChars(fix.len.cint)
        buffer.applyTag(tag, startIter, endIter)
        discard buffer.createSourceMark(NullStr, UseCat, startIter)
      socket.close
      dirtypath.removeFile
    win.searchcountlabel.text = "Usage: " & $occurences
    if rep and occurences > 0: # we intent to replace, so prepair for that
      replen = fix.len
      if entry.textLength == 0:
        entry.text = fix
        showMsg(win, "Caution: Replacement text was empty!")
      else:
        view.searchSettings.setSearchText(entry.getText)
        while gtk.eventsPending(): discard gtk.mainIteration() # wait for
        ln = view.searchContext.getOccurrencesCount
        if ln > 0:
          showMsg(win, "Caution: Replacement exits in file! ($1 times)" % [$ln])
        view.searchSettings.setSearchText("")
      if multiMod: showMsg(win, "Caution: Symbol is used in other modules")
    else:
      replen = -1
      if rep and occurences == 0:
        showMsg(win, "Nothing selected for substitition!")

proc use(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  useorrep(action, parameter, app, false)

proc userep(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  useorrep(action, parameter, app, true)

var appEntries = [
  gio.GActionEntryObj(name: "preferences", activate: preferencesActivated, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "quit", activate: quitActivated, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoDef", activate: gotoDef, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "con", activate: con, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "use", activate: use, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "userep", activate: userep, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "findNext", activate: findNext, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "findPrev", activate: findPrev, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "activateSearchEntry", activate: activateSearchEntry, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoNextMark", activate: gotoNextMark, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoPrevMark", activate: gotoPrevMark, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "find", activate: ned.find, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "check", activate: check, parameterType: nil, state: nil, changeState: nil)]

const
  str000 = """tooltip.background {
    border: none
  }
  """
  #str0 = "tooltip label {text-shadow: none; background-color: transparent; color: rgba($4, $5, $6, 1.0); \n}"
  str0 = "tooltip label {text-shadow: none; background-color: rgba($1, $2, $3, 1); color: rgba($4, $5, $6, 1.0); \n}"
  str00 = "tooltip {text-shadow: none; background-color: rgba($1, $2, $3, 0.5); color: rgba($4, $5, $6, 1.0); \n}"
proc setTTColor(fg, bg: cstring) =
  var rgba_bg: gdk.RGBAObj
  var rgba_fg: gdk.RGBAObj
  if not rgbaParse(rgba_fg, bg): return
  if not rgbaParse(rgba_bg, fg): return
  let str: string = str000 & str0 % map([rgba_bg.red, rgba_bg.green, rgba_bg.blue, rgba_fg.red, rgba_fg.green, rgba_fg.blue], proc(x: cdouble): string = $system.int(x*255)) &
    str00 % map([rgba_bg.red, rgba_bg.green, rgba_bg.blue, rgba_fg.red, rgba_fg.green, rgba_fg.blue], proc(x: cdouble): string = $system.int(x*255))
  var gerror: GError
  let provider: CssProvider = newCssProvider()
  styleContextAddProviderForScreen(gdk.screenGetDefault(), styleProvider(provider), STYLE_PROVIDER_PRIORITY_APPLICATION.cuint)
  discard loadFromData(provider, str, GSize(-1), gerror)
  if gerror != nil:
    #echo gerror.message
    free(gerror)
  objectUnref(provider)

proc nimEdAppStartup(app: gio.GApplication) {.cdecl.} =
  var
    builder: Builder
    appMenu: gio.GMenuModel
    quitAccels = [cstring "<Ctrl>Q", nil]
    gotoDefAccels = [cstring "<Ctrl>W", nil]
    findAccels = [cstring "<Ctrl>F", nil]
    checkAccels = [cstring "<Ctrl>E", nil]
    userepAccels = [cstring "<Ctrl>R", nil]
    useAccels = [cstring "<Ctrl>U", nil]
    conAccels = [cstring "<Ctrl>P", nil]
    activateSearchEntryAccels = [cstring "<Ctrl>slash", nil]
    findNextAccels = [cstring "<Ctrl>G", nil]
    findPrevAccels = [cstring "<Ctrl><Shift>G", nil]
    gotoNextMarkAccels = [cstring "<Ctrl>N", nil]
    gotoPrevMarkAccels = [cstring "<Ctrl><Shift>N", nil]
    my_user_data: int64  = 0xDEADBEE1
  # register the GObject types so builder can use them, see
  # https://mail.gnome.org/archives/gtk-list/2015-March/msg00016.html
  discard viewGetType()
  discard completionInfoGetType()
  discard styleSchemeChooserButtonGetType()
  gApplicationClass(nimEdAppParentClass).startup(app)
  addActionEntries(gio.gActionMap(app), addr appEntries[0], cint(len(appEntries)), app)
  setAccelsForAction(application(app), "app.quit", cast[cstringArray](addr quitAccels))
  setAccelsForAction(application(app), "app.gotoDef", cast[cstringArray](addr gotoDefAccels))
  setAccelsForAction(application(app), "app.con", cast[cstringArray](addr conAccels))
  setAccelsForAction(application(app), "app.use", cast[cstringArray](addr useAccels))
  setAccelsForAction(application(app), "app.userep", cast[cstringArray](addr userepAccels))
  setAccelsForAction(application(app), "app.findNext", cast[cstringArray](addr findNextAccels))
  setAccelsForAction(application(app), "app.findPrev", cast[cstringArray](addr findPrevAccels))
  setAccelsForAction(application(app), "app.activateSearchEntry", cast[cstringArray](addr activateSearchEntryAccels))
  setAccelsForAction(application(app), "app.gotoNextMark", cast[cstringArray](addr gotoNextMarkAccels))
  setAccelsForAction(application(app), "app.gotoPrevMark", cast[cstringArray](addr gotoPrevMarkAccels))
  setAccelsForAction(application(app), "app.find", cast[cstringArray](addr findAccels))
  setAccelsForAction(application(app), "app.check", cast[cstringArray](addr checkAccels))
  builder = newBuilder(resourcePath = "/org/gtk/ned/app-menu.ui")
  appMenu = gMenuModel(getObject(builder, "appmenu"))
  setAppMenu(application(app), appMenu)
  gtk.connectSignals(builder, cast[GPointer](addr my_user_data))
  objectUnref(builder)

proc nimEdAppActivateOrOpen(win: NimEdAppWindow) =
  let notebook: Notebook = newNotebook()
  bindWithMapping(win.settings, "showtabs", notebook, "show-tabs", gio.GSettingsBindFlags.GET, getMappingTabs, nil, notebook, nil)
  discard gSignalConnect(notebook, "page-added", gCallback(pageNumChanged), win)
  discard gSignalConnect(notebook, "page-removed", gCallback(pageNumChanged), win)
  discard gSignalConnect(notebook, "switch-page", gCallback(switchPage), win)
  show(notebook)
  attach(win.grid, notebook, 0, 1, 1, 1)
  let scheme: cstring  = getString(win.settings, StyleSchemeSettingsID)
  let manager = styleSchemeManagerGetDefault()
  let style = getScheme(manager, scheme)
  var st: gtksource.Style = gtksource.getStyle(style, "text")
  if st != nil:
    var fg, bg: cstring
    objectGet(st, "foreground", addr fg, nil)
    objectGet(st, "background", addr bg, nil)
    setTTColor(fg, bg)
    free(fg)
    free(bg)
  st = gtksource.getStyle(style, "search-match")
  if st != nil:
    var fg, bg: cstring
    objectGet(st, "foreground", addr fg, nil) # can be nil if no color scheme is set!
    objectGet(st, "background", addr bg, nil)
    win.searchMatchBg = $bg
    win.searchMatchFg = $fg
    free(fg)
    free(bg)
  win.setDefaultSize(1200, 800)
  win.logLevel = LogLevel.log
  win.statusID1 = win.statusbar.getContextID("StatudID1")
  win.statusID2 = win.statusbar.getContextID("StatudID2")
  present(win)

proc initSuggest(win: NimEdAppWindow; path: string) =
  if nsProcess.isNil and path != nil and path.hasSuffix(".nim"):
    let file: GFile = newFileForPath(path)
    if queryExists(file, nil):
      open(channel)
      let nimBinPath = findExe("nim")
      doAssert(nimBinPath != nil, "we need nim executable!")
      let nimsuggestBinPath = findExe("nimsuggest")
      doAssert(nimsuggestBinPath != nil, "we need nimsuggest executable!")
      let nimPath = nimBinPath.splitFile.dir.parentDir
      nsProcess = startProcess(nimsuggestBinPath, nimPath,
                         ["--v2", "--threads:on", "--port:" & $NSPort, $path],
                         options = {poStdErrToStdOut, poUsePath})
      createThread[NimEdAppWindow](thread, showData, win)
    objectUnref(file)

proc nimEdAppActivate(app: gio.GApplication) {.cdecl.} =
  let win = nimEdAppWindowNew(nimEdApp(app))
  nimEdAppActivateOrOpen(win)
  let notebook = gtk.notebook(win.grid.childAt(0, 1))
  discard addViewToNotebook(win, notebook, file = nil)

proc nimEdAppOpen(app: gio.GApplication; files: gio.GFileArray; nFiles: cint; hint: cstring) {.cdecl.} =
  var
    windows: glib.GList
    win: NimEdAppWindow
  windows = getWindows(application(app))
  if windows.isNil:
    win = nimEdAppWindowNew(nimEdApp(app))
    nimEdAppActivateOrOpen(win)
  else:
    win = nimEdAppWindow(windows.data)
  initSuggest(win, $files[0].path)
  for i in 0 ..< nFiles:
    nimEdAppWindowSmartOpen(win, files[i])

proc nimEdAppClassInit(klass: NimEdAppClass) =
  klass.startup = nimEdAppStartup
  klass.activate = nimEdAppActivate
  klass.open = nimEdAppOpen

proc nimEdAppNew: NimEdApp {.cdecl.} =
  nimEdApp(newObject(typeNimEdApp, "application-id", "org.gtk.ned",
           "flags", gio.GApplicationFlags.HANDLES_OPEN, nil))

proc initapp {.cdecl.} =
  var
    cmdCount {.importc, global.}: cint
    cmdLine {.importc, global.}: cstringArray
  discard glib.setenv("GSETTINGS_SCHEMA_DIR", ".", false)
  discard run(nimEdAppNew(), cmdCount, cmdLine)

proc cleanup {.noconv.} =
  var msg: StatusMsg
  let app = applicationGetDefault()
  if not (app.isNil or app.isRemote):
    if nsProcess != nil:
      msg.filepath = nil
      channel.send(msg)
      joinThreads(thread)
      #if nsProcess != nil:
      nsProcess.terminate
      discard nsProcess.waitForExit
      nsProcess.close

addQuitProc(cleanup)
#[ we use a text view for logging now
var L = newConsoleLogger()
L.levelThreshold = lvlAll
addHandler(L)
]#
initapp()

# 1838 lines
