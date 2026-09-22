// System-language entries (the "system_languages" group):
// java, kotlin, csharp (+ omnisharp alternate), c/c++ (+ ccls alternate).
package langserver

cpp_file_patterns :: proc() -> []string {
	src := [24]string{
		"*.c", "*.cpp", "*.cc", "*.cxx", "*.c++", "*.cp",
		"*.h", "*.hpp", "*.hxx", "*.h++",
		"*.inl", "*.ipp", "*.tpp", "*.txx",
		"*.m", "*.mm",
		"*.cppm", "*.cxxm", "*.c++m", "*.ixx",
		"*.cu", "*.hip", "*.cl", "*.clcpp",
	}
	out := make([]string, len(src), context.temp_allocator)
	for v, i in src {
		out[i] = v
	}
	return out
}

register_system_entries :: proc(reg: ^Registry) {
	registry_add(reg, {
		id                = "java",
		display_name      = "Java",
		file_patterns     = {"*.java"},
		priority          = PRIORITY_NORMAL,
		command           = "jdtls",
		required_binaries = {{"java", "Java"}},
		install_hint      = "Install Eclipse JDT Language Server (jdtls) from your package manager or https://download.eclipse.org/jdtls/",
	})

	registry_add(reg, {
		id                = "kotlin",
		display_name      = "Kotlin",
		file_patterns     = {"*.kt", "*.kts"},
		priority          = PRIORITY_NORMAL,
		command           = "kotlin-language-server",
		required_binaries = {{"kotlin-language-server", "kotlin-language-server"}},
		install_hint      = "Install from https://github.com/fwcd/kotlin-language-server/releases",
	})

	registry_add(reg, {
		id                = "csharp",
		display_name      = "C#",
		file_patterns     = {"*.cs"},
		priority          = PRIORITY_NORMAL,
		command           = "dotnet",
		args              = {"Microsoft.CodeAnalysis.LanguageServer.dll"},
		required_binaries = {{"dotnet", ".NET SDK"}},
		install_hint      = "Install .NET SDK from https://dotnet.microsoft.com/download and the C# language server via: dotnet tool install -g Microsoft.CodeAnalysis.LanguageServer",
	})

	registry_add(reg, {
		id                = "csharp_omnisharp",
		display_name      = "C# (OmniSharp)",
		file_patterns     = {"*.cs"},
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "OmniSharp",
		args              = {"-lsp", "--encoding", "ascii", "-z", "-s"},
		required_binaries = {{"OmniSharp", "OmniSharp"}},
	})

	registry_add(reg, {
		id                = "cpp",
		display_name      = "C/C++",
		file_patterns     = cpp_file_patterns(),
		priority          = PRIORITY_NORMAL,
		// clangd accepts multiple workspace folders and discovers the
		// compilation database per source file (walking up from each
		// file), so sibling C/C++/Objective-C projects each resolve their
		// own compile_commands.json. The .git marker catches repository
		// roots that keep no database in tree (Xcode-style projects).
		root_markers      = {".git", "compile_commands.json"},
		multi_root        = true,
		command           = "clangd",
		required_binaries = {{"clangd", "clangd"}},
		install_hint      = "Install via your package manager (e.g. apt install clangd, brew install llvm, or from https://releases.llvm.org/)",
	})

	registry_add(reg, {
		id                = "cpp_ccls",
		display_name      = "C/C++ (ccls)",
		file_patterns     = cpp_file_patterns(),
		priority          = PRIORITY_EXPERIMENTAL,
		experimental      = true,
		command           = "ccls",
		required_binaries = {{"ccls", "ccls"}},
	})
}
