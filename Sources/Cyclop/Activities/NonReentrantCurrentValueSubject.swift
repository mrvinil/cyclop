import Combine

@MainActor
final class NonReentrantCurrentValueSubject<Output> {
    var value: Output { subject.value }

    var publisher: AnyPublisher<Output, Never> {
        subject.eraseToAnyPublisher()
    }

    private let subject: CurrentValueSubject<Output, Never>
    private var pending: [Output] = []
    private var isSending = false

    init(_ value: Output) {
        subject = CurrentValueSubject(value)
    }

    func send(_ value: Output) {
        pending.append(value)
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }
        while !pending.isEmpty {
            subject.send(pending.removeFirst())
        }
    }
}
