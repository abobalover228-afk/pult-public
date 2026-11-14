import Foundation
@main struct WidgetChecks {
    static func main() throws {
        func sample(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
        let now=10000.0
        let valid: [String:Any] = ["saved_at":9990,"rate_limits":["five_hour":["used_percentage":25,"resets_at":11000]]]
        let fresh=ClaudeCacheSnapshot.parse(try sample(valid),now:now)
        precondition(fresh.fresh && fresh.windows.first?.1 == 75 && fresh.receivedAt == 9990)
        let reread=ClaudeCacheSnapshot.parse(try sample(valid),now:10200)
        precondition(!reread.fresh && reread.receivedAt == fresh.receivedAt)
        precondition(ClaudeCacheSnapshot.parse(nil,now:now).windows.isEmpty)
        precondition(!ClaudeCacheSnapshot.parse(Data("broken".utf8),now:now).fresh)
        for invalid: Any in [true,"20",-5,150] {
            let data=try sample(["saved_at":9990,"rate_limits":["five_hour":["used_percentage":invalid]]])
            precondition(!ClaudeCacheSnapshot.parse(data,now:now).fresh)
        }
        let expired=try sample(["saved_at":9990,"rate_limits":["five_hour":["used_percentage":80,"resets_at":9900]]])
        precondition(ClaudeCacheSnapshot.parse(expired,now:now).windows.isEmpty)
        let future=try sample(["saved_at":20000,"rate_limits":["five_hour":["used_percentage":5]]])
        precondition(!ClaudeCacheSnapshot.parse(future,now:now).fresh)
        let suite="pult.widget.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let hidden=HiddenWidgetAccounts(defaults:defaults)
        let key=HiddenWidgetAccounts.codex(home:"~/.codex-2",name:"Old")
        hidden.hide(key)
        let afterRestart=HiddenWidgetAccounts(defaults:defaults)
        precondition(afterRestart.contains(HiddenWidgetAccounts.codex(home:FileManager.default.homeDirectoryForCurrentUser.path+"/.codex-2",name:"Renamed")))
        afterRestart.restoreAll()
        precondition(HiddenWidgetAccounts(defaults:defaults).keys.isEmpty)
        print("PASS: fresh/stale/error/expired Claude data, truthful timestamp, hidden account identity, persistence across restart and restore")
    }
}
