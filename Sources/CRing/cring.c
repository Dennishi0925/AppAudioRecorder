#include "cring.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define AR_MAX_BUFFERS 8

struct ar_capture {
    float *data;
    uint32_t channels;
    uint32_t capacity;                 // frames
    _Atomic uint64_t head;             // 生產者已寫入的 frame 總數
    _Atomic uint64_t tail;             // 消費者已讀出的 frame 總數

    ar_gap *gaps;
    uint32_t gap_capacity;
    _Atomic uint64_t gap_head;
    _Atomic uint64_t gap_tail;

    // 只由生產者（callback）讀寫
    int have_prev;
    double expected_next;
    double sample_rate;
    int have_last_host;
    double last_end_host;       // 上一次 callback 資料結束時的系統時間（秒）
    int device_gap_armed;       // 新管線的第一次 callback 要計算切換空白
    double device_gap_fallback;
    int pending_valid;          // 尚未送出的缺口（連續同類缺口在此合併，避免佔滿佇列）
    ar_gap pending;

    // 計數
    _Atomic uint64_t callbacks;
    _Atomic uint64_t written;
    _Atomic uint64_t overflow_events, overflow_frames;
    _Atomic uint64_t ts_gap_events, ts_gap_frames;
    _Atomic uint64_t layout_gap_events, layout_gap_frames;
    _Atomic uint64_t backwards_events;
    _Atomic uint64_t rebase_events, rebase_gap_frames, rebase_overlap_frames;
    _Atomic uint64_t lost_gap_events;
    _Atomic uint64_t device_gap_events, device_gap_frames;
    _Atomic uint32_t segments;
    _Atomic double segment_first_sample_time;
    _Atomic double first_sample_time;
    _Atomic double next_sample_time;
    _Atomic uint32_t buffer_count;
    _Atomic uint32_t buf_channels[AR_MAX_BUFFERS];
    _Atomic uint32_t buf_frames[AR_MAX_BUFFERS];
};

#define LOAD(x) atomic_load_explicit(&(x), memory_order_relaxed)
#define ADD(x, v) atomic_fetch_add_explicit(&(x), (v), memory_order_relaxed)
#define STORE(x, v) atomic_store_explicit(&(x), (v), memory_order_relaxed)

ar_capture *ar_capture_create(uint32_t channels, uint32_t capacity_frames, uint32_t gap_capacity,
                              double sample_rate) {
    if (channels == 0 || capacity_frames == 0 || gap_capacity == 0 || !(sample_rate > 0)) return NULL;
    ar_capture *c = calloc(1, sizeof(ar_capture));
    if (!c) return NULL;
    c->data = calloc((size_t)capacity_frames * channels, sizeof(float));
    c->gaps = calloc(gap_capacity, sizeof(ar_gap));
    if (!c->data || !c->gaps) {
        free(c->data);
        free(c->gaps);
        free(c);
        return NULL;
    }
    c->channels = channels;
    c->capacity = capacity_frames;
    c->gap_capacity = gap_capacity;
    c->sample_rate = sample_rate;
    atomic_store_explicit(&c->segments, 1, memory_order_relaxed);
    return c;   // calloc 已把所有原子欄位清為 0
}

void ar_capture_destroy(ar_capture *c) {
    if (!c) return;
    free(c->data);
    free(c->gaps);
    free(c);
}

// 生產者：把待送缺口放進佇列。必須在寫入其後的資料「之前」呼叫（release 順序保證消費者看得到）。
static void flush_pending(ar_capture *c) {
    if (!c->pending_valid) return;
    c->pending_valid = 0;
    uint64_t gh = atomic_load_explicit(&c->gap_head, memory_order_relaxed);
    uint64_t gt = atomic_load_explicit(&c->gap_tail, memory_order_acquire);
    if (gh - gt >= c->gap_capacity) {
        ADD(c->lost_gap_events, 1);
        return;
    }
    c->gaps[gh % c->gap_capacity] = c->pending;
    atomic_store_explicit(&c->gap_head, gh + 1, memory_order_release);
}

// 生產者：記錄缺口。與尚未送出的同類缺口相連時直接合併。
static void push_gap(ar_capture *c, uint64_t missing, uint32_t kind, double sample_time) {
    if (missing == 0) return;
    uint64_t at = atomic_load_explicit(&c->head, memory_order_relaxed);
    if (c->pending_valid && c->pending.kind == kind && c->pending.at_frame == at) {
        c->pending.missing_frames += missing;
        return;
    }
    flush_pending(c);
    c->pending.at_frame = at;
    c->pending.missing_frames = missing;
    c->pending.sample_time = sample_time;
    c->pending.kind = kind;
    c->pending_valid = 1;
}

void ar_capture_flush(ar_capture *c) { flush_pending(c); }

void ar_capture_begin_cycle(ar_capture *c, double sample_time, double host_seconds,
                            uint32_t frames, uint32_t buffer_count) {
    ADD(c->callbacks, 1);
    STORE(c->buffer_count, buffer_count);
    if (!c->have_prev) {
        c->have_prev = 1;
        if (LOAD(c->callbacks) == 1) STORE(c->first_sample_time, sample_time);
        STORE(c->segment_first_sample_time, sample_time);
        if (c->device_gap_armed) {
            c->device_gap_armed = 0;
            double missing = c->device_gap_fallback;
            if (host_seconds >= 0 && c->have_last_host) {
                missing = (host_seconds - c->last_end_host) * c->sample_rate;
            }
            if (missing > 0.5) {
                uint64_t m = (uint64_t)llround(missing);
                ADD(c->device_gap_events, 1);
                ADD(c->device_gap_frames, m);
                push_gap(c, m, AR_GAP_DEVICE, sample_time);
            }
        }
    } else {
        double diff = sample_time - c->expected_next;
        // 用 host time 核對取樣時間的跳動：兩者差很多時，代表裝置時鐘重新起算（實測：拔耳機時
        // 取樣時間可能往後跳 47 秒、也可能歸零），以實際經過的時間為準。
        if (fabs(diff) > 0.5 && host_seconds >= 0 && c->have_last_host) {
            double hm = (host_seconds - c->last_end_host) * c->sample_rate;
            double tol = 0.01 * c->sample_rate;               // 10 ms：容許 host time 抖動
            if (fabs(diff - hm) > tol) {
                ADD(c->rebase_events, 1);
                double fill = 0;
                if (hm >= 0.005 * c->sample_rate) {
                    uint64_t missing = (uint64_t)llround(hm);
                    ADD(c->rebase_gap_frames, missing);
                    ADD(c->ts_gap_events, 1);
                    ADD(c->ts_gap_frames, missing);
                    push_gap(c, missing, AR_GAP_TIMESTAMP, sample_time);
                    fill = (double)missing;
                } else if (hm <= -0.005 * c->sample_rate) {
                    ADD(c->rebase_overlap_frames, (uint64_t)llround(-hm));
                }
                double elapsed = c->expected_next - LOAD(c->segment_first_sample_time);
                STORE(c->segment_first_sample_time, sample_time - elapsed - fill);
                diff = 0;                                     // 已處理，不再當成一般缺口或倒退
            }
        }
        if (diff > 0.5) {
            uint64_t missing = (uint64_t)llround(diff);
            ADD(c->ts_gap_events, 1);
            ADD(c->ts_gap_frames, missing);
            push_gap(c, missing, AR_GAP_TIMESTAMP, c->expected_next);
        } else if (diff < -0.5) {
            // 時間戳倒退：裝置時鐘重新起算（實測：拔耳機時，舊 aggregate 的主時鐘裝置消失，取樣時間歸零）。
            // 有 host time 就以實際經過的時間接上，否則無法補救。
            if (host_seconds >= 0 && c->have_last_host) {
                double hm = (host_seconds - c->last_end_host) * c->sample_rate;
                double tol = 0.005 * c->sample_rate;          // host time 抖動容許 5 ms
                ADD(c->rebase_events, 1);
                if (hm >= tol) {
                    uint64_t missing = (uint64_t)llround(hm);
                    ADD(c->rebase_gap_frames, missing);
                    ADD(c->ts_gap_events, 1);
                    ADD(c->ts_gap_frames, missing);
                    push_gap(c, missing, AR_GAP_TIMESTAMP, sample_time);
                    hm = (double)missing;
                } else {
                    if (hm <= -tol) ADD(c->rebase_overlap_frames, (uint64_t)llround(-hm));
                    hm = 0;
                }
                // 讓「本段經過的取樣數」保持連續（時鐘追蹤用）
                double elapsed = c->expected_next - LOAD(c->segment_first_sample_time);
                STORE(c->segment_first_sample_time, sample_time - elapsed - hm);
            } else {
                ADD(c->backwards_events, 1);
            }
        }
    }
    c->expected_next = sample_time + frames;
    STORE(c->next_sample_time, c->expected_next);
    if (host_seconds >= 0) {
        c->have_last_host = 1;
        c->last_end_host = host_seconds + (double)frames / c->sample_rate;
    }
}

uint64_t ar_capture_settle_segment(ar_capture *c, double now_host_seconds, double fallback_frames) {
    if (!c->device_gap_armed) return 0;
    c->device_gap_armed = 0;
    double missing = fallback_frames;
    if (now_host_seconds >= 0 && c->have_last_host) {
        missing = (now_host_seconds - c->last_end_host) * c->sample_rate;
    }
    if (missing <= 0.5) return 0;
    uint64_t m = (uint64_t)llround(missing);
    ADD(c->device_gap_events, 1);
    ADD(c->device_gap_frames, m);
    push_gap(c, m, AR_GAP_DEVICE, c->expected_next);
    flush_pending(c);
    return m;
}

void ar_capture_begin_segment(ar_capture *c, double fallback_frames) {
    flush_pending(c);
    c->have_prev = 0;
    c->device_gap_armed = 1;
    c->device_gap_fallback = fallback_frames;
    atomic_fetch_add_explicit(&c->segments, 1, memory_order_relaxed);
}

int ar_capture_write(ar_capture *c, const float *const *srcs, const uint32_t *src_channels,
                     uint32_t nsrc, uint32_t frames) {
    if (frames == 0) return 1;
    uint32_t total = 0;
    for (uint32_t s = 0; s < nsrc; s++) total += src_channels[s];
    if (total != c->channels) {
        ADD(c->layout_gap_events, 1);
        ADD(c->layout_gap_frames, frames);
        push_gap(c, frames, AR_GAP_LAYOUT, c->expected_next - frames);
        return -1;
    }
    uint64_t head = atomic_load_explicit(&c->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&c->tail, memory_order_acquire);
    if ((head - tail) + frames > c->capacity) {
        ADD(c->overflow_events, 1);
        ADD(c->overflow_frames, frames);
        push_gap(c, frames, AR_GAP_OVERFLOW, c->expected_next - frames);
        return 0;
    }
    flush_pending(c);   // 缺口必須比之後的資料先讓消費者看到
    const uint32_t ch = c->channels;
    for (uint32_t f = 0; f < frames; f++) {
        float *dst = c->data + (size_t)((head + f) % c->capacity) * ch;
        for (uint32_t s = 0; s < nsrc; s++) {
            uint32_t sc = src_channels[s];
            if (srcs[s]) {
                memcpy(dst, srcs[s] + (size_t)f * sc, sc * sizeof(float));
            } else {
                memset(dst, 0, sc * sizeof(float));
            }
            dst += sc;
        }
    }
    atomic_store_explicit(&c->head, head + frames, memory_order_release);
    ADD(c->written, frames);
    return 1;
}

void ar_capture_drop(ar_capture *c, uint32_t frames, uint32_t kind) {
    if (kind == AR_GAP_LAYOUT) {
        ADD(c->layout_gap_events, 1);
        ADD(c->layout_gap_frames, frames);
    } else if (kind == AR_GAP_OVERFLOW) {
        ADD(c->overflow_events, 1);
        ADD(c->overflow_frames, frames);
    }
    push_gap(c, frames, kind, c->expected_next - frames);
}

void ar_capture_note_buffer(ar_capture *c, uint32_t index, uint32_t channels, uint32_t frames) {
    if (index >= AR_MAX_BUFFERS) return;
    STORE(c->buf_channels[index], channels);
    STORE(c->buf_frames[index], frames);
}

uint32_t ar_capture_read(ar_capture *c, float *dst, uint32_t max_frames) {
    uint64_t tail = atomic_load_explicit(&c->tail, memory_order_relaxed);
    // 先讀資料 head，再讀缺口 head：生產者總是先記缺口、後寫之後的資料，
    // 所以看得到某段資料時，也一定看得到它之前的缺口。
    uint64_t head = atomic_load_explicit(&c->head, memory_order_acquire);
    uint64_t gh = atomic_load_explicit(&c->gap_head, memory_order_acquire);
    uint64_t gt = atomic_load_explicit(&c->gap_tail, memory_order_relaxed);
    uint64_t avail = head - tail;
    if (gt != gh) {
        uint64_t at = c->gaps[gt % c->gap_capacity].at_frame;
        uint64_t limit = at > tail ? at - tail : 0;
        if (limit < avail) avail = limit;
    }
    uint32_t n = avail < max_frames ? (uint32_t)avail : max_frames;
    if (n == 0) return 0;
    const uint32_t ch = c->channels;
    uint32_t pos = (uint32_t)(tail % c->capacity);
    uint32_t first = c->capacity - pos;
    if (first > n) first = n;
    memcpy(dst, c->data + (size_t)pos * ch, (size_t)first * ch * sizeof(float));
    if (n > first) {
        memcpy(dst + (size_t)first * ch, c->data, (size_t)(n - first) * ch * sizeof(float));
    }
    atomic_store_explicit(&c->tail, tail + n, memory_order_release);
    return n;
}

int ar_capture_pop_gap(ar_capture *c, ar_gap *out) {
    uint64_t gh = atomic_load_explicit(&c->gap_head, memory_order_acquire);
    uint64_t gt = atomic_load_explicit(&c->gap_tail, memory_order_relaxed);
    if (gt == gh) return 0;
    const ar_gap *slot = &c->gaps[gt % c->gap_capacity];
    uint64_t tail = atomic_load_explicit(&c->tail, memory_order_relaxed);
    if (slot->at_frame != tail) return 0;
    *out = *slot;
    atomic_store_explicit(&c->gap_tail, gt + 1, memory_order_release);
    return 1;
}

uint32_t ar_capture_channels(const ar_capture *c) { return c->channels; }
uint64_t ar_capture_callbacks(const ar_capture *c) { return LOAD(c->callbacks); }
uint64_t ar_capture_frames_written(const ar_capture *c) { return LOAD(c->written); }
uint64_t ar_capture_overflow_events(const ar_capture *c) { return LOAD(c->overflow_events); }
uint64_t ar_capture_overflow_frames(const ar_capture *c) { return LOAD(c->overflow_frames); }
uint64_t ar_capture_timestamp_gap_events(const ar_capture *c) { return LOAD(c->ts_gap_events); }
uint64_t ar_capture_timestamp_gap_frames(const ar_capture *c) { return LOAD(c->ts_gap_frames); }
uint64_t ar_capture_layout_gap_events(const ar_capture *c) { return LOAD(c->layout_gap_events); }
uint64_t ar_capture_layout_gap_frames(const ar_capture *c) { return LOAD(c->layout_gap_frames); }
uint64_t ar_capture_backwards_events(const ar_capture *c) { return LOAD(c->backwards_events); }
uint64_t ar_capture_rebase_events(const ar_capture *c) { return LOAD(c->rebase_events); }
uint64_t ar_capture_rebase_gap_frames(const ar_capture *c) { return LOAD(c->rebase_gap_frames); }
uint64_t ar_capture_rebase_overlap_frames(const ar_capture *c) { return LOAD(c->rebase_overlap_frames); }
uint64_t ar_capture_lost_gap_events(const ar_capture *c) { return LOAD(c->lost_gap_events); }
double ar_capture_first_sample_time(const ar_capture *c) { return LOAD(c->first_sample_time); }
double ar_capture_next_sample_time(const ar_capture *c) { return LOAD(c->next_sample_time); }
uint32_t ar_capture_buffer_count(const ar_capture *c) { return LOAD(c->buffer_count); }
uint32_t ar_capture_buffer_channels(const ar_capture *c, uint32_t i) { return i < AR_MAX_BUFFERS ? LOAD(c->buf_channels[i]) : 0; }
uint32_t ar_capture_buffer_frames(const ar_capture *c, uint32_t i) { return i < AR_MAX_BUFFERS ? LOAD(c->buf_frames[i]) : 0; }
uint64_t ar_capture_device_gap_events(const ar_capture *c) { return LOAD(c->device_gap_events); }
uint64_t ar_capture_device_gap_frames(const ar_capture *c) { return LOAD(c->device_gap_frames); }
uint32_t ar_capture_segments(const ar_capture *c) { return LOAD(c->segments); }
double ar_capture_segment_first_sample_time(const ar_capture *c) { return LOAD(c->segment_first_sample_time); }
