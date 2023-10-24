//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ISDBTestSupport
import LSPTestSupport
import LanguageServerProtocol
import SKCore
import SKTestSupport
import TSCBasic
import XCTest

public typealias URL = Foundation.URL

final class SKTests: XCTestCase {

  func testInitLocal() async throws {
    let testClient = try await TestSourceKitLSPClient(initialize: false)

    let initResult = try await testClient.send(
      InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURI: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
        trace: .off,
        workspaceFolders: nil
      )
    )

    guard case .options(let syncOptions) = initResult.capabilities.textDocumentSync else {
      XCTFail("Unexpected textDocumentSync property")
      return
    }
    XCTAssertEqual(syncOptions.openClose, true)
    XCTAssertNotNil(initResult.capabilities.completionProvider)
  }

  func testIndexSwiftModules() async throws {
    guard let ws = try await staticSourceKitTibsWorkspace(name: "SwiftModules") else { return }
    try ws.buildAndIndex()
    defer { withExtendedLifetime(ws) {} }  // Keep workspace alive for callbacks.

    let locDef = ws.testLoc("aaa:def")
    let locRef = ws.testLoc("aaa:call:c")

    try ws.openDocument(locDef.url, language: .swift)
    try ws.openDocument(locRef.url, language: .swift)

    // MARK: Jump to definition

    let response = try await ws.testClient.send(
      DefinitionRequest(
        textDocument: locRef.docIdentifier,
        position: locRef.position
      )
    )
    guard case .locations(let jump) = response else {
      XCTFail("Response is not locations")
      return
    }

    XCTAssertEqual(jump.count, 1)
    XCTAssertEqual(jump.first?.uri, try locDef.docUri.nativeURI)
    XCTAssertEqual(jump.first?.range.lowerBound, locDef.position)

    // MARK: Find references

    let refs = try await ws.testClient.send(
      ReferencesRequest(
        textDocument: locDef.docIdentifier,
        position: locDef.position,
        context: ReferencesContext(includeDeclaration: true)
      )
    )

    let call = ws.testLoc("aaa:call")
    XCTAssertEqual(
      Set(refs),
      [
        Location(
          TestLocation(
            url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(validating: locDef.url.path)).pathString),
            line: locDef.line,
            utf8Column: locDef.utf8Column,
            utf16Column: locDef.utf16Column
          )
        ),
        Location(
          TestLocation(
            url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(validating: locRef.url.path)).pathString),
            line: locRef.line,
            utf8Column: locRef.utf8Column,
            utf16Column: locRef.utf16Column
          )
        ),
        Location(
          TestLocation(
            url: URL(fileURLWithPath: try resolveSymlinks(AbsolutePath(validating: call.url.path)).pathString),
            line: call.line,
            utf8Column: call.utf8Column,
            utf16Column: call.utf16Column
          )
        ),
      ]
    )
  }

  func testIndexShutdown() async throws {

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("sk-test-data/\(testDirectoryName)", isDirectory: true)

    func listdir(_ url: URL) throws -> [URL] {
      try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func checkRunningIndex(build: Bool) async throws -> URL? {
      guard
        let ws = try await staticSourceKitTibsWorkspace(
          name: "SwiftModules",
          tmpDir: tmpDir,
          removeTmpDir: false
        )
      else {
        return nil
      }

      if build {
        try ws.buildAndIndex()
      }

      let locDef = ws.testLoc("aaa:def")
      let locRef = ws.testLoc("aaa:call:c")
      try ws.openDocument(locRef.url, language: .swift)
      let response = try await ws.testClient.send(
        DefinitionRequest(
          textDocument: locRef.docIdentifier,
          position: locRef.position
        )
      )
      guard case .locations(let jump) = response else {
        XCTFail("Response is not locations")
        return nil
      }
      XCTAssertEqual(jump.count, 1)
      XCTAssertEqual(jump.first?.uri, try locDef.docUri.nativeURI)
      XCTAssertEqual(jump.first?.range.lowerBound, locDef.position)

      let tmpContents = try listdir(tmpDir)
      guard let versionedPath = tmpContents.filter({ $0.lastPathComponent.starts(with: "v") }).spm_only else {
        XCTFail("expected one version path 'v[0-9]*', found \(tmpContents)")
        return nil
      }

      let versionContentsBefore = try listdir(versionedPath)
      XCTAssertEqual(versionContentsBefore.count, 1)
      XCTAssert(versionContentsBefore.first?.lastPathComponent.starts(with: "p") ?? false)

      _ = try await ws.testClient.send(ShutdownRequest())
      return versionedPath
    }

    guard let versionedPath = try await checkRunningIndex(build: true) else { return }

    let versionContentsAfter = try listdir(versionedPath)
    XCTAssertEqual(versionContentsAfter.count, 1)
    XCTAssertEqual(versionContentsAfter.first?.lastPathComponent, "saved")

    _ = try await checkRunningIndex(build: true)

    try FileManager.default.removeItem(atPath: tmpDir.path)
  }

  func testCodeCompleteSwiftTibs() async throws {
    let ws = try await SwiftPMTestWorkspace(
      files: [
        "a.swift": """
        struct A {
          func method(a b: Int) {}
        }
        """,
        "b.swift": """
        func test(a: A) {
          a.1️⃣
        }
        """,
      ]
    )
    let (uri, positions) = try ws.openDocument("b.swift")

    let testPosition = positions["1️⃣"]
    let results = try await ws.testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(uri), position: testPosition)
    )

    XCTAssertEqual(
      results.items,
      [
        CompletionItem(
          label: "method(a: Int)",
          kind: .method,
          detail: "Void",
          deprecated: false,
          sortText: nil,
          filterText: "method(a:)",
          insertText: "method(a: )",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(
              range: Range(testPosition),
              newText: "method(a: )"
            )
          )
        ),
        CompletionItem(
          label: "self",
          kind: .keyword,
          detail: "A",
          deprecated: false,
          sortText: nil,
          filterText: "self",
          insertText: "self",
          insertTextFormat: .plain,
          textEdit: .textEdit(
            TextEdit(range: Range(testPosition), newText: "self")
          )
        ),
      ]
    )
  }

  func testDependenciesUpdatedSwiftTibs() async throws {
    guard let ws = try await mutableSourceKitTibsTestWorkspace(name: "SwiftModules") else { return }
    defer { withExtendedLifetime(ws) {} }  // Keep workspace alive for callbacks.

    let moduleRef = ws.testLoc("aaa:call:c")

    try ws.openDocument(moduleRef.url, language: .swift)

    let initialDiags = try await ws.testClient.nextDiagnosticsNotification()
    // Semantic analysis: expect module import error.
    XCTAssertEqual(initialDiags.diagnostics.count, 1)
    if let diagnostic = initialDiags.diagnostics.first {
      XCTAssert(
        diagnostic.message.contains("no such module"),
        "expected module import error but found \"\(diagnostic.message)\""
      )
    }

    try ws.buildAndIndex()

    await ws.testClient.server.filesDependenciesUpdated([DocumentURI(moduleRef.url)])

    let updatedDiags = try await ws.testClient.nextDiagnosticsNotification()
    // Semantic analysis: no more errors expected, import should resolve since we built.
    XCTAssertEqual(updatedDiags.diagnostics.count, 0)
  }

  func testDependenciesUpdatedCXXTibs() async throws {
    let ws = try await MultiFileTestWorkspace(files: [
      "lib.c": """
      int libX(int value) {
        return value ? 22 : 0;
      }
      """,
      "main.c": """
      #include "lib-generated.h"

      int main(int argc, const char *argv[]) {
        return libX(argc);
      }
      """,
      "compile_flags.txt": "",
    ])

    let generatedHeaderURL = try ws.uri(for: "main.c").fileURL!.deletingLastPathComponent()
      .appendingPathComponent("lib-generated.h", isDirectory: false)

    // Write an empty header file first since clangd doesn't handle missing header
    // files without a recently upstreamed extension.
    try "".write(to: generatedHeaderURL, atomically: true, encoding: .utf8)
    let (mainUri, _) = try ws.openDocument("main.c")

    let openDiags = try await ws.testClient.nextDiagnosticsNotification()
    // Expect one error:
    // - Implicit declaration of function invalid
    XCTAssertEqual(openDiags.diagnostics.count, 1)

    // Update the header file to have the proper contents for our code to build.
    let contents = "int libX(int value);"
    try contents.write(to: generatedHeaderURL, atomically: true, encoding: .utf8)

    await ws.testClient.server.filesDependenciesUpdated([mainUri])

    let updatedDiags = try await ws.testClient.nextDiagnosticsNotification()
    // No more errors expected, import should resolve since we the generated header file
    // now has the proper contents.
    XCTAssertEqual(updatedDiags.diagnostics.count, 0)
  }

  func testClangdGoToInclude() async throws {
    try XCTSkipIf(!hasClangd)

    let ws = try await MultiFileTestWorkspace(files: [
      "Object.h": "",
      "main.c": """
      #include 1️⃣"Object.h"
      """,
    ])
    let (mainUri, positions) = try ws.openDocument("main.c")
    let headerUri = try ws.uri(for: "Object.h")

    let goToInclude = DefinitionRequest(
      textDocument: TextDocumentIdentifier(mainUri),
      position: positions["1️⃣"]
    )
    let resp = try await ws.testClient.send(goToInclude)

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-#include")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-#include")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, headerUri)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-#include")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, headerUri)
      }
    }
  }

  func testClangdGoToDefinitionWithoutIndex() async throws {
    try XCTSkipIf(!hasClangd)

    let ws = try await MultiFileTestWorkspace(files: [
      "Object.h": """
      struct Object {
        int field;
      };
      """,
      "main.c": """
      #include "Object.h"

      int main(int argc, const char *argv[]) {
        struct 1️⃣Object *obj;
      }
      """,
    ])

    let (mainUri, positions) = try ws.openDocument("main.c")
    let headerUri = try ws.uri(for: "Object.h")

    let goToDefinition = DefinitionRequest(
      textDocument: TextDocumentIdentifier(mainUri),
      position: positions["1️⃣"]
    )
    let resp = try await ws.testClient.send(goToDefinition)

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-definition")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-definition")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, headerUri)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-definition")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, headerUri)
      }
    }
  }

  func testClangdGoToDeclaration() async throws {
    try XCTSkipIf(!hasClangd)

    let ws = try await MultiFileTestWorkspace(files: [
      "Object.h": """
      struct Object {
        int field;
      };

      struct Object * newObject();
      """,
      "main.c": """
      #include "Object.h"

      int main(int argc, const char *argv[]) {
        struct Object *obj = 1️⃣newObject();
      }
      """,
    ])

    let (mainUri, positions) = try ws.openDocument("main.c")
    let headerUri = try ws.uri(for: "Object.h")

    let goToInclude = DeclarationRequest(
      textDocument: TextDocumentIdentifier(mainUri),
      position: positions["1️⃣"]
    )
    let resp = try await ws.testClient.send(goToInclude)

    let locationsOrLinks = try XCTUnwrap(resp, "No response for go-to-declaration")
    switch locationsOrLinks {
    case .locations(let locations):
      XCTAssert(!locations.isEmpty, "Found no locations for go-to-declaration")
      if let loc = locations.first {
        XCTAssertEqual(loc.uri, headerUri)
      }
    case .locationLinks(let locationLinks):
      XCTAssert(!locationLinks.isEmpty, "Found no location links for go-to-declaration")
      if let link = locationLinks.first {
        XCTAssertEqual(link.targetUri, headerUri)
      }
    }
  }

  func testCancellation() async throws {
    let testClient = try await TestSourceKitLSPClient()
    let uri = DocumentURI.for(.swift)
    let positions = testClient.openDocument(
      """
      class Foo {
        func slow(x: Invalid1, y: Invalid2) {
        1️⃣  x / y / x / y / x / y / x / y . 2️⃣
        }

        struct Foo {
          let 3️⃣fooMember: String
        }

        func fast(a: Foo) {
          a.4️⃣
        }
      }
      """,
      uri: uri
    )

    let completionRequestReplied = self.expectation(description: "completion request replied")

    let requestID = RequestID.string("cancellation-test")
    testClient.server.handle(
      CompletionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["2️⃣"]),
      id: requestID,
      from: ObjectIdentifier(self)
    ) { reply in
      switch reply {
      case .success:
        XCTFail("Expected completion request to fail because it was cancelled")
      case .failure(let error):
        XCTAssertEqual(error, ResponseError.cancelled)
      }
      completionRequestReplied.fulfill()
    }
    testClient.send(CancelRequestNotification(id: requestID))

    try await fulfillmentOfOrThrow([completionRequestReplied])

    let fastStartDate = Date()
    let fastReply = try await testClient.send(
      CompletionRequest(textDocument: TextDocumentIdentifier(uri), position: positions["4️⃣"])
    )
    XCTAssert(!fastReply.items.isEmpty)
    XCTAssertLessThan(Date().timeIntervalSince(fastStartDate), 2, "Fast request wasn't actually fast")

    // Remove the slow-to-typecheck line. This causes the implicit diagnostics request for the push diagnostics
    // notification to get cancelled, which unblocks sourcekitd for later tests.
    testClient.send(
      DidChangeTextDocumentNotification(
        textDocument: VersionedTextDocumentIdentifier(uri, version: 2),
        contentChanges: [
          TextDocumentContentChangeEvent(range: positions["1️⃣"]..<positions["2️⃣"], text: "")
        ]
      )
    )

    // Check that semantic functionality based on the AST is working again.
    let symbolInfo = try await testClient.send(
      SymbolInfoRequest(textDocument: TextDocumentIdentifier(uri), position: positions["3️⃣"])
    )
    XCTAssertGreaterThan(symbolInfo.count, 0)
  }
}
