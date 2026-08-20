import Foundation
import XCTest
@testable import Cyclop

@MainActor
final class NowPlayingFeedLifecycleTests: XCTestCase {
    func testOldLifecycleEventsCannotAffectNewFeedCycle() {
        let driver = FeedLifecycleDriver()
        let feed = NowPlayingFeed(lifecycleHooks: driver.hooks)
        var titles: [String] = []
        feed.onUpdate = { titles.append($0.title) }

        feed.start()
        let first = driver.latest
        driver.receive(Data("{\"title\":\"Старый".utf8), from: first)
        driver.terminate(first)
        XCTAssertEqual(driver.retryCount, 1)

        feed.stop()
        feed.start()
        let second = driver.latest
        driver.fireRetry(0)
        driver.receive(snapshotLine(title: "Новый"), from: second)
        driver.receive(snapshotLine(title: "Старый"), from: first)
        driver.terminate(first)

        XCTAssertEqual(titles, ["Новый"])
        XCTAssertEqual(driver.launchCount, 2)
        XCTAssertEqual(driver.retryCount, 1)
    }

    private func snapshotLine(title: String) -> Data {
        Data("{\"title\":\"\(title)\",\"artist\":\"Исполнитель\",\"album\":\"Альбом\"}\n".utf8)
    }
}

@MainActor
private final class FeedLifecycleDriver {
    private struct Session {
        let receive: (Data) -> Void
        let terminate: () -> Void
    }

    private var sessions: [Session] = []
    private var retries: [() -> Void] = []

    var hooks: NowPlayingFeed.LifecycleHooks {
        .init(
            launch: { [weak self] receive, terminate in
                self?.sessions.append(.init(receive: receive, terminate: terminate))
            },
            stop: {},
            scheduleRetry: { [weak self] retry in
                self?.retries.append(retry)
            }
        )
    }

    var latest: Int { sessions.index(before: sessions.endIndex) }
    var launchCount: Int { sessions.count }
    var retryCount: Int { retries.count }

    func receive(_ data: Data, from session: Int) {
        sessions[session].receive(data)
    }

    func terminate(_ session: Int) {
        sessions[session].terminate()
    }

    func fireRetry(_ index: Int) {
        retries[index]()
    }
}
