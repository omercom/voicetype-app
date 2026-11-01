import Carbon

/// Carbon reserves the chord globally and reports conflicts instead of silently failing.
final class ReadAloudHotKey {
    var onPressed: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func start() -> OSStatus {
        guard hotKey == nil else { return noErr }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x56545453, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<ReadAloudHotKey>.fromOpaque(context).takeUnretainedValue().onPressed?()
            return noErr
        }, 1, &type, pointer, &handler)
        guard status == noErr else { return status }
        let identifier = EventHotKeyID(signature: 0x56545453, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey | cmdKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { stop() }
        return result
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    deinit { stop() }
}
