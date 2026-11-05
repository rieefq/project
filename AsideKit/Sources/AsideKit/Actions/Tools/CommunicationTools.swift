import Foundation

private func contactsAccess(_ service: ContactsService, _ call: ToolCall) async -> ToolOutcome? {
    await Access.ensure(.contacts, call: call, current: { await service.access() }, request: { await service.requestAccess() })
}

/// Resolves a spoken name ("Sam", "mom") to exactly one contact, asking when ambiguous.
private func resolveContact(_ service: ContactsService, name: String, call: ToolCall, context: ExecutionContext) async -> Lookup<ContactMatch> {
    let matches: [ContactMatch]
    do { matches = try await service.find(name) } catch {
        return .outcome(.failed(ToolFailure(.service, message: "I couldn't search your contacts.", detail: "\(error)", isRetryable: true)))
    }
    if let id = call.arguments["contact_id"]?.nonEmptyString, let chosen = matches.first(where: { $0.id == id }) {
        return .found(chosen)
    }
    switch matches.count {
    case 0:
        return .outcome(.failed(ToolFailure(.notFound, message: "I couldn't find \(name) in your contacts.")))
    case 1:
        return .found(matches[0])
    default:
        // Prefer an exact full-name match.
        let exact = matches.filter { $0.name.lowercased() == name.lowercased() }
        if exact.count == 1 { return .found(exact[0]) }
        let options = matches.prefix(4).map { contact in
            ChoiceOption(label: contact.name, detail: contact.primaryPhone?.value ?? contact.handles.first?.value, value: .string(contact.id))
        }
        return .outcome(.needsChoice(ChoiceRequest(prompt: "Which \(name) — \(context.formatter.list(options.map(\.label), conjunction: "or"))?",
                                                   options: Array(options), parameter: "contact_id", call: call)))
    }
}

// MARK: - Messages

public struct SendMessageTool: ToolHandler {
    let contacts: ContactsService
    let communication: CommunicationService

    public init(contacts: ContactsService, communication: CommunicationService) {
        self.contacts = contacts
        self.communication = communication
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "send_message",
            description: "Prepare a text message to one of the user's contacts. Opens the system compose sheet with the recipient and text filled in; the user sends it. Never claim it was sent unless the result says sent.",
            inputSchema: Schema.object([
                "recipient": Schema.string("Contact name or relation, e.g. \"Sam Lee\", \"mom\"."),
                "body": Schema.string("The message text, in the user's voice."),
            ], required: ["recipient"]),
            capability: .messages, risk: .consequential)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard let name = call.arguments["recipient"]?.nonEmptyString else {
            return .outcome(.needsInfo(SlotRequest(prompt: "Who should I message?", parameter: "recipient", kind: .contact, call: call)))
        }
        guard await communication.canSendMessages() else {
            return .outcome(.failed(ToolFailure(.unavailable, message: "This device can't send messages.")))
        }
        if let blocked = await contactsAccess(contacts, call) { return .outcome(blocked) }
        switch await resolveContact(contacts, name: name, call: call, context: context) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let contact):
            guard let handle = contact.primaryPhone ?? contact.handles.first else {
                return .outcome(.failed(ToolFailure(.notFound, message: "\(contact.name) doesn't have a phone number or email I can message.")))
            }
            guard let body = call.arguments["body"]?.nonEmptyString else {
                return .outcome(.needsInfo(SlotRequest(prompt: "What should it say?", parameter: "body", kind: .text,
                                                       call: call.with("contact_id", .string(contact.id)))))
            }
            let resolved = call.with("contact_id", .string(contact.id)).with("handle", .string(handle.value))
                .with("handle_kind", .string(handle.kind.rawValue)).with("contact_name", .string(contact.name))
            let details = ConfirmationDetails(
                title: "Message", subject: "\(contact.name) · \(handle.value)", detail: body,
                consequence: "Opens a message to \(contact.name) for you to send.",
                prompt: "Message \(contact.name): \(body.spokenPrefix(words: 14))", confirmLabel: "Send")
            return .ready(PreparedCall(call: resolved, risk: .consequential, confirmation: details,
                                       idempotencyKey: "send_message:\(contact.id):\(body.lowercased())", platformConfirms: true))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        guard let id = arguments["contact_id"]?.nonEmptyString, let value = arguments["handle"]?.nonEmptyString,
              let body = arguments["body"]?.nonEmptyString else {
            return .failed(ToolFailure(.invalidArguments, message: "I'm missing who to message or what to say."))
        }
        let name = arguments["contact_name"]?.stringValue ?? "them"
        let kind = ContactHandle.Kind(rawValue: arguments["handle_kind"]?.stringValue ?? "phone") ?? .phone
        let contact = ContactMatch(id: id, name: name, handles: [ContactHandle(kind: kind, value: value)])
        let result = await communication.composeMessage(MessageDraft(recipient: contact, handle: ContactHandle(kind: kind, value: value), body: body))
        switch result {
        case .sent:
            return .completed(ActionResult(summary: "Sent a message to \(name)", speech: SpeechPlan(minimal: "Sent.", balanced: "Sent to \(name).", detailed: nil),
                                           referent: Referent(kind: .message, id: id, title: name), data: ["status": "sent"], earcon: .success))
        case .cancelled:
            return .completed(ActionResult(summary: "Message to \(name) not sent (cancelled)", speech: SpeechPlan("Okay, I didn't send it."),
                                           data: ["status": "cancelled"], earcon: .cancelled))
        case .handedOff:
            return .completed(ActionResult(summary: "Opened a message to \(name) (not confirmed sent)",
                                           speech: SpeechPlan(minimal: "It's ready to send.", balanced: "Your message to \(name) is ready — just hit send.", detailed: nil),
                                           data: ["status": "ready_to_send"], earcon: .attention))
        case .failed(let reason):
            return .failed(ToolFailure(.service, message: "I couldn't open the message.", detail: reason, isRetryable: true))
        }
    }
}

// MARK: - Calls

public struct CallContactTool: ToolHandler {
    let contacts: ContactsService
    let communication: CommunicationService

    public init(contacts: ContactsService, communication: CommunicationService) {
        self.contacts = contacts
        self.communication = communication
    }

    public var spec: ToolSpec {
        ToolSpec(name: "call_contact", description: "Start a phone or FaceTime call to one of the user's contacts. The system asks the user to confirm.",
                 inputSchema: Schema.object([
                    "recipient": Schema.string("Contact name or relation."),
                    "facetime": Schema.boolean("Use FaceTime."),
                 ], required: ["recipient"]),
                 capability: .phone, risk: .consequential)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard let name = call.arguments["recipient"]?.nonEmptyString else {
            return .outcome(.needsInfo(SlotRequest(prompt: "Who should I call?", parameter: "recipient", kind: .contact, call: call)))
        }
        if let blocked = await contactsAccess(contacts, call) { return .outcome(blocked) }
        switch await resolveContact(contacts, name: name, call: call, context: context) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let contact):
            guard let phone = contact.primaryPhone ?? (call.arguments["facetime"]?.boolValue == true ? contact.handles.first : nil) else {
                return .outcome(.failed(ToolFailure(.notFound, message: "\(contact.name) doesn't have a phone number.")))
            }
            let resolved = call.with("contact_id", .string(contact.id)).with("handle", .string(phone.value))
                .with("handle_kind", .string(phone.kind.rawValue)).with("contact_name", .string(contact.name))
            return .ready(PreparedCall(call: resolved, risk: .consequential,
                                       confirmation: ConfirmationDetails(title: "Call", subject: "\(contact.name) · \(phone.value)",
                                                                         consequence: "Starts a call.", prompt: "Call \(contact.name)?", confirmLabel: "Call"),
                                       platformConfirms: true))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        guard let value = arguments["handle"]?.nonEmptyString else {
            return .failed(ToolFailure(.invalidArguments, message: "Who should I call?"))
        }
        let name = arguments["contact_name"]?.stringValue ?? "them"
        let kind = ContactHandle.Kind(rawValue: arguments["handle_kind"]?.stringValue ?? "phone") ?? .phone
        do {
            try await communication.placeCall(to: ContactHandle(kind: kind, value: value, label: arguments["facetime"]?.boolValue == true ? "facetime" : nil))
            return .completed(ActionResult(summary: "Started a call to \(name)", speech: SpeechPlan(minimal: nil, balanced: "Calling \(name).", detailed: "Calling \(name)."),
                                           referent: Referent(kind: .message, id: arguments["contact_id"]?.stringValue ?? name, title: name),
                                           data: ["status": "started"], earcon: .none))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't start the call.", detail: "\(error)", isRetryable: true))
        }
    }
}
