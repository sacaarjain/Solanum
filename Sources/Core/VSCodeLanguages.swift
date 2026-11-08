import Foundation

/// VS Code's language ids by file extension and by whole file name, from the `contributes.languages` of the
/// extensions built into VS Code (microsoft/vscode, extensions/*/package.json), plus popular Marketplace languages
/// (Kotlin, TOML, Vue, Svelte…). Icon packs map many files by language (`languageIds`) rather than by extension.
enum VSCodeLanguages {
    static func id(forFileName name: String) -> String? {
        let lower = name.lowercased()
        if let id = fileNames[lower] { return id }
        // Longest extension first: "d.ts" before "ts".
        var i = lower.startIndex
        while let dot = lower[i...].firstIndex(of: ".") {
            if let id = extensions[String(lower[lower.index(after: dot)...])] { return id }
            i = lower.index(after: dot)
        }
        return nil
    }

    static let extensions: [String: String] = [
        "agent.md": "chatagent", "ascx": "xml", "asp": "html", "aspx": "html", "astro": "astro", "atom": "xml", "axaml": "xml",
        "axml": "xml", "babelrc": "jsonc", "bas": "vb", "bash": "shellscript", "bash_aliases": "shellscript", "bash_login": "shellscript",
        "bash_logout": "shellscript", "bash_profile": "shellscript", "bashrc": "shellscript", "bat": "bat", "bbx": "tex", "bib": "bibtex",
        "bowerrc": "json", "bpmn": "xml", "brs": "vb", "c": "c", "c++": "cpp", "c++m": "cpp", "cake": "csharp", "cbx": "tex", "cc": "cpp",
        "ccm": "cpp", "cff": "yaml", "cfg": "properties", "cginc": "hlsl", "chatmode.md": "chatagent", "cjs": "javascript",
        "clj": "clojure", "cljc": "clojure", "cljs": "clojure", "cljx": "clojure", "clojure": "clojure", "cls": "tex", "cmd": "bat",
        "code-profile": "json", "code-search": "search-result", "code-snippets": "snippets", "code-workspace": "jsonc",
        "coffee": "coffeescript", "color-theme.json": "jsonc", "compute": "hlsl", "conf": "properties", "containerfile": "dockerfile",
        "copilot-instructions.md": "instructions", "copilotmd": "markdown", "cpp": "cpp", "cppm": "cpp", "cpt": "xml", "cpy": "python",
        "cs": "csharp", "csh": "shellscript", "cshrc": "shellscript", "cshtml": "razor", "csl": "xml", "cson": "coffeescript",
        "csproj": "xml", "csproj.user": "xml", "css": "css", "css.map": "json", "csx": "csharp", "ctp": "php", "cts": "typescript",
        "ctx": "latex", "cu": "cuda-cpp", "cuh": "cuda-cpp", "cxx": "cpp", "cxxm": "cpp", "dart": "dart", "diff": "diff",
        "directory": "properties", "dita": "xml", "ditamap": "xml", "dockerfile": "dockerfile", "dsql": "sql", "dtd": "xml", "dtml": "xml",
        "ebuild": "shellscript", "eclass": "shellscript", "editorconfig": "properties", "edn": "clojure", "ejs": "html", "ent": "xml",
        "env": "dotenv", "erb": "ruby", "erl": "erlang", "es6": "javascript", "eslintrc": "jsonc", "eslintrc.json": "jsonc",
        "ex": "elixir", "exs": "elixir", "eyaml": "yaml", "eyml": "yaml", "fish": "shellscript", "fs": "fsharp", "fsi": "fsharp",
        "fsproj": "xml", "fsscript": "fsharp", "fsx": "fsharp", "fx": "hlsl", "fxh": "hlsl", "fxml": "xml", "gemspec": "ruby",
        "geojson": "json", "git-blame-ignore-revs": "ignore", "gitattributes": "properties", "gitconfig": "properties",
        "gitignore": "ignore", "gitignore_global": "ignore", "gitmodules": "properties", "go": "go", "gql": "graphql", "gradle": "groovy",
        "graphql": "graphql", "groovy": "groovy", "gvy": "groovy", "gyp": "python", "gypi": "python", "h": "cpp", "h++": "cpp",
        "h.in": "cpp", "handlebars": "handlebars", "har": "json", "hbs": "handlebars", "hh": "cpp", "hintrc": "jsonc", "hjs": "handlebars",
        "hlsl": "hlsl", "hlsli": "hlsl", "hpp": "cpp", "hpp.in": "cpp", "hrl": "erlang", "hs": "haskell", "htm": "html", "html": "html",
        "hxx": "cpp", "i": "c", "iced": "coffeescript", "icon-theme.json": "jsonc", "ii": "cpp", "iml": "xml", "ini": "ini", "inl": "cpp",
        "ino": "cpp", "instructions.md": "instructions", "ipp": "cpp", "ipy": "python", "ipynb": "json", "isml": "xml", "ixx": "cpp",
        "jade": "jade", "jav": "java", "java": "java", "jenkinsfile": "groovy", "jl": "julia", "jmd": "juliamarkdown", "jmx": "xml",
        "js": "javascript", "js.map": "json", "jscsrc": "json", "jsfmtrc": "jsonc", "jshintrc": "jsonc", "jshtm": "html",
        "jslintrc": "json", "json": "json", "jsonc": "jsonc", "jsonl": "jsonl", "jsonld": "json", "jsp": "html", "jsx": "javascriptreact",
        "ksh": "shellscript", "kt": "kotlin", "kts": "kotlin", "language-configuration.json": "jsonc", "launch": "xml", "less": "less",
        "lhs": "haskell", "litcoffee": "markdown", "log": "log", "ltx": "latex", "lua": "lua", "m": "objective-c", "mak": "makefile",
        "markdn": "markdown", "markdown": "markdown", "md": "markdown", "mdoc": "html", "mdown": "markdown", "mdtext": "markdown",
        "mdtxt": "markdown", "mdwn": "markdown", "menu": "xml", "mjs": "javascript", "mk": "makefile", "mkd": "markdown",
        "mkdn": "markdown", "mm": "objective-cpp", "mod": "xml", "mpp": "cpp", "mts": "typescript", "mxml": "xml", "mxx": "cpp",
        "ndjson": "jsonl", "nf": "groovy", "nim": "nim", "npmignore": "ignore", "npmrc": "properties", "nqp": "raku", "nuspec": "xml",
        "opml": "xml", "owl": "xml", "p6": "raku", "pac": "javascript", "patch": "diff", "php": "php", "php4": "php", "php5": "php",
        "phtml": "php", "pl": "perl", "pl6": "raku", "pm": "perl", "pm6": "raku", "pod": "perl", "podspec": "ruby", "prisma": "prisma",
        "profile": "shellscript", "proj": "xml", "prompt.md": "prompt", "properties": "properties", "props": "xml", "proto": "proto3",
        "ps1": "powershell", "psd1": "powershell", "psgi": "perl", "psh": "hlsl", "psm1": "powershell", "psrc": "powershell",
        "pssc": "powershell", "pt": "xml", "publishsettings": "xml", "pubxml": "xml", "pubxml.user": "xml", "pug": "jade", "py": "python",
        "pyi": "python", "pyt": "python", "pyw": "python", "r": "r", "rake": "ruby", "raku": "raku", "rakudoc": "raku", "rakumod": "raku",
        "rakutest": "raku", "razor": "razor", "rb": "ruby", "rbi": "ruby", "rbx": "ruby", "rbxlx": "xml", "rbxmx": "xml", "rdf": "xml",
        "rej": "diff", "repo": "properties", "rhistory": "r", "rhtml": "html", "rjs": "ruby", "rng": "xml", "ron": "markdown",
        "ronn": "markdown", "rprofile": "r", "rpy": "python", "rs": "rust", "rss": "xml", "rst": "restructuredtext", "rt": "r",
        "ru": "ruby", "sbt": "scala", "sc": "scala", "scala": "scala", "scss": "scss", "sh": "shellscript", "shader": "shaderlab",
        "shproj": "xml", "shtml": "html", "slnx": "xml", "sol": "solidity", "sql": "sql", "storyboard": "xml", "sty": "tex",
        "svelte": "svelte", "svg": "xml", "swcrc": "jsonc", "swift": "swift", "t": "perl", "targets": "xml", "tcshrc": "shellscript",
        "tex": "latex", "tf": "terraform", "tfvars": "terraform", "tld": "xml", "tmx": "xml", "toml": "toml", "toolset.jsonc": "jsonc",
        "tpp": "cpp", "ts": "typescript", "ts.map": "json", "tsbuildinfo": "json", "tsx": "typescriptreact", "txx": "cpp", "vb": "vb",
        "vba": "vb", "vbproj": "xml", "vbproj.user": "xml", "vbs": "vb", "vcxproj": "xml", "vcxproj.filters": "xml", "volt": "html",
        "vsh": "hlsl", "vue": "vue", "vuerc": "json", "webmanifest": "json", "winget": "yaml", "wixproj": "xml", "workbook": "markdown",
        "wsdl": "xml", "wxi": "xml", "wxl": "xml", "wxs": "xml", "xaml": "xml", "xbl": "xml", "xht": "html", "xhtml": "html", "xib": "xml",
        "xlf": "xml", "xliff": "xml", "xml": "xml", "xoml": "xml", "xpdl": "xml", "xprofile": "shellscript", "xsd": "xml",
        "xsession": "shellscript", "xsessionrc": "shellscript", "xsl": "xsl", "xslt": "xsl", "xul": "xml", "yaml": "yaml",
        "yaml-tmlanguage": "yaml", "yaml-tmpreferences": "yaml", "yaml-tmtheme": "yaml", "yash_profile": "shellscript",
        "yashrc": "shellscript", "yml": "yaml", "zig": "zig", "zlogin": "shellscript", "zlogout": "shellscript", "zprofile": "shellscript",
        "zsh": "shellscript", "zsh-theme": "shellscript", "zshenv": "shellscript", "zshrc": "shellscript",
    ]

    static let fileNames: [String: String] = [
        ".babelrc.json": "jsonc", ".devcontainer.json": "jsonc", ".ember-cli": "jsonc", ".env": "dotenv", ".envrc": "shellscript",
        ".flaskenv": "dotenv", ".hushlogin": "shellscript", ".vscodeignore": "ignore", ".watchmanconfig": "json",
        "apkbuild": "shellscript", "appfile": "ruby", "appraisals": "ruby", "argv.json": "jsonc", "babel.config.json": "jsonc",
        "bashrc_apple_terminal": "shellscript", "berksfile": "ruby", "berksfile.lock": "ruby", "brewfile": "ruby", "bun.lock": "jsonc",
        "capfile": "ruby", "cheffile": "ruby", "commit_editmsg": "git-commit", "composer.lock": "json", "containerfile": "dockerfile",
        "dangerfile": "ruby", "deliverfile": "ruby", "devcontainer.json": "jsonc", "dockerfile": "dockerfile", "extensions.json": "jsonc",
        "fastfile": "ruby", "gemfile": "ruby", "git-rebase-todo": "git-rebase", "gitconfig": "properties", "gnumakefile": "makefile",
        "guardfile": "ruby", "gymfile": "ruby", "hobofile": "ruby", "jakefile": "javascript", "jenkinsfile": "groovy",
        "jsconfig.json": "jsonc", "keybindings.json": "jsonc", "launch.json": "jsonc", "makefile": "makefile", "matchfile": "ruby",
        "mcp.json": "jsonc", "merge_msg": "git-commit", "ocamlmakefile": "makefile", "pkgbuild": "shellscript", "podfile": "ruby",
        "profiles.json": "jsonc", "puppetfile": "ruby", "rakefile": "ruby", "rantfile": "ruby", "scanfile": "ruby", "sconscript": "python",
        "sconstruct": "python", "settings.json": "jsonc", "skill.md": "skill", "snapfile": "ruby", "tasks.json": "jsonc",
        "thorfile": "ruby", "tsconfig.json": "jsonc", "typedoc.json": "jsonc", "user-dirs.dirs": "dotenv", "vagrantfile": "ruby",
        "zlogin": "shellscript", "zlogout": "shellscript", "zprofile": "shellscript", "zshenv": "shellscript", "zshrc": "shellscript",
        "zshrc_apple_terminal": "shellscript",
    ]
}
