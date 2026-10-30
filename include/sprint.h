/*
 * sPrint — Superroute's printing SDK, C interface (sPrint core 0.1.x).
 *
 * One library per OS / architecture: libsprint.dylib (macOS), libsprint.so
 * (Linux, Raspberry Pi), sprint.dll (Windows), or the static libsprint.a.
 *
 * Conventions
 *  - Structured values cross as UTF-8 JSON in the shapes of the Go API:
 *    TargetPrinter, LabelJob, PrintJob (its "data" is base64), PrintResult,
 *    DiscoveredPrinter, NodeState, PeerHostState. See docs/DESIGN.md §4.
 *  - Every char* and unsigned char* sPrint returns is owned by the caller and
 *    freed with sprint_free(). Strings passed in are only read during the call.
 *  - Functions returning int: 0 (or a non-negative value) on success, -1 on
 *    failure with *err set (when err is not NULL) to a message to free.
 *  - Handles (registry, node, peer identity, host, session) are opaque non-zero int64 values; 0 is failure.
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
   iOS registers its CoreBluetooth scan so every binding lists BLE printers there.
   Transport "mdns" is the native mDNS browser of LAN peers (see LAN peer printing). */
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

/* LAN peer printing (docs/LAN-PEER-DESIGN.md; peer-direct protocol 1.1.0, the
   SuperPrinter apps' own). Off by default: a host shares nothing until started,
   with the printers it names shared one by one, in approval mode unless set. */

/* Identity: seed_b64 "" (or NULL) makes a new one; otherwise the stored 32-byte seed, base64. */
SPRINT_API long long sprint_peer_identity_new(const char* seed_b64, char** err);
SPRINT_API char*     sprint_peer_identity_seed(long long identity);        /* base64, to store */
SPRINT_API char*     sprint_peer_identity_fingerprint(long long identity); /* "a1b2:c3d4:…" */
SPRINT_API void      sprint_peer_identity_free(long long identity);

/* Host (the printer owner). config_json: {"name", "port" (0 = 17778), "bind_addr"
   ("host:port", overrides port), "state": PeerHostState, "agent_version",
   "events_owned_by_host"}. identity 0 takes state.seed, else a new identity.
   Events: {"type":"peer_state","state":PeerHostState} (store it),
   {"type":"peer_pending","pending":{id, fingerprint, name, note, addr, requested}},
   {"type":"peer_connected","peer":PeerSessionInfo},
   {"type":"peer_disconnected","peer":PeerSessionInfo,"reason":"disconnected|revoked|expired|stopped"},
   {"type":"log","message"}. Calls returning char* answer {"ok": bool, "error": "..."} unless noted. */
SPRINT_API long long sprint_peer_host_new(const char* config_json, long long registry, long long identity,
                                          sprint_event_cb cb, void* user, char** err);
SPRINT_API char*     sprint_peer_host_start(long long host);
SPRINT_API void      sprint_peer_host_stop(long long host);
SPRINT_API char*     sprint_peer_host_set_mode(long long host, const char* mode); /* open | password | approval */
SPRINT_API char*     sprint_peer_host_set_password(long long host, const char* password);
SPRINT_API char*     sprint_peer_host_set_shared(long long host, const char* names_json); /* JSON array of registry names */
SPRINT_API char*     sprint_peer_host_set_discoverable(long long host, int on);
SPRINT_API char*     sprint_peer_host_pending(long long host);  /* JSON array of pending requests */
SPRINT_API char*     sprint_peer_host_decide(long long host, const char* request_id, int approve);
SPRINT_API char*     sprint_peer_host_sessions(long long host); /* JSON array of PeerSessionInfo */
SPRINT_API char*     sprint_peer_host_revoke(long long host, const char* fingerprint);
SPRINT_API char*     sprint_peer_host_state(long long host);    /* PeerHostState */
/* {"running", "addr", "fingerprint", "name", "mode", "discoverable", "advertising",
   "advertise_error", "sessions", "pending"} */
SPRINT_API char*     sprint_peer_host_status(long long host);
SPRINT_API void      sprint_peer_host_free(long long host);

/* Devices advertising on the LAN: {"peers": [{fingerprint, name, mode, addr, version, instance}], "error"}. */
SPRINT_API char*     sprint_peers_browse(int timeout_ms);

/* Session (the printer user). options_json: {"addr": "host:port", "fingerprint" (pin; "" =
   trust on first use), "password", "note", "ping_ms" (0 = 8000), "events_owned_by_host"}.
   Events: {"type":"peer_ended","fingerprint","name","reason":"revoked|expired|unreachable"}.
   A refusal sets *err, its code in brackets (e.g. "(BAD_PASSWORD)", "(THROTTLED)"). */
SPRINT_API long long sprint_peer_connect(const char* options_json, long long identity,
                                         sprint_event_cb cb, void* user, char** err);
/* {"status": "connected|pending|ended", "reason", "fingerprint", "name", "mode", "addr", "version"} */
SPRINT_API char*     sprint_peer_status(long long session);
/* Waits for the owner's decision (0 = two minutes): {"ok"} or {"ok":false,"error","code":"denied|timeout"}. */
SPRINT_API char*     sprint_peer_wait_approval(long long session, int timeout_ms);
SPRINT_API char*     sprint_peer_printers(long long session); /* {"printers": [...], "error"} */
/* Runs a PrintJob (label, raw, pdf, html, image) on a shared printer ("" = the peer's default): PrintResult. */
SPRINT_API char*     sprint_peer_print(long long session, const char* printer, const char* job_json);
SPRINT_API void      sprint_peer_disconnect(long long session);
SPRINT_API void      sprint_peer_free(long long session);
/* A connected peer's printers as registry targets "peer:<fingerprint>/<printer>". */
SPRINT_API char*     sprint_registry_attach_peer(long long registry, long long session);
SPRINT_API void      sprint_registry_detach_peer(long long registry, const char* fingerprint);

/* Native mDNS (Android NSD, Bonjour on iOS; desktops use their own). Browsing is
   sprint_register_scanner("mdns", cb, user): the callback browses _superprinter._tcp for
   scan_ms and answers {"services": [{"instance", "service", "domain", "host" (an address),
   "port", "txt": ["k=v", …]}]} or {"error"}. Advertising: advertise gets
   {"instance", "service", "domain", "port", "txt"} and answers 0 (or non-zero with *err
   malloc'ed); a later call for the same instance replaces it; withdraw removes it.
   A NULL advertise removes the advertiser. */
typedef int (*sprint_mdns_advertise_cb)(const char* service_json, char** err, void* user);
typedef int (*sprint_mdns_withdraw_cb)(const char* instance, void* user);
SPRINT_API int       sprint_register_mdns_advertiser(sprint_mdns_advertise_cb advertise, sprint_mdns_withdraw_cb withdraw,
                                                     void* user);

#ifdef __cplusplus
}
#endif

#endif /* SPRINT_H */
