// SPDX-License-Identifier: MIT
import ArgumentParser

public struct RootCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stackroom-import",
        abstract: "StackNest CLI — Stackroom import and performance benchmarks.",
        subcommands: [ImportCommand.self, BenchCommand.self],
        defaultSubcommand: ImportCommand.self
    )
    public init() {}
}
