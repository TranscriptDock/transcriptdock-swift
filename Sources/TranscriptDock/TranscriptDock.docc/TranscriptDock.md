# ``TranscriptDock``

An async client for the Transcript Dock video transcription API.

## Overview

Create a ``TranscriptDock/TranscriptDock`` client with your API key, submit a job
with an idempotency key, then poll it with
``TranscriptDock/TranscriptDock/waitForJob(_:timeout:pollInterval:)``.
Responses are `[String: JSONValue]` dictionaries that keep every field the API
returns. The client never retries requests and never follows redirects.

Creating a job can spend credits. Generate one idempotency key per intended
operation and save it with the returned job ID. If a response is lost, check the
job or replay the same body with the same key.

See the [API documentation](https://www.transcriptdock.com/docs) and the
[OpenAPI definition](https://www.transcriptdock.com/docs/openapi.yaml).

## Topics

### Client

- ``TranscriptDock/TranscriptDock``

### Values

- ``JSONValue``

### Errors

- ``ApiError``
- ``JobTimeoutError``
- ``TranscriptDockError``
