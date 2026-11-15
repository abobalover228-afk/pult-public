import AppKit
import SwiftUI

struct MessagePositions:PreferenceKey {
    static var defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]){value.merge(nextValue()){_,new in new}}
}
final class FollowState:ObservableObject {
    @Published var following=true
    var jump:(()->Void)?
    var measurements:(([String:CGFloat])->Void)?
    func resume(){following=true;jump?()}
    static func preservedY(origin:CGFloat,old:[String:CGFloat],new:[String:CGFloat])->CGFloat {
        guard let anchor=old.filter({$0.value >= origin-2 && new[$0.key] != nil}).min(by:{$0.value<$1.value}),let next=new[anchor.key] else{return origin}
        return max(0,origin+next-anchor.value)
    }
}
struct FollowingScroll<Content:View>:View {
    @ObservedObject var state:FollowState
    let content:Content
    init(state:FollowState,@ViewBuilder content:()->Content){self.state=state;self.content=content()}
    var body:some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing:0) {
                    content
                    Color.clear.frame(height:1).id("follow-bottom")
                }.background(NativeScrollProbe(state:state).frame(width:0,height:0))
            }
            .onAppear { state.jump={proxy.scrollTo("follow-bottom",anchor:.bottom)};state.following=true }
            .onDisappear { state.jump=nil;state.measurements=nil }
            .onReceive(Timer.publish(every:0.15,on:.main,in:.common).autoconnect()){_ in
                if state.following { proxy.scrollTo("follow-bottom",anchor:.bottom) }
            }
        }
    }
}

struct NativeScrollProbe:NSViewRepresentable {
    let state:FollowState
    func makeNSView(context:Context)->ScrollProbeView {let view=ScrollProbeView();view.state=state;return view}
    func updateNSView(_ view:ScrollProbeView,context:Context){view.state=state;view.attach()}
}
final class ScrollProbeView:NSView {
    weak var tracked:NSScrollView?
    var state:FollowState?
    var observers:[NSObjectProtocol]=[]
    var eventMonitor:Any?
    var adjusting=false
    var positions:[String:CGFloat]=[:]
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();attach()}
    override func viewDidMoveToSuperview(){super.viewDidMoveToSuperview();DispatchQueue.main.async{[weak self] in self?.attach()}}
    func attach(){
        guard let scroll=enclosingScrollView,tracked !== scroll else{return}
        for observer in observers{NotificationCenter.default.removeObserver(observer)};observers=[];tracked=scroll
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDragged,.keyDown]){[weak self,weak scroll] event in
            guard let self,let scroll,event.window === scroll.window else{return event}
            let point=scroll.convert(event.locationInWindow,from:nil)
            guard scroll.bounds.contains(point) else{return event}
            let userScroll=event.type == .scrollWheel || event.type == .leftMouseDragged
            if userScroll {
                if event.type == .scrollWheel && event.scrollingDeltaY > 0 { self.state?.following=false }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.08){[weak self] in self?.userMoved()}
            }
            return event
        }
        scroll.contentView.postsBoundsChangedNotifications=true;scroll.documentView?.postsFrameChangedNotifications=true
        observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main){[weak self] _ in self?.boundsChanged()})
        state?.measurements={[weak self] values in self?.updatePositions(values)}
    }
    func boundsChanged() {}
    func userMoved(){
        guard !adjusting,let scroll=tracked,let doc=scroll.documentView,let state else{return}
        let end=doc.isFlipped ? doc.bounds.height-scroll.contentView.bounds.maxY < 50 : scroll.contentView.bounds.minY < 50
        if state.following != end { state.following=end }
    }
    func updatePositions(_ new:[String:CGFloat]){
        defer{positions=new}
        guard let scroll=tracked,let doc=scroll.documentView else{return}
        if state?.following == true{return}
        let origin=scroll.contentView.bounds.origin
        let y=FollowState.preservedY(origin:origin.y,old:positions,new:new)
        if abs(y-origin.y)>0.5{
            DispatchQueue.main.async { [weak self,weak scroll,weak doc] in
                guard let self,let scroll,let doc,self.state?.following == false else{return}
                self.adjusting=true
                scroll.contentView.scroll(to:NSPoint(x:0,y:min(y,max(0,doc.bounds.height-scroll.contentView.bounds.height))))
                scroll.reflectScrolledClipView(scroll.contentView);self.adjusting=false
            }
        }
    }
    deinit{if let eventMonitor{NSEvent.removeMonitor(eventMonitor)};for observer in observers{NotificationCenter.default.removeObserver(observer)}}
}
