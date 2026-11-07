#include "nvme_smart.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <stdio.h>
#include <string.h>

static void copy_trimmed(char *dst, size_t dst_size, const uint8_t *src, size_t src_size) {
    size_t n = src_size < dst_size - 1 ? src_size : dst_size - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
    while (n > 0 && (dst[n - 1] == ' ' || dst[n - 1] == 0)) {
        dst[--n] = 0;
    }
}

static io_service_t find_smart_service(void) {
    CFMutableDictionaryRef property = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    if (property == NULL || matching == NULL) {
        if (property) CFRelease(property);
        if (matching) CFRelease(matching);
        return IO_OBJECT_NULL;
    }
    CFDictionarySetValue(property, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), property);
    CFRelease(property);
    // IOServiceGetMatchingService consumes the reference to `matching`.
    return IOServiceGetMatchingService(kIOMainPortDefault, matching);
}

int ww_read_smart(ww_smart_report *report, char *error, unsigned long error_size) {
    memset(report, 0, sizeof(*report));

    io_service_t service = find_smart_service();
    if (service == IO_OBJECT_NULL) {
        snprintf(error, error_size, "No SMART-capable NVMe drive found.");
        return 1;
    }

    IOCFPlugInInterface **plugin = NULL;
    IONVMeSMARTInterface **smart = NULL;
    SInt32 score = 0;
    int result = 0;

    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        snprintf(error, error_size, "Could not open the SMART interface (0x%08x).", kr);
        result = 2;
        goto done;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        snprintf(error, error_size, "The drive refused the SMART interface (0x%08x).", (unsigned)hr);
        result = 3;
        goto done;
    }

    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn io = (*smart)->SMARTReadData(smart, &data);
    if (io != kIOReturnSuccess) {
        snprintf(error, error_size, "Reading the SMART log failed (0x%08x).", io);
        result = 4;
        goto done;
    }

    report->critical_warning = data.CRITICAL_WARNING;
    report->temperature_kelvin = data.TEMPERATURE;
    report->available_spare = data.AVAILABLE_SPARE;
    report->available_spare_threshold = data.AVAILABLE_SPARE_THRESHOLD;
    report->percentage_used = data.PERCENTAGE_USED;
    // These are 128-bit counters; the low word covers anything a real drive reaches.
    report->data_units_read = data.DATA_UNITS_READ[0];
    report->data_units_written = data.DATA_UNITS_WRITTEN[0];
    report->host_read_commands = data.HOST_READ_COMMANDS[0];
    report->host_write_commands = data.HOST_WRITE_COMMANDS[0];
    report->power_cycles = data.POWER_CYCLES[0];
    report->power_on_hours = data.POWER_ON_HOURS[0];
    report->unsafe_shutdowns = data.UNSAFE_SHUTDOWNS[0];
    report->media_errors = data.MEDIA_ERRORS[0];
    report->error_log_entries = data.NUM_ERROR_INFO_LOG_ENTRIES[0];

    // Identity is nice to have: a failure here still leaves a usable health report.
    NVMeIdentifyControllerStruct identify;
    memset(&identify, 0, sizeof(identify));
    if ((*smart)->GetIdentifyData(smart, &identify, 0) == kIOReturnSuccess) {
        copy_trimmed(report->model, sizeof(report->model), identify.MODEL_NUMBER,
                     sizeof(identify.MODEL_NUMBER));
        copy_trimmed(report->firmware, sizeof(report->firmware), identify.FW_REVISION,
                     sizeof(identify.FW_REVISION));
    }

    CFTypeRef size = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, CFSTR("Size"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    if (size != NULL) {
        if (CFGetTypeID(size) == CFNumberGetTypeID()) {
            int64_t value = 0;
            CFNumberGetValue((CFNumberRef)size, kCFNumberSInt64Type, &value);
            report->capacity_bytes = (uint64_t)value;
        }
        CFRelease(size);
    }

done:
    if (smart != NULL) (*smart)->Release(smart);
    if (plugin != NULL) IODestroyPlugInInterface(plugin);
    IOObjectRelease(service);
    return result;
}
