import XCTest
@testable import CompanionTransport

final class V14ProtocolTests: XCTestCase {
    func testWireMessageEncodingDecodingV14() throws {
        let msg = WireMessage(
            type: "sms.send",
            text: "Hello from Mac",
            threadId: 42,
            address: "+15551234567",
            sendId: "test-send-123"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "sms.send")
        XCTAssertEqual(decoded.text, "Hello from Mac")
        XCTAssertEqual(decoded.threadId, 42)
        XCTAssertEqual(decoded.address, "+15551234567")
        XCTAssertEqual(decoded.sendId, "test-send-123")
    }

    func testCallStateWireMessage() throws {
        let callMsg = WireMessage(
            type: "call.state",
            number: "+19876543210",
            callerName: "Alice Smith",
            state: "RINGING",
            callId: "call-uuid-999"
        )
        let data = try JSONEncoder().encode(callMsg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "call.state")
        XCTAssertEqual(decoded.number, "+19876543210")
        XCTAssertEqual(decoded.callerName, "Alice Smith")
        XCTAssertEqual(decoded.state, "RINGING")
        XCTAssertEqual(decoded.callId, "call-uuid-999")
    }

    func testNotificationPushWireMessage() throws {
        let notifMsg = WireMessage(
            type: "notification.push",
            id: "notif-abc-123",
            text: "Hey, are you free for lunch?",
            packageName: "com.whatsapp",
            appName: "WhatsApp",
            title: "Bob",
            canReply: true
        )
        let data = try JSONEncoder().encode(notifMsg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "notification.push")
        XCTAssertEqual(decoded.id, "notif-abc-123")
        XCTAssertEqual(decoded.text, "Hey, are you free for lunch?")
        XCTAssertEqual(decoded.packageName, "com.whatsapp")
        XCTAssertEqual(decoded.appName, "WhatsApp")
        XCTAssertEqual(decoded.title, "Bob")
        XCTAssertEqual(decoded.canReply, true)
    }

    func testAndroidSmsConversationJsonCompatibility() throws {
        // Sample JSON emitted by Android SmsConversation.toJson()
        let jsonStr = """
        [
            {
                "threadId": 101,
                "address": "+14155550199",
                "contactName": "Charlie Brown",
                "snippet": "Sounds good to me!",
                "date": 1729500000000,
                "unreadCount": 1
            }
        ]
        """
        let data = jsonStr.data(using: .utf8)!
        let threads = try JSONDecoder().decode([SmsThread].self, from: data)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].threadId, 101)
        XCTAssertEqual(threads[0].id, "101")
        XCTAssertEqual(threads[0].address, "+14155550199")
        XCTAssertEqual(threads[0].contactName, "Charlie Brown")
        XCTAssertEqual(threads[0].snippet, "Sounds good to me!")
        XCTAssertEqual(threads[0].unreadCount, 1)
    }

    func testAndroidSmsMessageJsonCompatibility() throws {
        // Sample JSON emitted by Android SmsMessageItem.toJson()
        let jsonStr = """
        [
            {
                "id": 5001,
                "threadId": 101,
                "address": "+14155550199",
                "body": "Hello there!",
                "date": 1729500000000,
                "type": 1,
                "isFromMe": false
            },
            {
                "id": 5002,
                "threadId": 101,
                "address": "+14155550199",
                "body": "Hi Charlie!",
                "date": 1729500010000,
                "type": 2,
                "isFromMe": true
            }
        ]
        """
        let data = jsonStr.data(using: .utf8)!
        let messages = try JSONDecoder().decode([SmsMessage].self, from: data)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, 5001)
        XCTAssertEqual(messages[0].body, "Hello there!")
        XCTAssertEqual(messages[0].isFromMe, false)

        XCTAssertEqual(messages[1].id, 5002)
        XCTAssertEqual(messages[1].body, "Hi Charlie!")
        XCTAssertEqual(messages[1].isFromMe, true)
    }
}
