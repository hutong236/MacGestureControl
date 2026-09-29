import Foundation

struct FingerPattern: Equatable, Hashable {
    let thumb: Bool; let index: Bool; let middle: Bool; let ring: Bool; let little: Bool
}
struct Gesture: Equatable { let name: String; let pattern: FingerPattern; let enabled: Bool }
final class Engine {
    var gestures: [Gesture] = []
    var current: FingerPattern?
    var since: Double = 0
    var blocked: FingerPattern?
    func process(_ p: FingerPattern?, t: Double) -> Gesture? {
        guard let p else { current=nil; return nil }
        if current != p { current=p; since=t; if blocked != p { blocked=nil }; return nil }
        guard blocked != p, t-since >= 0.55 else { return nil }
        if let g=gestures.first(where: {$0.enabled && $0.pattern == p}) { blocked=p; return g }
        return nil
    }
}
let v = FingerPattern(thumb:false,index:true,middle:true,ring:false,little:false)
let e=Engine(); e.gestures=[Gesture(name:"V",pattern:v,enabled:true)]
precondition(e.process(v,t:0)==nil)
precondition(e.process(v,t:0.3)==nil)
precondition(e.process(v,t:0.56)?.name=="V")
precondition(e.process(v,t:1.2)==nil) // holding does not repeat
let fist = FingerPattern(thumb:false,index:false,middle:false,ring:false,little:false)
precondition(e.process(fist,t:1.3)==nil) // change gesture rearms
precondition(e.process(v,t:1.4)==nil)
precondition(e.process(v,t:2.0)?.name=="V")
print("PASS: static gesture stability + rearm")
