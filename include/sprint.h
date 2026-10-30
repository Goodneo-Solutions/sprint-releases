/*
 * sPrint — Superroute's printing SDK, C interface (sPrint core 0.1.x).
 *
 * One library per OS / architecture: libsprint.dylib (macOS), libsprint.so
 * (Linux, Raspberry Pi), sprint.dll (Windows), or the static libsprint.a.
 *
 * Conventions
 *  - Structured values cross as UTF-8 JSON in the shapes of the Go API:
 *    TargetPrinter, LabelJob, PrintJob (its "data" is base64), PrintResult,
 *    DiscoveredPrinter, NodeState. See docs/DESIGN.md §4.
 *  - Every char* and unsigned char* sPrint returns is owned by the caller and
 *    freed with sprint_free(). Strings passed in are only read during the call.
 *  - Functions returning int: 0 (or a non-negative value) on success, -1 on
 *    failure with *err set (when err is not NULL) to a message to free.
 *  - Handles (registry, node) are opaque non-zero int64 values; 0 is failure.
 *  - All functions are safe to call from any thread. Event callbacks run on a
 *    thread sPrint owns; copy what you need, do not block.
 */
#ifndef SPRINT_H
#define SPRINT_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(SPRINT_STATIC)
#  define SPRINT_API __declspec(dllimport)
#else
#  define SPRINT_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Basics */
SPRINT_API char* sprint_version(void);
SPRINT_API void  sprint_free(void* p);
/* JSON array of the command languages sPrint encodes into. */
SPRINT_API char* sprint_languages(void);
/* Cuts the print in flight; 1 when something was printing. */
SPRINT_API int   sprint_stop(void);

/* Encoding: the bytes a printer takes, without sending them. */
SPRINT_API int sprint_encode_label(const char* target_json, const char* label_json, int copies,
                                   unsigned char** out, size_t* out_len, char** err);
/* img: a PNG, JPEG or GIF file's bytes (a rendered PDF / HTML page, a photo). */
SPRINT_API int sprint_encode_image(const char* target_json, const unsigned char* img, size_t img_len, int copies,
                                   unsigned char** out, size_t* out_len, char** err);
/* The agent's one-page A4 test document (PDF). */
SPRINT_API int sprint_test_page_pdf(const char* subtitle, unsigned char** out, size_t* out_len);
SPRINT_API int sprint_self_test(const char* language, const char* text, unsigned char** out, size_t* out_len);

/* Printing to a printer described inline: returns a PrintResult JSON. */
SPRINT_API char* sprint_print(const char* target_json, const char* job_json);

/* Registry: path "" keeps it in memory; otherwise it is loaded from and saved to path. */
SPRINT_API long long sprint_registry_open(const char* path, char** err);
SPRINT_API void      sprint_registry_close(long long registry);
/* {"default": "...", "printers": [TargetPrinter...]} */
SPRINT_API char*     sprint_registry_list(long long registry);
/* The next three return {"ok": bool, "error": "..."}. */
SPRINT_API char*     sprint_registry_save(long long registry, const char* target_json);
SPRINT_API char*     sprint_registry_remove(long long registry, const char* name);
SPRINT_API char*     sprint_registry_set_default(long long registry, const char* name);
/* Runs a PrintJob on the printer it names (or the default); PrintResult JSON. */
SPRINT_API char*     sprint_registry_print(long long registry, const char* job_json);

/* Fallback chain for label jobs (stream → raw → driver → html), off by default. */
SPRINT_API int       sprint_registry_set_fallback(long long registry, int on);
SPRINT_API char*     sprint_registry_fallback_state(long long registry, const char* name);
SPRINT_API void      sprint_registry_reset_fallback(long long registry, const char* name);
/* The superprinter.probe/1 report of a registry printer (or {"error"}). */
SPRINT_API char*     sprint_registry_probe_report(long long registry, const char* name);

/* Discovery: each returns {"printers": [DiscoveredPrinter...], "error": "..."}. */
SPRINT_API char* sprint_local_prefixes(void); /* JSON array, e.g. ["192.168.1"] */
SPRINT_API char* sprint_scan_network(const char* prefix /* "" = every local /24 */, int timeout_ms);
SPRINT_API char* sprint_system_printers(void);
SPRINT_API char* sprint_usb_printers(void);
SPRINT_API char* sprint_bluetooth_printers(int scan_ms /* 0 = bonded only */);
SPRINT_API char* sprint_ble_printers(int scan_ms);
/* Both Bluetooth transports at once, each printer once: "transports" lists what it
   was seen on, "hosts" its address on each, transport/host are the preferred one. */
SPRINT_API char* sprint_nearby_bluetooth_printers(int scan_ms);
/* 1 when a Bluetooth device is a printer candidate (services: JSON array or NULL;
   class_of_device 0 when unknown). The rule every layer uses. */
SPRINT_API int   sprint_looks_like_printer(const char* name, const char* services_json, int class_of_device);
/* Folds the classic and LE sightings of one printer into one entry: {"printers": [...]}. */
SPRINT_API char* sprint_merge_bluetooth(const char* printers_json);

/* Identification */
SPRINT_API char* sprint_identify(const char* keys_json);   /* {"ok", "identity"} */
SPRINT_API char* sprint_probe(const char* target_json);
/* The whole identification ladder without paper (device ID, model table, IPP, status): {"ok", "identity"}. */
SPRINT_API char* sprint_identify_printer(const char* target_json);
/* Asks the printer, else prints one test line per language; first line "detected <language> …" when it answered. */
SPRINT_API char* sprint_detect_language(const char* target_json);    /* {"ok", "probe": null | {language, evidence}} */
/* Loads a model table revision (GET /api/odep/printer-models); returns the active revision. */
SPRINT_API int   sprint_load_model_table(const char* json, char** err);

/* Native layer: a host's own transport (Bluetooth, BLE, USB stacks) and renderer.
   Buffers and error strings a callback hands back (out, png, err) are allocated
   with malloc by the host and freed by sPrint. A callback returns 0 on success.
   Callbacks run on threads sPrint owns. */
typedef int (*sprint_send_cb)(const char* target_json, const unsigned char* data, size_t len, char** err, void* user);
/* Writes cmd and answers what came back until the link was quiet for quiet_ms or
   overall_ms passed; an empty answer (*out NULL) is not an error. NULL: no read-back. */
typedef int (*sprint_query_cb)(const char* target_json, const unsigned char* cmd, size_t len, int quiet_ms, int overall_ms,
                               unsigned char** out, size_t* out_len, char** err, void* user);
/* 1 when the printer looks able to take a job again (checked without paper). NULL: always 1. */
typedef int (*sprint_reachable_cb)(const char* target_json, void* user);
/* kind 0: data is a PDF (draw its first page); kind 1: data is UTF-8 HTML (base_url for its links).
   Draw at width_dots (0 = natural) × height_dots (0 = as long as needed) and answer a PNG. */
typedef int (*sprint_render_cb)(int kind, const unsigned char* data, size_t len, const char* base_url, int width_dots,
                                int height_dots, unsigned char** png, size_t* png_len, char** err, void* user);
/* Registers (or with send NULL removes) the transport for a name: bluetooth, ble, usb, or a host's own. */
SPRINT_API int sprint_register_transport(const char* name, sprint_send_cb send, sprint_query_cb query,
                                         sprint_reachable_cb reachable, void* user);
/* A host's scanner for a transport (ble, bluetooth): answers {"printers": [...]} or
   {"error"} as a malloc'ed string; sPrint keeps the printers among them. NULL removes it.
   iOS registers its CoreBluetooth scan so every binding lists BLE printers there. */
typedef char* (*sprint_scan_cb)(int scan_ms, void* user);
SPRINT_API int sprint_register_scanner(const char* transport, sprint_scan_cb scan, void* user);
/* Installs the host's renderer (NULL restores the built-in desktop one). */
SPRINT_API int sprint_set_renderer(sprint_render_cb render, void* user);

/* Print node */
/* Events: {"type":"state","state":NodeState} (persist it), {"type":"job","job_id","result"},
   {"type":"log","message"}, {"type":"sweep","sweep":SweepView} (a protocol sweep changed). */
typedef void (*sprint_event_cb)(const char* event_json, void* user);
/* config_json: {"state": NodeState, "device": {...}, "agent_version": "...",
   "report_system_queues": bool, "events_owned_by_host": bool}; "" for defaults.
   The event string is valid during the callback only, unless events_owned_by_host
   is true: then the host frees it with sprint_free when it is done. */
SPRINT_API long long sprint_node_new(const char* config_json, long long registry,
                                     sprint_event_cb cb, void* user, char** err);
SPRINT_API char*     sprint_node_pair(long long node, const char* code); /* {"ok","error"} */
SPRINT_API char*     sprint_node_provision(long long node);
SPRINT_API char*     sprint_node_heartbeat(long long node);
SPRINT_API void      sprint_node_unpair(long long node);
/* Runs the node (heartbeat, jobs, MQTT push, commands) on its own threads. */
SPRINT_API int       sprint_node_start(long long node);
SPRINT_API void      sprint_node_stop(long long node);
SPRINT_API char*     sprint_node_state(long long node);
SPRINT_API char*     sprint_node_status(long long node);
/* Protocol sweeps the node runs: JSON array of SweepView; a press is next | stop | choose. */
SPRINT_API char*     sprint_node_sweeps(long long node);
SPRINT_API char*     sprint_node_sweep_press(long long node, long long sweep, const char* action, const char* language);
SPRINT_API void      sprint_node_free(long long node);

#ifdef __cplusplus
}
#endif

#endif /* SPRINT_H */
