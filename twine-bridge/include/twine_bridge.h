#ifndef TWINE_BRIDGE_H
#define TWINE_BRIDGE_H

#include <stddef.h>
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

TwineStatus twine_client_events_after(
    TwineClient *client,
    uint64_t sequence,
    uint32_t limit,
    TwineBuffer *out_events
);

TwineStatus twine_client_next_terminal_chunk(
    TwineClient *client,
    TwineTerminalChunk *out_chunk
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
