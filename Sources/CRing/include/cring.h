#ifndef CRING_H
#define CRING_H

#include <stdint.h>

// 擷取用的共同時間線 ring buffer（單一生產者／單一消費者，無鎖）。
//
// 生產者 = Core Audio 即時 callback；消費者 = 背景寫檔執行緒。
// 每個 frame 同時包含所有來源的聲道（例如 App 2 聲道 + 麥克風 1 聲道 = 3 聲道），
// 所以各來源永遠一起寫入或一起丟棄，不會因為只有一邊溢位而錯位。
//
// 無法寫入的資料（ring 滿、時間戳不連續、緩衝區配置不符）不會被跳過：
// 生產者在缺口佇列記下「發生在資料流的哪個位置、少了幾個 frame」，
// 消費者讀到該位置時取出缺口，對所有來源補零，保留時間線。
//
// 即時路徑（begin_cycle / write / drop / note_buffer）不配置記憶體、不加鎖、不碰磁碟。

typedef struct ar_capture ar_capture;

enum {
    AR_GAP_OVERFLOW = 1,     // ring 已滿，整個 callback 的資料被丟棄
    AR_GAP_TIMESTAMP = 2,    // 輸入時間戳往前跳，表示 HAL 層少了資料
    AR_GAP_LAYOUT = 3,       // 緩衝區數量、聲道數或長度與開始前算好的配置不符
    AR_GAP_DEVICE = 4,       // 裝置變動後重建錄音管線期間的空白
};

typedef struct {
    uint64_t at_frame;        // 缺口出現在資料流的位置（此前已寫入 ring 的 frame 數）
    uint64_t missing_frames;  // 要補零的 frame 數
    double sample_time;       // 發生時的輸入取樣時間
    uint32_t kind;            // AR_GAP_*
} ar_gap;

ar_capture *ar_capture_create(uint32_t channels, uint32_t capacity_frames, uint32_t gap_capacity,
                              double sample_rate);
void ar_capture_destroy(ar_capture *c);

// ---- 即時路徑 ----

// 每次 IO callback 開頭呼叫一次。檢查時間戳連續性，必要時記錄時間戳缺口。
// host_seconds：本次輸入的系統時間（秒）；無效時傳負值。用來計算裝置切換期間的空白長度。
void ar_capture_begin_cycle(ar_capture *c, double sample_time, double host_seconds,
                            uint32_t frames, uint32_t buffer_count);

// 把 nsrc 個交錯格式來源合併寫入同一個 frame。src_channels 的總和必須等於建立時的聲道數。
// 成功回傳 1；ring 已滿時整塊丟棄、記錄溢位缺口並回傳 0；聲道總和不符回傳 -1（記為配置缺口）。
int ar_capture_write(ar_capture *c, const float *const *srcs, const uint32_t *src_channels,
                     uint32_t nsrc, uint32_t frames);

// 本次 callback 的資料不可用（配置不符），記錄缺口但不寫資料。
void ar_capture_drop(ar_capture *c, uint32_t frames, uint32_t kind);

// 裝置變動後重建錄音管線時呼叫（舊的 IO 已停止、新的 IO 尚未開始；呼叫端此時暫代生產者）。
// 新管線第一次 callback 時，依 host time 計算與舊管線最後一筆資料之間的空白並記錄為 AR_GAP_DEVICE；
// host time 無效時改用 fallback_frames。時間戳連續性檢查從新管線重新起算。
void ar_capture_begin_segment(ar_capture *c, double fallback_frames);

// 停止時呼叫（IO 已停止）：若 begin_segment 之後新管線一次 callback 都沒有，
// 依 now_host_seconds 與舊管線最後一筆資料的時間差補上 AR_GAP_DEVICE（host time 無效時用 fallback_frames）。
// 回傳補上的 frame 數（沒有待結算的中斷時回傳 0）。
uint64_t ar_capture_settle_segment(ar_capture *c, double now_host_seconds, double fallback_frames);

// 送出尚未進入佇列的缺口。IO 停止後、最後一次清空 ring 之前呼叫一次
//（連續缺口會先在生產者端合併，直到下一次成功寫入或呼叫此函式才送出）。
void ar_capture_flush(ar_capture *c);

// 記錄最近一次 callback 的緩衝區配置（診斷用）。
void ar_capture_note_buffer(ar_capture *c, uint32_t index, uint32_t channels, uint32_t frames);

// ---- 消費端 ----

// 讀出資料，最多讀到下一個缺口的位置為止。回傳讀出的 frame 數。
uint32_t ar_capture_read(ar_capture *c, float *dst, uint32_t max_frames);
// 下一個缺口剛好位於目前讀取位置時，取出並回傳 1；否則回傳 0。
int ar_capture_pop_gap(ar_capture *c, ar_gap *out);

// ---- 計數（任一執行緒可讀）----

uint32_t ar_capture_channels(const ar_capture *c);
uint64_t ar_capture_callbacks(const ar_capture *c);
uint64_t ar_capture_frames_written(const ar_capture *c);
uint64_t ar_capture_overflow_events(const ar_capture *c);
uint64_t ar_capture_overflow_frames(const ar_capture *c);
uint64_t ar_capture_timestamp_gap_events(const ar_capture *c);
uint64_t ar_capture_timestamp_gap_frames(const ar_capture *c);
uint64_t ar_capture_layout_gap_events(const ar_capture *c);
uint64_t ar_capture_layout_gap_frames(const ar_capture *c);
uint64_t ar_capture_backwards_events(const ar_capture *c);   // 時間戳倒退且沒有 host time：無法補救，時間線不可信
// 時間戳倒退但有 host time：視為時鐘重新起算，依實際經過時間接上（空白記為 AR_GAP_TIMESTAMP）
uint64_t ar_capture_rebase_events(const ar_capture *c);
uint64_t ar_capture_rebase_gap_frames(const ar_capture *c);
uint64_t ar_capture_rebase_overlap_frames(const ar_capture *c);  // host time 顯示重疊（無法補回，只記錄）
uint64_t ar_capture_lost_gap_events(const ar_capture *c);    // 缺口佇列已滿而無法記錄：時間線不可信
uint64_t ar_capture_device_gap_events(const ar_capture *c);
uint64_t ar_capture_device_gap_frames(const ar_capture *c);
uint32_t ar_capture_segments(const ar_capture *c);           // 管線段數（1 = 沒有重建過）
double ar_capture_segment_first_sample_time(const ar_capture *c);
double ar_capture_first_sample_time(const ar_capture *c);
double ar_capture_next_sample_time(const ar_capture *c);
uint32_t ar_capture_buffer_count(const ar_capture *c);
uint32_t ar_capture_buffer_channels(const ar_capture *c, uint32_t index);
uint32_t ar_capture_buffer_frames(const ar_capture *c, uint32_t index);

#endif
