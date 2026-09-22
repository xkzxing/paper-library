# Architecture Guide

[简体中文](ARCHITECTURE.md) · English

This guide is for readers who want to understand the design, assess privacy boundaries, or help maintain the project. It explains how features work together, where data is stored, and how failures are recovered without requiring a source-code tour.

## 1. Overall design

The app treats the local library as the source of truth for files and the app database as a recoverable index.

- The user chooses an ordinary folder as the library. PDFs, regular notes, and study notes remain there and can be browsed in Finder.
- SwiftData stores paper records, categories, tags, reading projects, file versions, and AI task state.
- `.paperlib/manifest.json` is a portable library manifest. The app exports it after important saves and retains a limited set of historical copies.
- Imports, moves, and recovery use paths relative to the library root rather than storing absolute paths in the database. A shared path-safety layer resolves and validates each path when needed.

```text
User selects a library
      │
      ├── Library files: PDFs, notes, .paperlib manifest and operation records
      │
      └── App database: paper relationships, UI state, task state and search index
                         │
                         └── Manifest export / restore after database damage
```

The main entry point is `PaperLibrary/App/PaperLibraryApp.swift`. It creates the app database and injects library access, file-health, and search coordinators. The main window displays the library; Settings handles library selection, network services, and search configuration.

## 2. Startup and library access

### Selecting a library

The user chooses a library folder through the system file picker. The app creates a security-scoped bookmark for the folder and stores the bookmark and library identifier in user preferences. On the next launch, it restores the bookmark before accessing the folder.

Each library root contains `.paperlib/library.json`, which records a unique identifier, schema version, and creation time. When a folder is selected again, the app checks this identifier to avoid connecting the database to a different library by mistake.

### Path safety

`LibraryPathSafety` validates all relative paths. It rejects absolute paths, home-directory shortcuts, empty paths, `.`, `..`, symbolic links, and paths that resolve outside the library. A PDF that is about to be opened is also checked for its extension and regular-file status.

This prevents a damaged manifest or database from directing the app outside the library, and ensures that file moves, recovery, and health checks follow the same boundary rules.

### Startup recovery order

When the library view starts, maintenance runs in this order:

1. Read the manifest and restore recoverable records if the database is empty or needs recovery.
2. Scan unfinished import transactions, remove invalid temporary files, or complete records that can be confirmed.
3. Check that registered PDFs still exist; for missing files, search the library for a matching SHA-256.
4. Mark AI analysis and study-note tasks interrupted by a previous failure as recoverable.
5. Rebuild or incrementally update the full-text search index.

If SwiftData cannot open its database because of corruption, migration failure, or incompatibility, the app first moves the database and its logs to an isolated location in Application Support. It then creates a new database and attempts to restore it from the library manifest. Keeping the damaged store makes investigation and recovery easier than deleting it outright.

## 3. Core data model

| Object | Purpose | Main relationships |
| --- | --- | --- |
| Paper | Stores title, authors, year, identifiers, journal data, status, and metadata verification results | May have multiple file versions, tags, personal marks, reading projects, analyses, and study-note tasks |
| File version | Stores relative path, hash, page count, size, import time, and preferred-version status | Belongs to one paper |
| Category and tag | Categories provide a primary filing location; tags support multi-dimensional filtering | A paper may have multiple tags |
| Reading project | Stores reading organization, priority, order, and read state | A paper may belong to multiple projects |
| AI analysis | Stores a structured research card, source file version, usage, cost, and error state | Belongs to one paper |
| Study-note task | Stores plan, progress, resume data, usage, and output state | Belongs to one paper |

A paper and a PDF are not a one-to-one pair. One paper can have several file versions, such as a preprint, revision, or appendix, and the user can choose a preferred version. This lets merge, split, duplicate detection, and reprocessing work at the file-version level without copying the entire paper record.

## 4. Import, filing, and duplicate detection

### Import flow

After the import coordinator receives one or more files, it:

1. Verifies that each input is a readable PDF and uses PDFKit to extract title, authors, abstract, page count, year, and detectable identifiers such as DOI.
2. Computes SHA-256, file size, and page count to create a review candidate.
3. Looks for duplicates using hashes, DOI, NBER, SSRN, arXiv, RePEc, and text fingerprints.
4. Lets the user create a new paper, merge the file as another version, or skip the candidate.
5. Builds a destination-relative path from category, author, year, and title. If metadata is insufficient, it uses `Uncategorized/Unknown Year/` and preserves the original filename.
6. Copies the file through staging and commit steps tagged with a transaction ID, writes records, saves the database, and then removes the staging state.

The original source file is never moved or renamed. Once the import finishes, the copy inside the library becomes the managed version.

### Rename and move

When metadata, category, or filing location changes, the app performs moves in batches. A PDF's regular note, study note, and associated asset folders are treated as companion files and move with it. The app records source and destination paths before the move and attempts a rollback on failure. On the next launch, operation records can guide cleanup or recovery.

### Delete, merge, and split

Deleting a paper handles its related file versions and relationships. Merge consolidates duplicate paper records; split moves selected file versions to a new paper. Both operations work at the file-version level and do not alter the PDF contents.

## 5. Manifest, backups, and library health

### Manifest

The manifest has its own schema version and contains the library ID, papers, file versions, categories, tags, projects, AI state, and required relationships. It is stored as formatted JSON at `.paperlib/manifest.json`, with recent historical copies in `.paperlib/backups/`.

Export uses a temporary file followed by an atomic replacement so an interrupted write does not leave half a JSON document. The UI observes database-save events and coalesces consecutive changes to reduce disk writes; it exports immediately when the app moves to the background.

### Health checks

Health checks only traverse the library. The app validates each recorded relative path first. If a PDF is missing, it then searches the library for a file with the same SHA-256. A match updates the relative path. If no match is found, the issue remains visible for the user; records are not deleted speculatively.

## 6. Search and smart retrieval

### Basic search

Basic search combines titles, authors, years, abstracts, identifiers, file paths, and full-text passages. It supports all terms, any term, exact phrases, and several status filters. The UI first limits the search to the current category, tags, or reading project, then returns paper-level results.

### Full-text index

The text extractor reads PDFs page by page and splits their text into passages with page ranges. A separate SQLite index stores:

- Paper and file-version identifiers.
- Passage order, start and end pages, original text, and normalized text.
- File SHA-256 and path, so the app can determine whether the index is still valid.
- Vectors and their model-version information.

When a file is imported, deleted, replaced, or moved, the coordinator invalidates and updates only the affected papers' indexes rather than rebuilding the whole library.

### Smart search

Smart search has three stages:

```text
Query
  │
  ├── Keyword and bibliographic scoring
  ├── Similarity retrieval using query and passage vectors
  └── Candidate fusion, deduplication by paper, and remote reranking
                                      │
                                      └── Results with page numbers and passages
```

Embeddings and reranking use Bailian. The app sends candidate passages in batches for embedding generation and stores normalized vectors locally. At query time it sends the query text, uses cosine similarity to select a limited candidate set, and then sends the query and candidate passages to the reranking service. Results are consolidated into one entry per paper with several evidence passages.

Fast, balanced, and deep modes change candidate counts, character budgets, and reranking scope, not the source text in the library. Candidate limits control memory use and cost. The flow also supports cancellation, retries, and progress reporting.

## 7. Metadata and citation export

### Local extraction and online verification

PDF import starts with local parsing. When the user requests verification, the Crossref client looks up a DOI first. If no DOI is available, it searches by title, authors, and year and applies similarity matching. A dedicated applier writes verified fields back to the paper. Conflicts are surfaced rather than silently overwriting user-confirmed data.

Journal metrics are retrieved from OpenAlex, cached as JSON in the paper record, and stored with the last lookup time so list views do not need a network request every time.

### BibTeX export

The local exporter builds citation keys and entries from paper records. Online verification first tries DOI content negotiation and falls back to a Semantic Scholar search if needed. The remote record is parsed and compared field by field with the local title, authors, year, and journal. The UI shows differences, and the user confirms before exporting or updating.

Network requests use limited retries for timeouts, rate limits, and server errors, and can be cancelled.

## 8. AI research cards and study notes

### Research cards

The Gemini analyzer creates research cards. Before a request, the app checks for an API key, file readability, file size, the user's monthly budget, and the long-document policy. By default, only the first configured number of pages is sent for papers over the page threshold; automatic analysis can also be skipped.

The analyzer uploads the PDF or an excerpt and requests structured fields such as research question, methods, data, findings, limitations, and evidence page numbers. A page normalizer maps returned page numbers to actual PDF pages and marks references it cannot verify. Results, usage, estimated cost, and error state are saved in the AI analysis record.

Batch analysis uses controlled concurrency and a shared request gate to avoid too many long uploads at once. Cancelling analysis does not affect local paper files.

### Study notes

Study notes are designed for long documents:

1. Upload the PDF and wait for the remote file to become available.
2. Create or reuse remote cached content and generate a chapter plan.
3. Request each section in order and append streaming responses to a local checkpoint.
4. Record progress, token usage, and cost after each section.
5. On success, export a Markdown note beside the PDF. On failure or cancellation, retain the incomplete note and checkpoint.

Checkpoints live in a hidden task directory beside the PDF and record the task ID, completed sections, and plan. After restart, running tasks are marked interrupted. If a checkpoint is available, the user can resume from the next section without repeating completed work.

## 9. Notes, projects, and UI state

Regular notes and study notes are Markdown files beside the PDF. A safe default is used when a note is first created; an existing file is never overwritten. Companion asset directories are managed alongside the PDF as well.

Reading projects store organizational relationships such as project membership, priority, read state, and order. They do not copy or move PDFs. Categories, tags, personal marks, sidebar selection, sorting, and search preferences are stored in the app database or user preferences.

## 10. Network and privacy boundaries

The app enables sandboxing, read and write access to user-selected folders, read and write access to Downloads, and outbound network access. It has no first-party accounts, sync, advertising, or behavioral analytics.

| Feature | Service | Data that may be sent |
| --- | --- | --- |
| Metadata lookup | Crossref, OpenAlex, DOI, Semantic Scholar | DOI, title, authors, year, journal, and other bibliographic information |
| Research cards and study notes | Gemini | PDF or excerpts, prompts, and model request parameters |
| Smart search | Bailian | Query, candidate text passages, workspace identifier, and authorization request |

API keys are not stored in the repository. The current implementation stores them in private files in Application Support, with directory permissions `0700` and file permissions `0600`. Users should review each third-party provider's policies and avoid uploading papers that must remain private.

See the [Privacy Notice](PRIVACY.en.md) for the user-facing explanation.

## 11. Tests and maintenance entry points

Tests cover import and rollback, duplicate detection, move recovery, notes, manifest recovery, metadata, citation export, AI results, study-note checkpoints, search selection, and library health. Unit tests use an in-memory database and temporary libraries to avoid reading real papers.

| Area | Main directory |
| --- | --- |
| UI and interactions | `PaperLibrary/Features/` |
| Paper models and filing rules | `PaperLibrary/Domain/` |
| File import, moves, recovery, and health | `PaperLibrary/Services/FileStore/` |
| Metadata and citation services | `PaperLibrary/Services/Metadata/` |
| AI analysis and study notes | `PaperLibrary/Services/AI/` |
| Full-text and smart search | `PaperLibrary/Services/Search/` |
| Manifest backup and recovery | `PaperLibrary/Persistence/Backup/` |

When changing file formats, network requests, permissions, or AI data transfers, update this guide, the privacy notice, and relevant tests.
