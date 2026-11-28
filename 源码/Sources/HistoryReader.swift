import AppKit
import SwiftUI

// The very same text view stays under the pointer as reading becomes editing. AppKit owns
// caret positioning, undo, selection and marked text (including uncommitted Chinese input).
struct PassageEditor: NSViewRepresentable {
  let id: UUID, value: String, label: String
  var size: CGFloat = 15, editable = true, editing = false, bottomAtEntry = false, followsTail = false
  var compare:String? = nil
  var step: ((Int) -> Bool)? = nil
  var begin: () -> Bool, change: (String) -> Void, save: () -> Void, cancel: () -> Void
  final class TextBox: NSTextView {
    weak var reader: Reader?
    override var needsPanelToBecomeKey: Bool { reader?.config?.editing == true }
    override var undoManager:UndoManager? { reader?.undoStack ?? super.undoManager }
    override func accessibilityPerformPress() -> Bool {
      guard reader?.enter() == true else {return super.accessibilityPerformPress()}; window?.makeKey(); window?.makeFirstResponder(self); return true
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) {
      let hit=reader?.plainOffset(at:characterIndexForInsertion(at:convert(event.locationInWindow,from:nil)))
      guard isEditable else {super.mouseDown(with:event);return}; guard reader?.enter() == true else {return}
      window?.makeKey();window?.makeFirstResponder(self)
      if let hit {setSelectedRange(NSRange(location:min(hit,string.utf16.count),length:0));return};super.mouseDown(with:event)
    }
    override func shouldChangeText(in range:NSRange,replacementString string:String?) -> Bool {
      guard reader?.enter() == true else {return false};return super.shouldChangeText(in:range,replacementString:string)
    }
    override func keyDown(with e:NSEvent) {
      if !hasMarkedText(),e.keyCode == 53,reader?.config?.editing == true {reader?.config?.cancel();return};super.keyDown(with:e)
    }
    override func performKeyEquivalent(with e:NSEvent) -> Bool {
      if !hasMarkedText(),reader?.config?.editing == true,e.modifierFlags.intersection([.command,.option,.control,.shift]) == .command,[1,36,76].contains(e.keyCode) {reader?.config?.save();return true};return super.performKeyEquivalent(with:e)
    }
    override func didChangeText() { super.didChangeText();reader?.config?.change(string);reader?.fit() }
  }
  final class Reader: NSScrollView {
    let text = TextBox(), undoStack=UndoManager()
    var config:PassageEditor?, renderedDiff:[ReviewRuns.Piece]?, token:UUID?, lastSize:CGFloat=0, lastViewport=NSSize.zero
    private var monitor:Any?, scrollWatch:NSObjectProtocol?, followsNewest=true
    override init(frame:NSRect) {
      super.init(frame:frame);borderType = .noBorder;drawsBackground=false;hasVerticalScroller=true;autohidesScrollers=true;scrollerStyle = .overlay
      text.reader=self;text.isSelectable=true;text.isRichText=false;text.drawsBackground=false;text.focusRingType = .none;text.allowsUndo=true;text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.isAutomaticTextReplacementEnabled=false;text.isAutomaticSpellingCorrectionEnabled=false
      text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.textContainerInset=NSSize(width:2,height:2);text.textContainer?.lineFragmentPadding=0;text.textContainer?.widthTracksTextView=true
      documentView=text
      scrollWatch=NotificationCenter.default.addObserver(forName:NSScrollView.didLiveScrollNotification,object:self,queue:.main) { [weak self] _ in self?.userScrolled() }
    }
    required init?(coder:NSCoder){nil}
    override var undoManager:UndoManager? {undoStack}
    func plainOffset(at offset:Int) -> Int? {
      guard let runs=renderedDiff else {return nil};var visual=0,plain=0
      for r in runs {let count=r.s.utf16.count;if offset<=visual+count {return plain+(r.type<0 ? 0 : max(0,offset-visual))};visual+=count;if r.type>=0 {plain+=count}};return plain
    }
    func enter() -> Bool {
      guard var c=config,c.editable else {return false};if c.editing {return true};guard c.begin() else {return false};c.editing=true;apply(c);return true
    }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow();if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil};guard window != nil else {return}
      monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in
        guard let s=self,let c=s.config,let step=c.step,!c.editing,let w=s.window,w.isKeyWindow,e.window === w,w.attachedSheet == nil,[125,126].contains(e.keyCode),e.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else {return e}
        if let t=w.firstResponder as? NSTextView,t !== s.text {return e};if w.firstResponder is NSTextField {return e}
        let dir=e.keyCode==125 ? 1 : -1, y=s.contentView.bounds.minY,edge=dir>0 ? s.bottom : 0
        if abs(y-edge)<=0.75 {return step(dir) ? nil : e}
        let distance=min(76,max(20,s.contentSize.height*0.65))
        s.scroll(to:min(s.bottom,max(0,y+CGFloat(dir)*distance)));return nil
      }
    }
    var bottom:CGFloat {max(0,text.frame.height-contentView.bounds.height)}
    func scroll(to y:CGFloat) {contentView.scroll(to:NSPoint(x:0,y:y));reflectScrolledClipView(contentView)}
    private func userScrolled() {if config?.followsTail == true {followsNewest=bottom-contentView.bounds.minY <= 2}}
    override func scrollWheel(with e:NSEvent) {super.scrollWheel(with:e);userScrolled()}
    override func layout() {
      super.layout(); if lastViewport != contentSize {fit()}
      // A hosting view measures the reader at several sizes before it becomes visible.
      // Reflow must not be mistaken for the user scrolling up.
      if config?.followsTail == true, followsNewest, abs(contentView.bounds.minY-bottom)>0.5 {scroll(to:bottom)}
    }
    func fit() {
      let w=max(1,contentSize.width);lastViewport=contentSize
      text.setFrameSize(NSSize(width:w,height:max(1,text.frame.height)))
      guard let m=text.layoutManager,let c=text.textContainer else {return};c.containerSize=NSSize(width:max(1,w-4),height:.greatestFiniteMagnitude);m.ensureLayout(for:c)
      text.setFrameSize(NSSize(width:w,height:max(ceil(m.usedRect(for:c).height)+5,contentSize.height)))
    }
    func apply(_ c:PassageEditor) {
      let previous=config, new=token != c.id, oldCompare=previous?.editing == true ? nil : previous?.compare
      let compare=c.editing || c.compare==c.value ? nil : c.compare, font=NSFont.systemFont(ofSize:c.size,weight:.medium)
      let y=contentView.bounds.minY
      if new {followsNewest=true}
      config=c;token=c.id;text.isEditable=c.editable;text.isSelectable = !c.followsTail;text.setAccessibilityLabel(c.label)
      let p=NSMutableParagraphStyle();p.lineSpacing=3
      let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:p]
      let restyle=new || lastSize != c.size;lastSize=c.size
      if new || previous?.editing == true && !c.editing {undoStack.removeAllActions()}
      if let compare {
        if restyle || renderedDiff == nil || compare != oldCompare || previous?.value != c.value {
          let runs=ReviewRuns.transcriptDiff(compare,c.value), ink=NSMutableAttributedString(string:""); var first:Int?
          for r in runs { var a=attrs;if r.type != 0 {if first == nil {first=ink.length};a[.foregroundColor]=r.type<0 ? NSColor.systemRed : NSColor(Color.inkMint);if r.type<0 {a[.strikethroughStyle]=NSUnderlineStyle.single.rawValue} };ink.append(NSAttributedString(string:r.s,attributes:a)) }
          renderedDiff=runs;text.textStorage?.setAttributedString(ink);fit()
          if !c.followsTail {text.scrollRangeToVisible(NSRange(location:first ?? 0,length:0))}
        }
      } else if !text.hasMarkedText() {
        let wasMarked=renderedDiff != nil;renderedDiff=nil
        if restyle || wasMarked || text.string != c.value {
          if c.followsTail, !restyle, !wasMarked, let old=previous?.value, c.value.utf16.starts(with:old.utf16) {
            // A committed prefix is immutable. Append without re-laying out the entire transcript.
            let added=(c.value as NSString).substring(from:old.utf16.count)
            text.textStorage?.append(NSAttributedString(string:added,attributes:attrs))
          } else {text.textStorage?.setAttributedString(NSAttributedString(string:c.value,attributes:attrs))}
          text.typingAttributes=attrs;text.defaultParagraphStyle=p;fit()
        }
        if new {scroll(to:c.bottomAtEntry ? bottom : 0)}
      }
      if lastViewport != contentSize {fit()}
      if c.followsTail {scroll(to:followsNewest ? bottom : min(bottom,y))}
    }
    deinit {if let monitor {NSEvent.removeMonitor(monitor)};if let scrollWatch {NotificationCenter.default.removeObserver(scrollWatch)}}
  }
  func makeNSView(context:Context) -> Reader {Reader(frame:.zero)}
  func updateNSView(_ v:Reader,context:Context) {v.apply(self)}
}
