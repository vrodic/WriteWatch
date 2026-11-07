#ifndef WW_NVME_SMART_H
#define WW_NVME_SMART_H

#include <stdint.h>

/// Plain-C snapshot of an NVMe drive's identity and SMART health log.
/// The drive's serial number is deliberately not collected.
typedef struct {
    char model[41];
    char firmware[9];
    uint64_t capacity_bytes;
    uint8_t critical_warning;
    int32_t temperature_kelvin;
    uint8_t available_spare;
    uint8_t available_spare_threshold;
    uint8_t percentage_used;
    uint64_t data_units_read;
    uint64_t data_units_written;
    uint64_t host_read_commands;
    uint64_t host_write_commands;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
    uint64_t error_log_entries;
} ww_smart_report;

/// Reads the first SMART-capable NVMe drive through IOKit.
/// Returns 0 on success. On failure, returns a nonzero code and fills `error`.
int ww_read_smart(ww_smart_report *report, char *error, unsigned long error_size);

#endif
