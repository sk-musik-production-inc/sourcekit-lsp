add_library(Diagnose STATIC
  CommandConfiguration+Sendable.swift
  CommandLineArgumentsReducer.swift
  DiagnoseCommand.swift
  IndexCommand.swift
  MergeSwiftFiles.swift
  OSLogScraper.swift
  ReduceCommand.swift
  ReduceFrontendCommand.swift
  ReduceSourceKitDRequest.swift
  ReduceSwiftFrontend.swift
  ReductionError.swift
  ReproducerBundle.swift
  RequestInfo.swift
  SourceKitD+RunWithYaml.swift
  SourcekitdRequestCommand.swift
  SourceKitDRequestExecutor.swift
  SourceReducer.swift
  StderrStreamConcurrencySafe.swift
  SwiftFrontendCrashScraper.swift
  Toolchain+SwiftFrontend.swift)

set_target_properties(Diagnose PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

target_link_libraries(Diagnose PUBLIC
  InProcessClient
  LSPLogging
  SKCore
  SourceKitD
  ArgumentParser
  SwiftSyntax::SwiftIDEUtils
  SwiftSyntax::SwiftSyntax
  SwiftSyntax::SwiftParser
  TSCBasic
)
