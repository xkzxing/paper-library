# Paper Library

A local-first macOS literature manager for economics research, with a browsable file system, flexible tags, and AI-assisted analysis.

[简体中文](README.md) · English

## Privacy and network access

The app has no first-party accounts, sync service, advertising, or behavioral analytics. Papers and library data stay on the user's device by default. Network requests occur only when the user invokes the relevant feature. AI analysis, smart search, and metadata lookup may send paper excerpts or bibliographic information to third-party services.

Read the full [Privacy Notice](PRIVACY.en.md) before use. Do not use network features with papers that must not be sent to third-party services. For implementation details, data flows, and recovery behavior, see the [Architecture Guide](ARCHITECTURE.en.md).

## Features

- Choose a local library folder and persist access with a security-scoped bookmark.
- Import one or many PDFs without changing the source files.
- Use durable import and move transactions with rollback and crash recovery.
- Extract titles, authors, page counts, years, annotations, and full text.
- Detect duplicates using SHA-256, DOI, NBER, SSRN, arXiv, RePEc, and text fingerprints.
- Keep multiple PDF versions, select a preferred version, and merge or split records.
- Verify metadata through Crossref and display journal metrics from OpenAlex.
- Organize work with dynamic categories, tags, smart lists, combined search, and batch actions.
- Group papers into reading projects with project-specific priority, read state, and sorting.
- Verify individual BibTeX entries online and export batches locally or online.
- Generate structured Gemini research cards with evidence-page checks, cancellation, retries, and budget controls.
- Generate chapter-based Gemini study notes with caching, checkpoints, resume support, and cost estimates.
- Store regular notes and study notes beside each PDF without overwriting existing files.
- Check library health and relocate moved PDFs by SHA-256.
- Recover the library from a manifest, historical manifest backups, or an isolated damaged database.
- Open PDFs with the system default reader or a reader selected by the user.

## Library layout

```text
Library root/
├── Labor/
│   └── 2024/
│       └── Doe - 2024 - Paper Title/
│           ├── Doe - 2024 - Paper Title.pdf
│           ├── Doe - 2024 - Paper Title.md
│           ├── Doe - 2024 - Paper Title.assets/
│           ├── Doe - 2024 - Paper Title-study-notes.md
│           └── Doe - 2024 - Paper Title-study-notes.assets/
├── Uncategorized/
│   └── Unknown Year/
└── .paperlib/
    ├── library.json
    ├── manifest.json
    ├── imports/
    ├── operations/
    └── backups/
```

When a reliable title, author, or year cannot be extracted, the PDF keeps its original filename and is placed in `Uncategorized/Unknown Year/`. After the user confirms metadata or it is verified online, the app organizes the folder by author, year, and title.

## Search, projects, and exports

Search can target titles, authors, bibliographic fields, research content, identifiers, and file fields. It supports all terms, any term, exact phrases, and combined filters for year, review status, analysis status, abstracts, annotations, multiple versions, and missing DOIs.

Smart search combines BM25, semantic vectors, and bibliographic ranking within the current project, category, and tag scope, then reranks candidates with Qwen 3.7. Candidates are consolidated by paper so that long papers do not crowd out other results. Choose fast, balanced, or deep search and set the result limit to 5, 10, or 20 papers.

Projects store reading organization only; they do not move or copy PDFs. A paper can belong to multiple projects.

Batch BibTeX export has two modes:

- **Use library records** exports only confirmed entries without unresolved issues.
- **Verify online** looks up records using DOI, Crossref, and Semantic Scholar, then presents discrepancies together.

Invalid entries are skipped and reported in the completion summary; they do not block the rest of the export.

## AI settings

In Settings, enter a Gemini API key, fast-model name, monthly budget, and current token prices. The default fast model is `gemini-3.5-flash-lite`; study notes use `gemini-3.1-pro-preview`. Keys are stored in a private local file in the app's sandbox, readable and writable only by the current user.

By default, automatic analysis sends only the first 60 pages of papers longer than 200 pages. You can also skip automatic analysis in Settings. Research-card uploads are limited to 50 MB per PDF. Update price settings based on provider announcements.

AI failures do not block PDF import, search, filing, or opening papers externally. Study-note checkpoints are retained so generation can resume from the next section.

## Backup, recovery, and library health

At launch, the app recovers unfinished imports and file moves, checks registered PDFs, and attempts to relocate missing files by SHA-256. In **Settings → Library Maintenance**, run a manual check and review the counts for checked, relocated, repaired, and still-missing files. Missing files remain in the problem list.

`.paperlib/manifest.json` records papers, categories, tags, projects, file versions, and analysis state, and keeps the ten most recent historical backups. If the database is damaged, the original database and logs are safely quarantined before a new database is created and restored from the manifest where possible.

## Build and test

- Xcode 26.6 or a compatible version
- macOS 14 or later

Open `PaperLibrary.xcodeproj` and run the `PaperLibrary` scheme.

Run unit tests from the command line:

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project PaperLibrary.xcodeproj \
  -scheme PaperLibrary \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -only-testing:PaperLibraryTests \
  test
```

Smart-search embeddings and reranking use Qwen 3.7 through the Beijing region of Bailian. The app no longer includes a local model runtime or model-download dependency. Existing vectors can be reused across all three search depths; changing the result limit does not require rebuilding the index.

Tests cover import and rollback, batch file safety, move recovery, duplicate detection, file naming, search, BibTeX, AI results, study-note checkpoints, cost estimates, manifest recovery, and library health checks.

This repository does not include an individual signing identity, release script, or signed application bundle. Anyone distributing the app must perform signing and verification independently and must not commit certificates, private keys, or machine-specific configuration.

## License

This project is licensed under the [MIT License](LICENSE). See [Third-Party Notices](THIRD_PARTY_NOTICES.en.md) for dependency information.
