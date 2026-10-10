#ifndef TWINE_BRIDGE_H
#define TWINE_BRIDGE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TwineClient TwineClient;

typedef enum TwineStatus {
    TWINE_STATUS_OK = 0,
    TWINE_STATUS_EMPTY = 1,
    TWINE_STATUS_NULL_POINTER = 2,
    TWINE_STATUS_INVALID_UTF8 = 3,
    TWINE_STATUS_MALFORMED_COMMAND = 4,
    TWINE_STATUS_INVALID_ARGUMENT = 5,
    TWINE_STATUS_CURSOR_EXPIRED = 6,
    TWINE_STATUS_INTERNAL_ERROR = 7,
    TWINE_STATUS_PANIC = 8,
    TWINE_STATUS_TERMINAL_NOT_RUNNING = 9,
} TwineStatus;

typedef struct TwineBuffer {
    // Rust-allocated bytes. After a successful bridge call, the caller owns this allocation and
    // must pass the unchanged pointer/length pair to twine_buffer_release exactly once.
    uint8_t *data;
    size_t length;
} TwineBuffer;

typedef struct TwineTerminalChunk {
    uint64_t terminal_id;
    uint64_t offset;
    TwineBuffer bytes;
} TwineTerminalChunk;

// User settings access requires no client or open folder. Reads return a FilePreview JSON;
// saves accept the file-save request and return saved/conflict/failed JSON. Only the configured
// user config file can be saved. Output ownership follows twine_buffer_release.
// Save input is bounded to 12 MiB + 16 KiB; pointer/length rules match twine_client_save_file.
TwineStatus twine_config_file(TwineBuffer *out_file);
// Local memory discovery and reading. Request JSON: {folder?, sourceId?, examplesRoot?}.
// Catalog returns sources and discovery diagnostics; read requires a discovered sourceId.
// No client is needed. Input/ownership rules match send_command and twine_buffer_release.
TwineStatus twine_memory_catalog(const uint8_t *bytes, size_t length, TwineBuffer *out_catalog);
TwineStatus twine_memory_read(const uint8_t *bytes, size_t length, TwineBuffer *out_source);
// Explicit Markdown save: {source: <memory request>, text, expectedVersion, overwrite}.
// Returns saved/conflict/failed JSON. Input bound and pointer rules match save_file;
// no client is needed, and output ownership follows twine_buffer_release.
TwineStatus twine_memory_save(const uint8_t *bytes, size_t length, TwineBuffer *out_result);
TwineStatus twine_config_save_file(const uint8_t *request_bytes, size_t request_length, TwineBuffer *out_result);

// A null out parameter is rejected with TWINE_STATUS_NULL_POINTER. Otherwise it must point to
// aligned, writable storage and must not contain an unreleased bridge allocation. Bridge functions
// initialize valid out parameters to an empty value before work. Every non-null client must be a
// live pointer returned by twine_client_create; calls for a client are serialized, and the client is
// destroyed exactly once after its calls finish. Functions other than destroy reject a null client.
//
// data_directory is the absolute UTF-8 path of the directory where the core keeps its database.
// A path longer than 1024 bytes is rejected without reading data_directory. For a nonzero length at
// or below that limit, a null data_directory is rejected; otherwise it must identify
// data_directory_length readable bytes for the duration of this call.
TwineStatus twine_client_create(
    const uint8_t *data_directory,
    size_t data_directory_length,
    TwineClient **out_client
);
TwineStatus twine_client_destroy(TwineClient *client);

// Same pointer/length contract as twine_client_create. Window clients share durable history,
// but each owns its own folder, event stream, workflows, and processes.
TwineStatus twine_client_create_window(const uint8_t *data_directory, size_t data_directory_length, TwineClient **out_client);

// Returns a caller-owned JSON array of folders to restore. Same contracts as get_snapshot.
TwineStatus twine_client_restorable_folders(TwineClient *client, TwineBuffer *out_result);

// A command larger than 1 MiB is rejected without reading command_bytes. For a nonzero command at
// or below that limit, a null command_bytes is rejected; otherwise it must identify command_length
// readable bytes for the duration of this call.
TwineStatus twine_client_send_command(
    TwineClient *client,
    const uint8_t *command_bytes,
    size_t command_length,
    TwineBuffer *out_response
);

TwineStatus twine_client_snapshot(TwineClient *client, TwineBuffer *out_snapshot);

// Poll expanded directories and a selected file. Same input and ownership rules as send_command.
// Returns EMPTY while a scan is pending or the supplied revision is current (no owned buffer).
TwineStatus twine_client_poll_files(
    TwineClient *client, const uint8_t *request_bytes, size_t request_length, TwineBuffer *out_snapshot
);

// Starts listing a harness's models and effort levels on a core thread; returns at once. Request
// {"harness": "codex" | "claudeCode" | "pi"}, with the same input rules as send_command. Poll until
// it isn't EMPTY: the JSON status is listed (with models) or failed (with message). Destroy exactly
// once; destroying a pending request stops the harness.
typedef struct TwineModelsRequest TwineModelsRequest;
TwineStatus twine_client_request_harness_models(
    TwineClient *client, const uint8_t *request_bytes, size_t request_length, TwineModelsRequest **out_request
);
TwineStatus twine_models_request_poll(TwineModelsRequest *request, TwineBuffer *out_models);
TwineStatus twine_models_request_destroy(TwineModelsRequest *request);

// Saves UTF-8 text through core with version checking. JSON result status is saved, conflict,
// or failed. Allows escaped text up to the 2 MiB file limit; release JSON with twine_buffer_release.
// Pointer rules match send_command; input is bounded to 12 MiB + 16 KiB before dereference.
TwineStatus twine_client_save_file(
    TwineClient *client, const uint8_t *request_bytes, size_t request_length, TwineBuffer *out_result
);

TwineStatus twine_client_events_after(
    TwineClient *client,
    uint64_t sequence,
    uint32_t limit,
    TwineBuffer *out_events
);

// Trace pages contain JSON metadata, never terminal bytes. Limits are 1..200.
// A zero cursor starts at the newest spans or the first events, respectively.
TwineStatus twine_client_workflow_trace(
    TwineClient *client, uint64_t workflow_id, uint64_t before_span_id,
    uint32_t limit, TwineBuffer *out_page
);
TwineStatus twine_client_trace_events(
    TwineClient *client, uint64_t span_id, uint64_t after_event_id,
    uint32_t limit, TwineBuffer *out_page
);
TwineStatus twine_client_trace_activities(
    TwineClient *client, uint64_t span_id, uint64_t after_activity_id,
    uint32_t limit, TwineBuffer *out_page
);

// Full details are UTF-8 pages of 4..65536 bytes. Offsets are UTF-8 boundaries;
// nextOffset is null at the end. Expired detail files return an explicit error.
TwineStatus twine_client_trace_detail(
    TwineClient *client, uint64_t activity_id, bool output, uint64_t offset,
    uint32_t limit, TwineBuffer *out_page
);
// Operations: 0 status, 1 pin, 2 unpin, 3 request background cleanup.
// Status includes clearGeneration and completedClearGeneration as cleanup receipts.
TwineStatus twine_client_trace_storage(
    TwineClient *client, uint64_t span_id, uint32_t operation, TwineBuffer *out_page
);

TwineStatus twine_client_next_terminal_chunk(
    TwineClient *client,
    TwineTerminalChunk *out_chunk
);

// Nonblocking transcript requests. Empty from start means the bounded queue is full; Empty from
// poll means the read is pending. Continue servicing live I/O between attempts. Destroy each request
// once, even when canceled. Poll returns a binary buffer released with twine_buffer_release.
// Little-endian u64 flags: 1 = expired (no other fields), 2 = complete replay prefix available.
// Otherwise u64 offset, next_offset, end_offset, resize_count; then resize_count records of
// u64 byte_offset and u16 rows, columns, pixel_width, pixel_height; then the raw output bytes.
typedef struct TwineTranscriptRequest TwineTranscriptRequest;
TwineStatus twine_client_request_transcript(
    TwineClient *client, uint64_t terminal_id, uint64_t offset, uint32_t limit, TwineTranscriptRequest **out_request
);
TwineStatus twine_transcript_request_poll(TwineTranscriptRequest *request, TwineBuffer *out_page);
TwineStatus twine_transcript_request_destroy(TwineTranscriptRequest *request);

// Sends raw user input to a live terminal. Inputs larger than 64 KiB are rejected without reading
// input_bytes. A null input pointer is valid only when input_length is zero.
// Writes and resizes return TWINE_STATUS_TERMINAL_NOT_RUNNING after the process stops;
// its remaining output and transcript stay readable until the terminal is closed.
TwineStatus twine_client_write_terminal_input(
    TwineClient *client,
    uint64_t terminal_id,
    const uint8_t *input_bytes,
    size_t input_length
);

// Sends terminal-generated protocol replies. Pointer and size contracts match user input.
TwineStatus twine_client_write_terminal_response(
    TwineClient *client,
    uint64_t terminal_id,
    const uint8_t *input_bytes,
    size_t input_length
);

TwineStatus twine_client_resize_terminal(
    TwineClient *client,
    uint64_t terminal_id,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
);

// Releases a caller-owned bridge buffer and clears its fields. An already-empty buffer is accepted.
// A null TwineBuffer pointer is rejected. Otherwise it must identify aligned, writable storage; a
// nonempty pointer/length pair must be unchanged from the successful bridge call that returned it
// and must be released exactly once.
TwineStatus twine_buffer_release(TwineBuffer *buffer);

#ifdef __cplusplus
}
#endif

#endif
