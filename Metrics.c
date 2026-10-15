#include "Metrics.h"
#include <mach/mach.h>
#include <mach/host_info.h>
#include <sys/sysctl.h>
#include <sys/event.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include <stdlib.h>

SystemMetrics sample_metrics(void) {
    SystemMetrics result = {0};
    result.cpu = -1;
    result.cpu_user = result.cpu_system = result.cpu_idle = -1;
    for (int i = 0; i < METRIC_MAX_CORES; i++) result.cpu_cores[i] = -1;
    mach_port_t host = mach_host_self();
    static uint32_t previous[CPU_STATE_MAX];
    static int initialized = 0;
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count) == KERN_SUCCESS) {
        uint64_t all = 0, idle = 0, user = 0, system = 0;
        for (int i = 0; i < CPU_STATE_MAX; i++) {
            uint32_t delta = cpu.cpu_ticks[i] - previous[i];
            all += delta;
            if (i == CPU_STATE_IDLE) idle = delta;
            if (i == CPU_STATE_USER || i == CPU_STATE_NICE) user += delta;
            if (i == CPU_STATE_SYSTEM) system = delta;
            previous[i] = cpu.cpu_ticks[i];
        }
        if (initialized && all) {
            result.cpu = 100.0 * (all - idle) / all;
            result.cpu_user = 100.0 * user / all;
            result.cpu_system = 100.0 * system / all;
            result.cpu_idle = 100.0 * idle / all;
        }
        initialized = 1;
    }
    static uint32_t previous_cores[METRIC_MAX_CORES][CPU_STATE_MAX];
    static natural_t previous_core_count = 0;
    natural_t core_count = 0;
    processor_info_array_t core_info = NULL;
    mach_msg_type_number_t core_info_count = 0;
    if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &core_count, &core_info, &core_info_count) == KERN_SUCCESS) {
        if (core_info_count >= core_count * CPU_STATE_MAX) {
            result.cpu_core_count = core_count < METRIC_MAX_CORES ? core_count : METRIC_MAX_CORES;
            for (uint32_t i = 0; i < result.cpu_core_count; i++) {
                uint64_t all = 0, idle = 0;
                for (int state = 0; state < CPU_STATE_MAX; state++) {
                    uint32_t ticks = (uint32_t)core_info[i * CPU_STATE_MAX + state];
                    uint32_t delta = ticks - previous_cores[i][state];
                    all += delta;
                    if (state == CPU_STATE_IDLE) idle = delta;
                    previous_cores[i][state] = ticks;
                }
                if (previous_core_count == core_count && all) result.cpu_cores[i] = 100.0 * (all - idle) / all;
            }
            previous_core_count = core_count;
        } else previous_core_count = 0;
        vm_deallocate(mach_task_self(), (vm_address_t)core_info, (vm_size_t)core_info_count * sizeof(integer_t));
    } else previous_core_count = 0;
    result.load_valid = getloadavg(result.load_average, 3) == 3;
    size_t size = sizeof(result.memory_total);
    int total_ok = sysctlbyname("hw.memsize", &result.memory_total, &size, NULL, 0) == 0;
    vm_statistics64_data_t vm;
    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    host_page_size(host, &page_size);
    if (total_ok && page_size && host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) == KERN_SUCCESS) {
        uint64_t internal = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
        result.app_memory = internal * page_size;
        result.wired = (uint64_t)vm.wire_count * page_size;
        // File-backed and purgeable pages approximate reusable cached memory.
        result.cached = ((uint64_t)vm.external_page_count + vm.purgeable_count) * page_size;
        result.memory_used = (internal + vm.wire_count + vm.compressor_page_count) * page_size;
        if (result.memory_used > result.memory_total) result.memory_used = result.memory_total;
        result.compressed = (uint64_t)vm.compressor_page_count * page_size;
        result.memory_valid = 1;
    }
    struct xsw_usage swap;
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        result.swap_used = swap.xsu_used;
        result.swap_valid = 1;
    }
    uint32_t pressure = 0;
    size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) == 0) {
        if (pressure == DISPATCH_MEMORYPRESSURE_NORMAL) { result.pressure = 0; result.pressure_valid = 1; }
        else if (pressure == DISPATCH_MEMORYPRESSURE_WARN) { result.pressure = 1; result.pressure_valid = 1; }
        else if (pressure == DISPATCH_MEMORYPRESSURE_CRITICAL) { result.pressure = 2; result.pressure_valid = 1; }
    }
    mach_port_deallocate(mach_task_self(), host);
    return result;
}
