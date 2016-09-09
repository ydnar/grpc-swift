/*
 *
 * Copyright 2016, Google Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */
import Cocoa
import gRPC

// https://gist.github.com/rickw/cc198001f5f3aa59ae9f
extension NSTextView {
  func appendText(line: String) {
    if let textStorage = self.textStorage {
      textStorage.append(
        NSAttributedString(string:line+"\n",
                           attributes:[NSFontAttributeName:NSFont.systemFont(ofSize:12.0)]))
    }
    if let contents = self.string {
      self.scrollRangeToVisible(
        NSRange(location:contents.lengthOfBytes(using:String.Encoding.utf8),length: 0))
    }
  }
}

// http://stackoverflow.com/a/28976644/35844
func sync(lock: AnyObject, closure: () -> Void) {
  objc_sync_enter(lock)
  closure()
  objc_sync_exit(lock)
}

class Document: NSDocument {

  @IBOutlet weak var hostField: NSTextField!
  @IBOutlet weak var portField: NSTextField!
  @IBOutlet weak var connectionSelector: NSSegmentedControl!
  @IBOutlet weak var startButton: NSButton!
  @IBOutlet var textView: NSTextView!
  // http://stackoverflow.com/questions/24062437/cannot-form-weak-reference-to-instance-of-class-nstextview

  var client : Client!

  var server : Server!

  var running: Bool // all accesses to this should be synchronized

  override init() {
    running = false
    super.init()
  }

  override func close() {
    self.textView = nil // prevents logging to the textView
    stop()
    super.close()
  }

  override var windowNibName: String? {
    return "Document"
  }

  override func data(ofType typeName: String) throws -> Data {
    throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
  }

  override func read(from data: Data, ofType typeName: String) throws {
    throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
  }

  func log(_ line:String) {
    DispatchQueue.main.async {
      if let view = self.textView {
        view.appendText(line:line)
      }
    }
  }

  @IBAction func startButtonPressed(sender: NSButton){
    if sender.title == "Start" {
      updateInterfaceBeforeStarting()
      let address = hostField.stringValue + ":" + portField.stringValue
      if (connectionSelector.selectedSegment == 0) {
        startClient(address:address)
      } else {
        startServer(address:address)
      }
    } else {
      stop()
    }
  }

  func updateInterfaceBeforeStarting() {
    startButton.title = "Stop"
    hostField.isEnabled = false
    portField.isEnabled = false
    connectionSelector.isEnabled = false
    if let textStorage = self.textView.textStorage {
      textStorage.setAttributedString(NSAttributedString(string:"", attributes: [:]))
    }
  }

  func updateInterfaceAfterStopping() {
    DispatchQueue.main.async {
      if self.startButton != nil {
        self.startButton.title = "Start"
        self.hostField.isEnabled = true
        self.portField.isEnabled = true
        self.connectionSelector.isEnabled = true
      }
    }
  }

  func setIsRunning(_ value:Bool) {
    sync(lock:self) {
      self.running = value
    }
  }

  func isRunning() -> Bool {
    var result:Bool = false
    sync(lock:self) {
      result = self.running
    }
    return result
  }

  func stop() {
    if (self.client != nil) {
      setIsRunning(false) // stops client
    }
    if (self.server != nil) {
      self.server.stop() // stops server
    }
  }

  func startServer(address:String) {
    self.log("Server Starting")
    self.log("GRPC version " + gRPC.version())
    self.setIsRunning(true)

    self.server = gRPC.Server(address:address)
    var requestCount = 0

    self.server.run() {(requestHandler) in
      requestCount += 1
      self.log("\(requestCount): Received request " + requestHandler.host()
        + " " + requestHandler.method()
        + " from " + requestHandler.caller())
      let initialMetadata = requestHandler.requestMetadata
      for i in 0..<initialMetadata.count() {
        self.log("\(requestCount): Received initial metadata -> " + initialMetadata.key(index:i) + ":" + initialMetadata.value(index:i))
      }

      let initialMetadataToSend = Metadata()
      initialMetadataToSend.add(key:"a", value:"Apple")
      initialMetadataToSend.add(key:"b", value:"Banana")
      initialMetadataToSend.add(key:"c", value:"Cherry")
      requestHandler.receiveMessage(initialMetadata:initialMetadataToSend) {(messageBuffer) in
        let messageData = messageBuffer!.data()
        let messageString = String(data: messageData as Data, encoding:String.Encoding.utf8)
        self.log("\(requestCount): Received message: " + messageString!)
      }
      if requestHandler.method() == "/quit" {
        self.stop()
      }
      let replyMessage = "thank you very much!"
      let trailingMetadataToSend = Metadata()
      trailingMetadataToSend.add(key:"0", value:"zero")
      trailingMetadataToSend.add(key:"1", value:"one")
      trailingMetadataToSend.add(key:"2", value:"two")
      requestHandler.sendResponse(message:ByteBuffer(string:replyMessage),
                                  trailingMetadata:trailingMetadataToSend)
      self.log("------------------------------")
    }

    self.server.onCompletion() {
      self.log("Server Stopped")
      self.updateInterfaceAfterStopping()
    }
  }


  func startClient(address:String) {
    DispatchQueue.global().async {
      self.log("Client Starting")
      self.log("GRPC version " + gRPC.version())
      self.setIsRunning(true)

      let host = "foo.test.google.fr"
      let message = gRPC.ByteBuffer(string:"hello gRPC server!")

      self.client = gRPC.Client(address:address)
      let steps = 10
      for i in 1...steps {
        if !self.isRunning() {
          break
        }
        let method = (i < steps) ? "/hello" : "/quit"

        let metadata = Metadata(pairs:[MetadataPair(key:"x", value:"xylophone"),
                                       MetadataPair(key:"y", value:"yu"),
                                       MetadataPair(key:"z", value:"zither")])

        let call = self.client.createCall(host: host, method: method, timeout: 30)
        call.performNonStreamingCall(messageData: message.data(),
                                     metadata: metadata)
        {(response) in

          if let initialMetadata = response.initialMetadata {
            for j in 0..<initialMetadata.count() {
              self.log("\(i): Received initial metadata -> " + initialMetadata.key(index:j) + " : " + initialMetadata.value(index:j))
            }
          }

          self.log("\(i): Received status: \(response.status) " + response.statusDetails)
          if let messageData = response.messageData {
            let messageString = String(data: messageData as Data, encoding:String.Encoding.utf8)
            self.log("\(i): Received message: " + messageString!)
          }

          if let trailingMetadata = response.trailingMetadata {
            for j in 0..<trailingMetadata.count() {
              self.log("\(i): Received trailing metadata -> " + trailingMetadata.key(index:j) + " : " + trailingMetadata.value(index:j))
            }
          }
          self.log("------------------------------")

        }
        
        sleep(1)
      }
      self.log("Client Stopped")
      self.updateInterfaceAfterStopping()
    }
  }
}