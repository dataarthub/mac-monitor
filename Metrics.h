#include <stdint.h>
#define METRIC_MAX_CORES 64
typedef struct {
    double cpu;
    double cpu_user;
    double cpu_system;
    double cpu_idle;
    double cpu_cores[METRIC_MAX_CORES];
    uint32_t cpu_core_count;
    double load_average[3];
    int load_valid;
    uint64_t memory_total;
    uint64_t memory_used;
    uint64_t app_memory;
    uint64_t wired;
    uint64_t cached;
    uint64_t compressed;
    uint64_t swap_used;
    uint32_t pressure;
    int memory_valid;
    int swap_valid;
    int pressure_valid;
} SystemMetrics;
SystemMetrics sample_metrics(void);
