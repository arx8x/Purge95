#include <IOKit/IOKitLib.h>
#include <HBLog.h>
#include <spawn.h>
// #include <mach/mach.h>

static long notification_count = 0;
static time_t last_cleared_time = 0;
static bool is_waiting_to_clear = false;
static bool last_notification_charging_state = false;
static io_service_t iopm_sevice = 0;
// from iofbres
int run_command(const char *command)
{
	pid_t pid;
	const char *argv[] = {"/bin/sh", "-c", command, NULL};
	int status;

	status = posix_spawn(&pid, argv[0], NULL, NULL, (char **)argv, NULL);
	if(status == 0)
	{
		if(waitpid(pid, &status, 0) == -1)
		{
			return -1;
		}
		return status;
	}
	return -1;
}

static void clear_battery_data_and_reload_aggregated()
{
  // this is unlikely but what if deletions of the files takes 10 minutes (hypothetically),
  // the device is unplugged twice? we don't want aggregated to be reloaded like that
  if(is_waiting_to_clear) return;
  is_waiting_to_clear = true;
  HBLogDebug(@"WILL CLEAR");
  int aggregated_unload_error = run_command("launchctl unload /System/Library/LaunchDaemons/com.apple.aggregated.plist");
  if(!aggregated_unload_error)
  {
    int del_error = run_command("rm /var/containers/Shared/SystemGroup/*/Library/BatteryLife/CurrentPowerlog*");
    // int del_error = run_command("rm /tmp/test");
    HBLogDebug(@"BatteryLife delete: %d", del_error);
  }
  int aggregated_load_error = run_command("launchctl load /System/Library/LaunchDaemons/com.apple.aggregated.plist");
  HBLogDebug(@"reloading aggregated %d %d", aggregated_unload_error, aggregated_load_error);
  // store the last cleared time so that the request to clear files won't be processed more than once in 5 minutes
  time(&last_cleared_time);
  is_waiting_to_clear = false;
}

static void io_service_callback(void *	refcon, io_service_t srv, natural_t type, void * arg)
{
  HBLogDebug(@"lifetime notification count %ld", ++notification_count);
  time_t current_time;
  time(&current_time);
  HBLogDebug(@"It has been %ld seconds since last purge", (current_time - last_cleared_time));
  if(is_waiting_to_clear || (current_time - last_cleared_time < 300)) return;

  CFMutableDictionaryRef dict;
  if(!iopm_sevice)
  {
    iopm_sevice = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if(!iopm_sevice)
    {
      HBLogDebug(@"Error getting battery data");
      return;
    }
  }
  kern_return_t pret = IORegistryEntryCreateCFProperties(iopm_sevice, &dict, 0, 0);
  HBLogDebug(@"Notification received, service properties : %d", pret);
  CFBooleanRef is_charging_cf;
  // there are multiple ways to check if external power is connected but since we also need to read
  // battery level, it's better to just read this one service. Apple has changed the property names in
  // IOPMPowerSource subclasses before but iirc, they didn't change the "AppleRaw*" keys when they did
  bool key_retrieved = CFDictionaryGetValueIfPresent(dict, CFSTR("AppleRawExternalConnected"), (const void **)&is_charging_cf);
  if(key_retrieved)
  {
    HBLogDebug(@"Key retrieved, %@", is_charging_cf);
    double current_capacity, max_capacity;
    CFNumberRef current_capacity_cf = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR("AppleRawCurrentCapacity"));
    CFNumberGetValue(current_capacity_cf, kCFNumberDoubleType, &current_capacity);
    CFNumberRef max_capacity_cf = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR("AppleRawMaxCapacity"));
    CFNumberGetValue(max_capacity_cf, kCFNumberDoubleType, &max_capacity);

    float current_percentage = current_capacity/max_capacity;
    HBLogDebug(@"%f, %f, %f", current_capacity, max_capacity, current_percentage);
    bool is_charging = CFBooleanGetValue(is_charging_cf);

    // why is such a check needed?
    // well, because we're relying on notifications based on property changes on IOServices,
    // it's likely that a property that we totally don't care about can change and trigger
    // If the device is unplugged, we get a notification and clear the database
    // 1 hour later, a property can trigger a notification and cause the database purge
    // to be triggered if the check isn't in place. So, we're making sure that the device is
    // plugged in before clearing the database again. This way, even if get two or three notifications
    // after the device being unplugged, we will only clear the database IF the last state is different
    // than the current charging state
    if(last_notification_charging_state != is_charging)
    {
      HBLogDebug(@"can clear notification");
      last_notification_charging_state = is_charging;
      if(!is_charging)
      {
        // clear only if battery level is above 95%
        // I know there's some property in IOPMPowerSource but it's inconsistent
        // in the subclasses. (AppleSmartBattery and AppleARMPMUCharger for example)
        if(current_percentage > 0.95)
        {
          HBLogDebug(@"clearing");
          clear_battery_data_and_reload_aggregated();
        }
      }
    }
    else
    {
      HBLogDebug(@"Same state: won't clear");
    }

  }
  CFRelease(dict);
}



%ctor
{
  static dispatch_once_t token;
  dispatch_once(&token,
  ^{
    // IOPMPowerSource can also be used for notifications. But the issue is it spams notifications, because properties in it are bound to
    // change very often. You can get thousands of notifications in under an hour.
    // on new iOS versions IOAccessoryPowerSourceItemUSB_ChargingPort, IOUSBDeviceInterfaceUserClient, IOAccessoryUSBPowerSourceDetect
    // can also be used. I just want this to also work on iOS 10.
    // Also gotta look into MachingNotifications for something that shows up in IOKit when a power source is connected, regardles
    // of it being wired or wireless.
    io_service_t wireless_service_test = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMCWirelessCharger"));
    io_service_t usb = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleTriStarBuiltIn"));

    IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
    CFRunLoopSourceRef runloopsauce = IONotificationPortGetRunLoopSource(port);

    if(usb)
    {
      io_object_t notification_usb;
      kern_return_t ret = IOServiceAddInterestNotification(port, usb, kIOGeneralInterest,io_service_callback, NULL, &notification_usb);
      HBLogDebug(@"Register for usb notification: %d", ret);
    }

    // I'm still very unsure about this. I don't even know what this is. Still giving it a try
    if(wireless_service_test)
    {
      io_object_t notification_wireless_test;
      kern_return_t ret = IOServiceAddInterestNotification(port, wireless_service_test, kIOGeneralInterest,io_service_callback, NULL, &notification_wireless_test);
      HBLogDebug(@"Register for experimental wireless charger notification: %d", ret);
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), runloopsauce, kCFRunLoopDefaultMode);
  });
}
