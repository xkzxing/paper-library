# Privacy Notice

[简体中文](PRIVACY.md) · English

## Overview

Paper Library is local-first. It has no first-party account system, sync service, advertising, or behavioral analytics. The selected library, imported papers, and locally generated notes and indexes remain on the user's device by default.

## Information stored locally

The app stores papers, notes, indexes, import and move records, backup manifests, and necessary bibliographic information in the user-selected library. API keys entered in Settings are stored in a private local directory within the app's sandbox. The directory is accessible only to the current user. Keys are not uploaded to servers operated by this project's maintainers.

## Network features and data sent

Third-party services are contacted only when the user invokes the relevant feature or enables the corresponding processing:

- Metadata lookup may send DOIs, titles, authors, years, and other bibliographic information to Crossref, OpenAlex, Semantic Scholar, or DOI services.
- Gemini research cards and study notes may send a PDF or selected pages, prompts, and model request parameters for analysis, according to the user's settings.
- Smart search may send search queries, candidate text passages used for embeddings or reranking, and required request parameters to Bailian.

Third-party providers handle received data under their own privacy policies. Do not use network analysis or smart search with papers that must not be transmitted to those services.

## User controls and deletion

Users can delete files, notes, indexes, and backups from the library, remove API keys in Settings, or turn off network features. Deleting local data does not automatically delete data previously sent to third-party services; such data is subject to each provider's policies and controls.

## Contact and updates

This notice is distributed with the source code. When reporting a security issue, do not include API keys, paper text, or other personal data in a public issue.
