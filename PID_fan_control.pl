#!/usr/local/bin/perl

# This script is based on the hybrid fan controller script created by @Stux, and posted at:
# https://forums.freenas.org/index.php?threads/script-hybrid-cpu-hd-fan-zone-controller.46159/

# The significant changes from @Stux's script are:
# 1. Replace HD fan control of several discrete duty cycles as a function of hottest HD temperature with a PID controller
#    which controls duty cycle in 1% steps as a function of average HD temperature.  As a protection, if any HD temperature
#    exceeds a specified value, the HD fans are commanded to 100% duty cycle.  This covers cases where one HD may be running 
#    hot, even if the average HD temperature is acceptable, or the PID loop control has gone awry.
# 2. Add optional setting to command CPU fans to 100% duty cycle if needed to assist with HD cooling, to cover scenarios 
#    where the CPU fan zone also controls chassis exit fans.
# 3. Add optional log of HD fan temperatures, PID loop values and commanded fan duty cycles.  The log may optionally contain
#    a record of each HD temperature, or only the coolest and warmest HD temperatures.
# 4. Added ability to specify the number of warmest disks to use when calculating the average temperature.
# 5. Added ability to put certain configuration values in a configuration file that is checked each time around the control loop.

# This script can be downloaded from : 
# https://forums.freenas.org/index.php?threads/pid-fan-controller-perl-script.50908/

###############################################################################################
# This script is designed to control both the CPU and HD fans in a Supermicro X10 based system according to both
# the CPU and HD temperatures in order to minimize noise while providing sufficient cooling to deal with scrubs
# and CPU torture tests. It may work in X9 based systems, but this has not been tested.  It has been found to work on at least
# the X11SSM-F.

# It relies on the motherboard having two fan zones, FAN1..FAN4 and FANA..FANC.

# To use this correctly, you should connect all your PWM HD fans, by splitters if necessary to the FANA..FANC headers, or to
# the numbered FAN1..FAN4 headers.   The CPU, case and exhaust fans should then be connected to the other headers.  This script 
# will then control the HD fans in response to the HD temp, and the other fans in response to CPU temperature. When CPU 
# temperature is high the HD fans will be used to provide additional cooling, if you specify cpu/hd shared cooling.

# If the fans should be high, and they are stuck low, or vice-versa, the BMC will be rebooted, thus it is critical to set the
# cpu/hd_max_fan_speed variables correctly.

# NOTE: It is highly likely the "get_hd_temp" function will not work as-is with your HDs. Until a better solution is provided
# you will need to modify this function to properly acquire the temperature. Setting debug=2 will help.

# Tested with a SuperMicro X10SRH-cF, Xeon E5-1650v4, Noctua 120, 90 and 80mm fans in a Norco RPC-4224 4U chassis, with 16 x 4 TB WD Red drives.

# More information on CPU/Peripheral Zone can be found in this post:
# https://forums.freenas.org/index.php?threads/thermal-and-accoustical-design-validation.28364/

# stux (+ editorial changes on Fan Zones from Kevin Horton)

###############################################################################################

# The IPMI fan lower and upper fan speed thresholds must be adjusted to be compatible with the fans used.  Do not rely 
# completely on manufacturer specs to determine the slowest and fastest possible fan speeds, as some fans have been found
# to run at speeds that differ somewhat from the official specs.  See: 
# https://forums.freenas.org/index.php?resources/how-to-change-ipmi-sensor-thresholds-using-ipmitool.35/

# The following ipmitool commands can be run when connected to the FreeNAS server via ssh.  They are useful to set a desired fan duty cycle before
# checking the fan speeds.

# Set duty cycle in Zone 0 to 100%: ipmitool raw 0x30 0x70 0x66 0x01 0x00 100  
# Set duty cycle in Zone 0 to  50%: ipmitool raw 0x30 0x70 0x66 0x01 0x00 50
# Set duty cycle in Zone 0 to  20%: ipmitool raw 0x30 0x70 0x66 0x01 0x00 20

# Set duty cycle in Zone 1 to 100%: ipmitool raw 0x30 0x70 0x66 0x01 0x01 100
# Set duty cycle in Zone 1 to  50%: ipmitool raw 0x30 0x70 0x66 0x01 0x01 50
# Set duty cycle in Zone 1 to  20%: ipmitool raw 0x30 0x70 0x66 0x01 0x01 20

# Check duty cycle in Zone 0:                   ipmitool raw 0x30 0x70 0x66 0x00 0x00
# result is hex, with 64 being 100% duty cycle.  32 is 50% duty cycle.  14 is 20% duty cycle.

#  Check duty cycle in Zone 1:                  ipmitool raw 0x30 0x70 0x66 0x00 0x01
# result is hex, with 64 being 100% duty cycle.  32 is 50% duty cycle.  14 is 20% duty cycle.

# Check fan speeds using: ipmitool sdr

# Number of warmest disks to average
# Originally, the script would calculate an average temperature for all disks, and vary fan speed as required to achieve the target 
# temperature.  Later, the option was added to have the script only worry about the warmest X disks, and use the average of those
# disks as the target.  This better accomadated the common situation where there are several disks that run several degrees warmer
# than the others, and it is desired to keep those warm disks from exceeding a specified temperature.

# If desired, certain settings may be defined in a configuration file that can be changed on the fly, while the script is running.
# The script will check the latest modification time of the config file each time it determines the new fan duty cycle, and reload
# the configuration data if it has changed.  This is useful when testing the script, as the PID control gains, average disk target
# temperature and number of warmest disk temperatures to average
# Kevin Horton
###############################################################################################
# VERSION HISTORY
#####################
# 2016-09-19 Initial Version
# 2016-09-19 Added cpu_hd_override_temp, to prevent HD fans cycling when CPU fans are sufficient for cooling CPU
# 2016-09-26 hd_list is now refreshed before checking HD temps so that we start/stop monitoring devices that
#            have been hot inserted/removed.
#            "Drives are warm, going to 75%" log message was missing an unless clause causing it to print
#            every time
# 2016-10-07 Replaced get_cpu_temp() function with get_cpu_temp_sysctl() which queries the kernel, instead of
#            IPMI. This is faster, more accurate and more compatible, hopefully allowing this to work on X9
#            systems. The original function is still present and is now called get_cpu_temp_ipmi(). 
#            Because this is a much faster method of reading the temps,  and because its actually the max core 
#            temp, I found that the previous cpu_hd_override_temp of 60 was too sensitive and caused the override 
#            too often. I've bumped it up to 62, which on my system seems good. This means that if a core gets to 
#            62C the HD fans will kick in, and this will generally bring temps back down to around 60C... depending 
#            on the actual load. Your results will vary, and for best results you should tune controller with 
#            mprime testing at various thread levels. Updated the cpu threasholds to 35/45/55 because of the improved
#            responsiveness of the get_cpu_temp function
#
# The following changes are by Kevin Horton
# 2017-01-14 Reworked get_hd_list() to exclude SSDs
#            Added function to calculate maximum and average HD temperatures.
#            Replaced original HD fan control scheme with a PID controller, controlling the average HD temp..
#            Added safety override if any HD reaches a specified max temperature.  If so, the PID loop is overridden, 
#            and HD fans are set to 100%
#            Retain float value of fan duty cycle between loop cycles, so that small duty cycle corrections 
#            accumulate and eventually push the duty cycle to the next integer value.
# 2017-01-18 Added log file
# 2017-01-21 Refactored code to bump up CPU fan to help cool HD.  Drop the variabe CPU duty cycle, and just set to High,
#            Added log file option without temps for every HD.
# 2017-01-29 Add header to log file every X hours
#
# 2018-08-24 v1.0 Version optimized for 1500 rpm Noctua NF-F12 fans
# 
# 2018-08-25 Revised gains and thresholds for 3000 rpm Noctua NF-F12 iPPC fans
#            Added 10s pause before checking fan speed, to allow time for fans to respond to latest gain change
#
# 2018-09-17 Revised HD temp average to only look at warmest X disks.
#
# 2018-09-27 Use config file to determine number of warmest disks to average, PID gains and target average temperature.
#            The config file may be revised while the script is running, and the updated values will be read into the script 
#            each time around the control loop.
#
# 2020-01-01 Merged options for selectable number of disks to average and certain settings in config file to 
#            Master branch
#
# TO DO
#           Do not change fan speed due to calculated Tave changes when switching config scripts
###############################################################################################
## CONFIGURATION
################

##CONFIG FILE
## Read following config file at start and every X minutes to determine number of warmest disks to average,
## target average temperature and PID gains.  If file is not available, or corrupt, use defaults specified
## in this script.
$config_file = '/root/nas_fan_control/PID_fan_control_config.ini';

##DEFAULT VALUES
## Use the values declared below if the config file is not present
$hd_ave_target = 38;         # PID control loop will target this average temperature for the warmest N disks
$Kp = 16/3;                  # PID control loop proportional gain
$Ki = 0;                     # PID control loop integral gain
$Kd = 24;                    # PID control loop derivative gain
$hd_num_peak = 2;            # Number of warmest HDs to use when calculating average temp
$hd_fan_duty_start     = 60; # HD fan duty cycle when script starts

## DEBUG LEVEL
## 0 means no debugging. 1,2,3,4 provide more verbosity
## You should run this script in at least level 1 to verify its working correctly on your system
$debug = 0;
$debug_log = '/root/Debug_PID_fan_control.log';

## LOG
$log = '/root/PID_fan_control.log';
$log_temp_summary_only      = 0; # 1 if not logging individual HD temperatures.  0 if logging temp of each HD
$log_header_hourly_interval = 2; # number of hours between log headers.  Valid options are 1, 2, 3, 4, 6 & 12.
                                 # log headers will always appear at the start of a log, at midnight and any 
                                 # time the list of HDs changes (if individual HD temperatures are logged)

## CPU THRESHOLD TEMPS
## A modern CPU can heat up from 35C to 60C in a second or two. The fan duty cycle is set based on this
$high_cpu_temp = 55;       # will go HIGH when we hit
$med_cpu_temp  = 45;       # will go MEDIUM when we hit, or drop below again
$low_cpu_temp  = 35;       # will go LOW when we fall below 35 again

## HD THRESHOLD TEMPS
## HD change temperature slowly. 
## This is the temperature that we regard as being uncomfortable. The higher this is the
## more silent your system.
## Note, it is possible for your HDs to go above this... but if your cooling is good, they shouldn't.
# $hd_ave_target = 38.0;   # define this value in the DEFAULT VALUES block at top of script
$hd_max_allowed_temp = 40; # celsius. PID control aborts and fans set to 100% duty cycle when a HD hits this temp.
                           # This ensures that no matter how poorly chosen the PID gains are, or how much of a spread
                           # there is between the average HD temperature and the maximum HD temperature, the HD fans 
                           # will be set to 100% if any drive reaches this temperature.

## NUMBER OF WARMEST HD TO AVERAGE                           
# $hd_num_peak = 4;        # average the temperatures of this many warmest hard drives when calculating the average disk temperature

## CPU TEMP TO OVERRIDE HD FANS
## when the CPU climbs above this temperature, the HD fans will be overridden
## this prevents the HD fans from spinning up when the CPU fans are capable of providing 
## sufficient cooling.
$cpu_hd_override_temp = 65;

## CPU/HD SHARED COOLING
## If your HD fans contribute to the cooling of your CPU you should set this value.
## It will mean when you CPU heats up your HD fans will be turned up to help cool the
## case/cpu. This would only not apply if your HDs and fans are in a separate thermal compartment.
$hd_fans_cool_cpu = 1;      # 1 if the hd fans should spin up to cool the cpu, 0 otherwise

## HD FAN DUTY CYCLE TO OVERRIDE CPU FANS
$cpu_fans_cool_hd            = 1;  # 1 if the CPU fans should spin up to cool the HDs, when needed.  0 otherwise.  This may be 
                                   #   useful if the CPU fan zone also contains chassis exit fans, as an increase in chassis exit 
                                   #   fan speed may increase the HD cooling air flow.
$hd_cpu_override_duty_cycle = 95;  # when the HD duty cycle equals or exceeds this value, the CPU fans may be overridden to help cool HDs

## CPU TEMP CONTROL
$cpu_temp_control = 1;  # 1 if the script will control a CPU fan to control CPU temperatures.  0 if the script only controls HD fans.

## PID CONTROL GAINS
## If you were using the spinpid.sh PID control script published by @Glorious1 at the link below, you will need to adjust the value of $Kp
## that you were using, as that script defined Kp in terms of the gain per one cycle around the loop, but this script defines it in terms
## of the gain per minute.  Divide the Kp value from the spinpid.sh script by the time in minutes for checking hard drive temperatures. 
## For example, if you used a gain of Kp = 8, and a T = 3 (3 minute interval), the new value is $Kp = 8/3.
## Kd values from the spinpid.sh script can be used directly here.
## https://forums.freenas.org/index.php?threads/script-to-control-fan-speed-in-response-to-hard-drive-temperatures.41294/page-4#post-285668
#$Kp = 8/3;
# $Kp = 16/3; # define this value in the DEFAULT VALUES block at top of script
# $Ki = 0;    # define this value in the DEFAULT VALUES block at top of script
# $Kd =  96;  # define this value in the DEFAULT VALUES block at top of script

#######################
## FAN CONFIGURATION
####################

## FAN SPEEDS
## You need to determine the actual max fan speeds that are achieved by the fans
## Connected to the cpu_fan_header and the hd_fan_header.
## These values are used to verify high/low fan speeds and trigger a BMC reset if necessary.
$cpu_max_fan_speed    = 1800;
$hd_max_fan_speed     = 3300;


## CPU FAN DUTY LEVELS
## These levels are used to control the CPU fans
$fan_duty_high         = 100;    # percentage on, ie 100% is full speed.
$fan_duty_med          =  60;
$fan_duty_low          =  30;

## HD FAN DUTY LEVELS
## These levels are used to control the HD fans
$hd_fan_duty_high      = 100;    # percentage on, ie 100% is full speed.
$hd_fan_duty_med_high  =  80;
$hd_fan_duty_med_low   =  50;
$hd_fan_duty_low       =  16;    # some 120mm fans stall below 30.
#$hd_fan_duty_start    =  60;    # HD fan duty cycle when script starts - defined in config file


## FAN ZONES
# Your CPU/case fans should probably be connected to the main fan sockets, which are in fan zone zero
# Your HD fans should be connected to FANA which is in Zone 1
# You could switch the CPU/HD fans around, as long as you change the zones and fan header configurations.
#
# 0 = FAN1..5
# 1 = FANA..FANC
$cpu_fan_zone = 0;
$hd_fan_zone  = 1;


## FAN HEADERS
## these are the fan headers which are used to verify the fan zone is high. FAN1+ are all in Zone 0, FANA is Zone 1.
## cpu_fan_header should be in the cpu_fan_zone
## hd_fan_header should be in the hd_fan_zone
$cpu_fan_header = "FAN2";                 # used for printing to standard output for debugging   
$hd_fan_header  = "FANB";                 # used for printing to standard output for debugging   
@hd_fan_list = ("FANA", "FANB", "FANC");  # used for logging to file  


################
## MISC
#######

## IPMITOOL PATH
## The script needs to know where ipmitool is
$ipmitool = "/usr/local/bin/ipmitool";

## HD POLLING INTERVAL
## The controller will only poll the harddrives periodically. Since hard drives change temperature slowly
## this is a good thing. 180 seconds is a good value.
$hd_polling_interval = 90;    # seconds

## FAN SPEED CHANGE DELAY TIME
## It takes the fans a few seconds to change speeds, we allow a grace before verifying. If we fail the verify
## we'll reset the BMC
$fan_speed_change_delay = 10; # seconds

## BMC REBOOT TIME
## It takes the BMC a number of seconds to reset and start providing sensible output. We'll only
## Reset the BMC if its still providing rubbish after this time.
$bmc_reboot_grace_time = 120; # seconds

## BMC RETRIES BEFORE REBOOTING
## We verify high/low of fans, and if they're not where they should be we reboot the BMC after so many failures
$bmc_fail_threshold    = 1;     # will retry n times before rebooting

# edit nothing below this line
########################################################################################################################


# GLOBALS
@hd_list = ();

# massage fan speeds
$cpu_max_fan_speed *= 0.8;
$hd_max_fan_speed *= 0.8;

$hd_duty = $hd_fan_duty_start;

#fan/bmc verification globals/timers
$last_fan_level_change_time = 0;        # the time when we changed a fan level last
$fan_unreadable_time        = 0;        # the time when a fan read failure started, 0 if there is none.
$bmc_fail_count             = 0;        # how many times the fans failed verification in the last period. 

#this is the last cpu temp that was read        
$last_cpu_temp = 0;

use POSIX qw(strftime);
use Time::Local;

$SIG{INT} = sub { print "\nCaught SIGINT: setting fan mode to optimal\n"; set_fan_mode("optimal"); exit(0); };
$SIG{TERM} = sub { print "\nCaught SIGTERM: setting fan mode to optimal\n"; set_fan_mode("optimal"); exit(0); };
$SIG{HUP} = sub { print "\nCaught SIGHUP: setting fan mode to optimal\n"; set_fan_mode("optimal"); exit(0); };

# start the controller
main();

################################################ MAIN

sub main
{
    open LOG, ">>", $log or die $!;
    open DEBUG_LOG, ">>", $debug_log or die $!;

    ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start) = read_config();
    
    # Print Log Header
    @hd_list = get_hd_list();
    print_log_header(@hd_list);
    # current time
    ($sec,$min,$hour,$day,$month,$year,$wday,$yday,$isdst) = localtime(time);
    $next_log_hour = ( int( $hour/$log_header_hourly_interval ) + 1 ) * $log_header_hourly_interval;
    
    if ( $next_log_hour >= 24 )
    {
        # next log time is after midnight.  Roll back to previous log time, calcuate Unix epoch seconds, and add required seconds to get next log time
        $next_log_hour -= $log_header_hourly_interval;
        $next_log_time = timelocal(0,0,$next_log_hour,$day,$month,$year) + 3600 * $log_header_hourly_interval;
    }
    else
    {
        # next log time in seconds past Unix epoch
        $next_log_time = timelocal(0,0,$next_log_hour,$day,$month,$year);
    }
    
    # need to go to Full mode so we have unfettered control of Fans
    set_fan_mode("full");
    
    my $cpu_fan_level = ""; 
    my $old_cpu_fan_level = "";
    my $override_hd_fan_level = 0;
    my $last_hd_check_time = 0;
    $temp_error = 0;
    my $integral = 0;
    $cpu_fan_override = 0;
    $hd_fan_duty = $hd_fan_duty_start;

    ($hd_min_temp, $hd_max_temp, $hd_ave_temp_old, @hd_temps) = get_hd_temps();
    ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time) = read_config();
    
    while()
    {
        if ($cpu_temp_control)
        {
            $old_cpu_fan_level = $cpu_fan_level;
            $cpu_fan_level = control_cpu_fan( $old_cpu_fan_level );
        
            if( $old_cpu_fan_level ne $cpu_fan_level )
            {
                $last_fan_level_change_time = time;
            }

            if( $cpu_fan_level eq "high" )
            {
            
                if( $hd_fans_cool_cpu && !$override_hd_fan_level && ($last_cpu_temp >= $cpu_hd_override_temp || $last_cpu_temp == 0) )
                {
                    #override hd fan zone level, once we override we won't backoff until the cpu drops to below "high"
                    $override_hd_fan_level = 1;
                    dprint( 0, "CPU Temp: $last_cpu_temp >= $cpu_hd_override_temp, Overiding HD fan zone to $hd_fan_duty_high%, \n" );
                    set_fan_zone_duty_cycle( $hd_fan_zone, $hd_fan_duty_high );
                
                    $last_fan_level_change_time = time;
                }
            }
            elsif( $override_hd_fan_level )
            {
                #restore hd fan zone level;
                $override_hd_fan_level = 0;
                dprint( 0, "Restoring HD fan zone to $hd_fan_duty%\n" );
                set_fan_zone_duty_cycle( $hd_fan_zone, $hd_fan_duty );    
            
                $last_fan_level_change_time = time;
            }
        }

        # periodically determine hd fan zone level
        
        my $check_time = time;
        if( $check_time - $last_hd_check_time >= $hd_polling_interval )
        {
            $last_hd_check_time = $check_time;
            @last_hd_list = @hd_list;
            
            # check to see if config file has been updated.  If so, update the config values and print a new log header
            $config_time_new = (stat($config_file))[9];

            if ($config_time_new > $config_time)
            {
                ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time) = read_config();
                print_log_header(@hd_list);
            }
            
    
            # we refresh the hd_list from camcontrol devlist
            # everytime because if you're adding/removing HDs we want
            # starting checking their temps too!
            @hd_list = get_hd_list();
            
            ($hd_min_temp, $hd_max_temp, $hd_ave_temp, @hd_temps) = get_hd_temps();
            $hd_fan_duty_old = $hd_fan_duty;
            $hd_fan_duty = calculate_hd_fan_duty_cycle_PID( $hd_max_temp, $hd_ave_temp, $hd_fan_duty );
            
            if( !$override_hd_fan_level )
            {
                set_fan_zone_duty_cycle( $hd_fan_zone, $hd_fan_duty );

                $last_fan_level_change_time = time; # this resets every time, but it shouldn't matter since hd_polling_interval is large.
            }
            # print to log
            if (@hd_list != @last_hd_list && $log_temp_summary_only == 0)
            {
                # print new disk iD header if it has changed (e.g. hot swap insert or remove)
                @hd_list = print_log_header(@hd_list);
            }
            elsif ( $check_time >= $next_log_time )
            {
                # time to print a new log header
                @hd_list = print_log_header(@hd_list);
                $next_log_time += 3600 * $log_header_hourly_interval;
            }
            
            my $timestring = build_time_string();
            # ($hd_min_temp, $hd_max_temp, $hd_ave_temp, @hd_temps) = get_hd_temps();
            
            print LOG "$timestring";
            
            if ($log_temp_summary_only)
            {
                printf(LOG "    %2i", 0+@hd_list); # number of HDs, so it can be seen if a hot swap addition or removal was detected
                printf(LOG "   %2i", $hd_min_temp);
            }
            else
            {
                foreach my $item (@hd_temps)
                {
                    printf(LOG "%5s", $item);
                }
            }
            printf(LOG "  ^%2i", $hd_max_temp);
            printf(LOG "%7.2f", $hd_ave_temp);
            printf(LOG "%6.2f", $hd_ave_temp - $hd_ave_target);
            
            $hd_fan_mode = get_fan_mode();
            printf(LOG "%6s", $hd_fan_mode);
	    
	    sleep 10; # pause 10s to allow fans to change speed after setting it
            $ave_fan_speed = get_fan_ave_speed(@hd_fan_list);
            printf(LOG "%6s", $ave_fan_speed);
            printf(LOG "%4i/%-3i", $hd_fan_duty_old, $hd_fan_duty);
            
            $cput = get_cpu_temp_sysctl();
            printf(LOG "%4i %6.2f %6.2f  %6.2f  %6.2f%\n", $cput, $P, $I, $D, $hd_duty);
        }
        
        # verify_fan_speed_levels function is fairly complicated
        if ($cpu_temp_control)
        {
            verify_fan_speed_levels(  $cpu_fan_level, $override_hd_fan_level ? $hd_fan_duty_high : $hd_fan_duty );
        }
        else
        {
            verify_fan_speed_levels2( $hd_fan_duty );
        }
        
#         if ($cpu_temp_control)
#         {
#             # CPU temps can go from cool to hot in 2 seconds! so we only ever sleep for 1 second.
#             sleep 1;
#         }
#         else
#         {
#             sleep $hd_polling_interval - 1;
#         }
        # CPU temps can go from cool to hot in 2 seconds! so we only ever sleep for 1 second.
        sleep 1;

    } # inf loop
}

################################################# SUBS
sub get_hd_list
{
    my $disk_list = `camcontrol devlist | grep -v "SSD" | grep -v "Verbatim" | grep -v "Kingston" | grep -v "Elements" | sed 's:.*(::;s:).*::;s:,pass[0-9]*::;s:pass[0-9]*,::' | egrep '^[a]*da[0-9]+\$' | tr '\012' ' '`;
    dprint(3,"$disk_list\n");

    my @vals = split(" ", $disk_list);
    
    foreach my $item (@vals)
    {
        dprint(2,"$item\n");
    }

    return @vals;
}

sub get_hd_temp
{
    my $max_temp = 0;
    
    foreach my $item (@hd_list)
    {
        my $disk_dev = "/dev/$item";
        my $command = "/usr/local/sbin/smartctl -A $disk_dev | grep Temperature_Celsius";
         
        dprint( 3, "$command\n" );
        
        my $output = `$command`;

        dprint( 2, "$output");

        my @vals = split(" ", $output);

        # grab 10th item from the output, which is the hard drive temperature (on Seagate NAS HDs)
          my $temp = "$vals[9]";
        chomp $temp;
        
        if( $temp )
        {
            dprint( 1, "$disk_dev: $temp\n");
            
            $max_temp = $temp if $temp > $max_temp;
        }
    }

    dprint(0, "Maximum HD Temperature: $max_temp\n");

    return $max_temp;
}

sub get_hd_temps
# return minimum, maximum, average HD temperatures and array of individual temps
{
    my $max_temp = 0;
    my $min_temp = 1000;
    my $temp_sum = 0;
    my $HD_count = 0;
    my @temp_list = ();

    foreach my $item (@hd_list)
    {
        my $disk_dev = "/dev/$item";
        my $command = "/usr/local/sbin/smartctl -A $disk_dev | grep Temperature_Celsius";

        my $output = `$command`;

        my @vals = split(" ", $output);

        # grab 10th item from the output, which is the hard drive temperature (on Seagate NAS HDs)
        my $temp = "$vals[9]";
        chomp $temp;

        if( $temp )
        {
            push(@temp_list, $temp);
            $temp_sum += $temp;
            $HD_count +=1;
            $max_temp = $temp if $temp > $max_temp;
            $min_temp = $temp if $temp < $min_temp;
        }
    }

    my @temps_sorted = sort { $a <=> $b } @temp_list;

    $temp_sum = 0;
    for (my $n = $hd_num_peak; $n > 0; $n = $n -1) {
	$temp_sum += pop(@temps_sorted);
	}

    my $ave_temp = $temp_sum / $hd_num_peak;

    return ($min_temp, $max_temp, $ave_temp, @temp_list);
}

sub verify_fan_speed_levels
{
    my( $cpu_fan_level, $hd_fan_duty ) = @_;
    dprint( 4, "verify_fan_speed_levels: cpu_fan_level: $cpu_fan_level, hd_fan_duty: $hd_fan_duty\n");

    my $extra_delay_before_next_check = 0;
    
    my $temp_time = time - $last_fan_level_change_time;
    dprint( 4, "Time since last verify : $temp_time, last change: $last_fan_level_change_time, delay: $fan_speed_change_delay\n");
    if( $temp_time > $fan_speed_change_delay )
    {
        # we've waited for the speed change to take effect.
        
        my $cpu_fan_speed = get_fan_speed("CPU");
        if( $cpu_fan_speed < 0 )
        {
            dprint(1,"CPU Fan speed unavailable\n" );
            $fan_unreadable_time = time if $fan_unreadable_time == 0;
        }
        
        my $hd_fan_speed = get_fan_speed("HD");
        if( $hd_fan_speed < 0 )
        {
            dprint(1,"HD Fan speed unavailable\n" );
            $fan_unreadable_time = time if $fan_unreadable_time == 0;
        }
        
        if( $hd_fan_speed < 0 || $cpu_fan_speed < 0 )
        {
            # one of the fans couldn't be reliably read

            my $temp_time = time - $fan_unreadable_time;
            if( $temp_time > $bmc_reboot_grace_time )
            {
                #we've waited, and we still can't read fan speed.
                dprint(0, "Fan speeds are unreadable after $bmc_reboot_grace_time seconds, rebooting BMC\n");
                reset_bmc();
                $fan_unreadable_time = 0;
            }
            else
            {
                dprint(2, "Fan speeds are unreadable after $temp_time seconds, will try again\n");  
            }       
        }
        else
        {
            # we have no been able to read the fan speeds

            my $cpu_fan_is_wrong = 0;
            my $hd_fan_is_wrong = 0;    
            
            #verify cpu fans
            if( $cpu_fan_level eq "high" && $cpu_fan_speed < $cpu_max_fan_speed )
            {
                dprint(0, "CPU fan speed should be high, but $cpu_fan_speed < $cpu_max_fan_speed.\n");
                $cpu_fan_is_wrong=1;
            }
            elsif( $cpu_fan_level eq "low" && $cpu_fan_speed > $cpu_max_fan_speed )
            {
                dprint(0, "CPU fan speed should be low, but $cpu_fan_speed > $cpu_max_fan_speed.\n");
                $cpu_fan_is_wrong=1;
            }
            
            #verify hd fans
            if( $hd_fan_duty >= $hd_fan_duty_high && $hd_fan_speed < $hd_max_fan_speed )
            {
                dprint(0, "HD fan speed should be high, but $hd_fan_speed < $hd_max_fan_speed.\n");
                $hd_fan_is_wrong=1;
            }
            elsif( $hd_fan_duty <= $hd_fan_duty_low && $hd_fan_speed > $hd_max_fan_speed )
            {
                dprint(0, "HD fan speed should be low, but $hd_fan_speed > $hd_max_fan_speed.\n");
                $hd_fan_is_wrong=1;
            }
            
            #verify both fans are good
            if( $cpu_fan_is_wrong || $hd_fan_is_wrong )
            {
                $bmc_fail_count++;
                
                dprint( 3, "bmc_fail_count:  $bmc_fail_count, bmc_fail_threshold: $bmc_fail_threshold\n");
                if( $bmc_fail_count <= $bmc_fail_threshold )
                {
                    #we'll try setting the fan speeds, and giving it another attempt
                    dprint(1, "Fan speeds are not where they should be, will try again.\n");

                    set_fan_mode("full");

                    set_fan_zone_level( $cpu_fan_zone, $cpu_fan_level );
                    set_fan_zone_duty_cycle( $hd_fan_zone, $hd_fan_duty );
                }
                else
                {
                    #time to reset the bmc
                    dprint(1, "Fan speeds are still not where they should be after $bmc_fail_count attempts, will reboot BMC.\n");
                    set_fan_mode("full");
                    reset_bmc();
                    $bmc_fail_count = 0;
                }
            }
            else
            {
                #everything is good. We'll sit back for another minute.

                dprint( 2, "Verified fan levels, CPU: $cpu_fan_speed, HD: $hd_fan_speed. All good.\n" );
                $bmc_fail_count = 0; # we succeeded

                $extra_delay_before_next_check = 60 - $fan_speed_change_delay; # lets give it a minute since it was good.
            }   

                
            #reset our unreadable timer, since we read the fan speeds.
            $fan_unreadable_time = 0;
                                    
        }
            
        #reset our timer, so that we'll wait before checking again.
        $last_fan_level_change_time = time + $extra_delay_before_next_check; #another delay before checking please.
    }
    
    return;
}

sub verify_fan_speed_levels2
{
    my( $hd_fan_duty ) = @_;
    dprint( 4, "verify_fan_speed_level: hd_fan_duty: $hd_fan_duty\n");

    my $extra_delay_before_next_check = 0;
    
    my $temp_time = time - $last_fan_level_change_time;
    dprint( 4, "Time since last verify : $temp_time, last change: $last_fan_level_change_time, delay: $fan_speed_change_delay\n");
    if( $temp_time > $fan_speed_change_delay )
    {
        # we've waited for the speed change to take effect.
        
        my $hd_fan_speed = get_fan_speed("HD");
        if( $hd_fan_speed < 0 )
        {
            dprint(1,"HD Fan speed unavailable\n" );
            $fan_unreadable_time = time if $fan_unreadable_time == 0;
        }
        
        if( $hd_fan_speed < 0 )
        {
            # one of the fans couldn't be reliably read

            my $temp_time = time - $fan_unreadable_time;
            if( $temp_time > $bmc_reboot_grace_time )
            {
                #we've waited, and we still can't read fan speed.
                dprint(0, "Fan speeds are unreadable after $bmc_reboot_grace_time seconds, rebooting BMC\n");
                reset_bmc();
                $fan_unreadable_time = 0;
            }
            else
            {
                dprint(2, "Fan speeds are unreadable after $temp_time seconds, will try again\n");  
            }       
        }
        else
        {
            # we have no been able to read the fan speeds

            my $hd_fan_is_wrong = 0;    
            
            #verify hd fans
            if( $hd_fan_duty >= $hd_fan_duty_high && $hd_fan_speed < $hd_max_fan_speed )
            {
                dprint(0, "HD fan speed should be high, but $hd_fan_speed < $hd_max_fan_speed.\n");
                $hd_fan_is_wrong=1;
            }
            elsif( $hd_fan_duty <= $hd_fan_duty_low && $hd_fan_speed > $hd_max_fan_speed )
            {
                dprint(0, "HD fan speed should be low, but $hd_fan_speed > $hd_max_fan_speed.\n");
                $hd_fan_is_wrong=1;
            }
            
            #verify HD fans are good
            if( $hd_fan_is_wrong )
            {
                $bmc_fail_count++;
                
                dprint( 3, "bmc_fail_count:  $bmc_fail_count, bmc_fail_threshold: $bmc_fail_threshold\n");
                if( $bmc_fail_count <= $bmc_fail_threshold )
                {
                    #we'll try setting the fan speeds, and giving it another attempt
                    dprint(1, "Fan speeds are not where they should be, will try again.\n");

                    set_fan_mode("full");

                    set_fan_zone_duty_cycle( $hd_fan_zone, $hd_fan_duty );
                }
                else
                {
                    #time to reset the bmc
                    dprint(1, "Fan speeds are still not where they should be after $bmc_fail_count attempts, will reboot BMC.\n");
                    set_fan_mode("full");
                    reset_bmc();
                    $bmc_fail_count = 0;
                }
            }
            else
            {
                #everything is good. We'll sit back for another minute.

                dprint( 2, "Verified fan levels, HD: $hd_fan_speed. All good.\n" );
                $bmc_fail_count = 0; # we succeeded

                $extra_delay_before_next_check = 60 - $fan_speed_change_delay; # lets give it a minute since it was good.
            }   

                
            #reset our unreadable timer, since we read the fan speeds.
            $fan_unreadable_time = 0;
                                    
        }
            
        #reset our timer, so that we'll wait before checking again.
        $last_fan_level_change_time = time + $extra_delay_before_next_check; #another delay before checking please.
    }
    
    return;
}

# need to pass in last $cpu_fan
sub control_cpu_fan
{
    my ($old_cpu_fan_level) = @_;

#    my $cpu_temp = get_cpu_temp_ipmi();    # no longer used, because sysctl is better, and more compatible.
    my $cpu_temp = get_cpu_temp_sysctl();

    my $cpu_fan_level = decide_cpu_fan_level( $cpu_temp, $old_cpu_fan_level );

    if( $old_cpu_fan_level ne $cpu_fan_level )
    {
            dprint( 1, "CPU Fan changing... ($cpu_fan_level)\n");
        set_fan_zone_level( $cpu_fan_zone, $cpu_fan_level );    
    }

    return $cpu_fan_level;
}

sub calculate_hd_fan_duty_cycle_PID
{
    my ($hd_max_temp, $hd_ave_temp, $old_hd_duty) = @_;
    # my $hd_duty;
    
    my $temp_error_old = $hd_ave_temp_old - $hd_ave_target;
    my $temp_error = $hd_ave_temp - $hd_ave_target;

    if ($hd_max_temp >= $hd_max_allowed_temp  ) 
    {
        $hd_duty = $hd_fan_duty_high;
        dprint(0, "Drives are too hot, going to $hd_fan_duty_high%\n") unless $old_hd_duty == $hd_duty;
     }
    elsif ($hd_max_temp >= 0 )
    {
        my $temp_error = $hd_ave_temp - $hd_ave_target;
        $integral += $temp_error * $hd_polling_interval / 60;
        my $derivative = ($temp_error - $temp_error_old) * 60 / $hd_polling_interval;
        # my $P = $Kp * $temp_error * $hd_polling_interval / 60;
        # my $I = $Ki * $integral;
        # my $D = $Kd * $derivative;
        $P = $Kp * $temp_error * $hd_polling_interval / 60;
        $I = $Ki * $integral;
        $D = $Kd * $derivative;
        # $hd_duty = $old_hd_duty + $P + $I + $D;
        $hd_duty = $hd_duty + $P + $I + $D;

        if ($hd_duty > $hd_fan_duty_high)
        {
            $hd_duty = $hd_fan_duty_high;
        }
        elsif ($hd_duty < $hd_fan_duty_low)
        {
            $hd_duty = $hd_fan_duty_low;
        }

        dprint(0, "temperature error = $temp_error\n");
        dprint(1, "PID corrections are P = $P, I = $I and D = $D\n");
        dprint(0, "PID control new duty cycle is $hd_duty%\n") unless $old_hd_duty == $hd_duty;
    }
    else
    {
        $hd_duty = 100;
        dprint( 0, "Drive temperature ($hd_temp) invalid. going to 100%\n");
    }
    
    $hd_ave_temp_old = $hd_ave_temp;
    
    if ($cpu_fans_cool_hd == 1 && $hd_duty > $hd_cpu_override_duty_cycle)
    {
        $cpu_fan_override = 1;
    }
    else
    {
        $cpu_fan_override = 0;
    }
    # $hd_duty is retained as float between cycles, so any small incremental adjustments less 
    # than 1 will not be lost, but build up until they are large enough to cause a change 
    # after the value is truncated with int()

    # add 0.5 before truncating with int() to approximate the behaviour of a proper round() function
    return int($hd_duty + 0.5);
}

sub build_date_time_string
{
    my $datetimestring = strftime "%F %H:%M:%S", localtime;
    
    return $datetimestring;
}

sub build_date_string
{
    my $datestring = strftime "%F", localtime;
    
    return $datestring;
}

sub build_time_string
{
    my $timestring = strftime "%H:%M:%S", localtime;
    
    return $timestring;
}

sub print_log_header
{
    @hd_list = @_;
    my $timestring = build_time_string();
    my $datestring = build_date_string();
    printf(LOG "\n\nPID Fan Controller Log  ---  Target $hd_num_peak Disk HD Temperature = %5.2f deg C  ---  PID Control Gains: Kp = %6.3f, Ki = %6.3f, Kd = %5.1f\n         ", $hd_ave_target, $Kp, $Ki, $Kd);
    if ($log_temp_summary_only)
    {
        print LOG "   HD   Min";
    }
    else
    {
        foreach $item (@hd_list)
        {
            print LOG "     ";
        }
    }
    
    print LOG "  Max   Ave  Temp   Fan   Fan  Fan %   CPU    P      I      D      Fan\n$datestring";
    
    if ($log_temp_summary_only)
    {
        print LOG " Qty  Temp ";
    }
    else
    {
        foreach $item (@hd_list)
        {
            printf(LOG "%4s ", $item);
        }
    }
    
    print LOG "Temp  Temp   Err  Mode   RPM Old/New Temp  Corr   Corr   Corr    Duty\n";
    
    return @hd_list;
}

sub get_fan_ave_speed
{
    my $speed_sum = 0;
    my $fan_count = 0;
    foreach my $fan (@_)
    {
        $speed_sum += get_fan_speed2($fan);
        $fan_count += 1;
    }
    
    my $ave_speed = sprintf("%i", $speed_sum / $fan_count);
    
    return $ave_speed;
}

sub dprint
{
    my ( $level,$output) = @_;
    
#    print( "dprintf: debug = $debug, level = $level, output = \"$output\"\n" );
    
    if( $debug > $level ) 
    {
        my $datestring = build_date_time_string();
        print DEBUG_LOG "$datestring: $output";
    }

    return;
}

sub dprint_list
{
    my ( $level,$name,@output) = @_;
        
    if( $debug > $level ) 
    {
        dprint($level,"$name:\n");

        foreach my $item (@output)
        {
            dprint( $level, " $item\n");
        }
    }

    return;
}

sub bail_with_fans_full
{
    dprint( 0, "Setting fans full before bailing!\n");
    set_fan_mode("full");
    die @_;
}

sub get_fan_mode
{
    my $command = "$ipmitool raw 0x30 0x45 0";
    my $fan_code = `$command`;
    
    if ($fan_code == 1) { $hd_fan_mode = "Full"; }
    elsif ($fan_code == 0) { $hd_fan_mode = " Std"; }
    elsif ($fan_code == 2) { $hd_fan_mode = " Opt"; }
    elsif ($fan_code == 4) { $hd_fan_mode = " Hvy"; }
    
    return $hd_fan_mode;
}

sub get_fan_mode_code
{
    my ( $fan_mode )  = @_;
    my $m;

    if(     $fan_mode eq    'standard' )    { $m = 0; }
    elsif(    $fan_mode eq    'full' )     { $m = 1; }
    elsif(    $fan_mode eq    'optimal' )     { $m = 2; }
    elsif(    $fan_mode eq    'heavyio' )    { $m = 4; }
    else                     { die "illegal fan mode: $fan_mode\n" }

    dprint( 3, "fanmode: $fan_mode = $m\n"); 

    return $m;
}

sub set_fan_mode
{
    my ($fan_mode) = @_;
    my $mode = get_fan_mode_code( $fan_mode );

    dprint( 1, "Setting fan mode to $mode ($fan_mode)\n");
    `$ipmitool raw 0x30 0x45 0x01 $mode`;

    sleep 5;    #need to give the BMC some breathing room

    return;
}    

# returns the maximum core temperature from the kernel to determine CPU temperature.
# in my testing I found that the max core temperature was pretty much the same as the IPMI 'CPU Temp'
# value, but its much quicker to read, and doesn't require X10 IPMI. And works when the IPMI is rebooting too.
sub get_cpu_temp_sysctl
{
    # significantly more efficient to filter to dev.cpu than to just grep the whole lot!
    my $core_temps = `sysctl -a dev.cpu | egrep -E \"dev.cpu\.[0-9]+\.temperature\" | awk '{print \$2}' | sed 's/.\$//'`;
    chomp($core_temps);

    dprint(3,"core_temps:\n$core_temps\n");

    my @core_temps_list = split(" ", $core_temps);
    
    dprint_list( 4, "core_temps_list", @core_temps_list );

    my $max_core_temp = 0;
    
    foreach my $core_temp (@core_temps_list)
    {
        if( $core_temp )
        {
            dprint( 2, "core_temp = $core_temp C\n");
            
            $max_core_temp = $core_temp if $core_temp > $max_core_temp;
        }
    }

    dprint(1, "CPU Temp: $max_core_temp\n");

    $last_cpu_temp = $max_core_temp; #possible that this is 0 if there was a fault reading the core temps

    return $max_core_temp;
}

# reads the IPMI 'CPU Temp' field to determine overall CPU temperature
sub get_cpu_temp_ipmi
{
    my $cpu_temp = `$ipmitool sensor get \"CPU Temp\" | awk '/Sensor Reading/{print \$4}'`;
    chomp $cpu_temp;

    dprint( 1, "CPU Temp: $cpu_temp\n");
    
    $last_cpu_temp = $cpu_temp; # note, this hasn't been cleaned.
    return $cpu_temp;
}

sub decide_cpu_fan_level
{
    my ($cpu_temp, $cpu_fan) = @_;
    
    if ($cpu_fan_override == 1)
    {
        if( $cpu_fan ne "high" )
        {
            $cpu_fan = "high";
            dprint( 0, "CPU fan set to high to help cool HDs.\n");
        }
    }
    else
    {
        #if cpu_temp evaluates as "0", its most likely the reading returned rubbish.
        if ($cpu_temp <= 0) 
        {
            if( $cpu_temp eq "No")    # "No reading" 
            {
                dprint( 0, "CPU Temp has no reading.\n");
            }
            elsif( $cpu_temp eq "Disabled" )
            {
                dprint( 0, "CPU Temp reading disabled.\n");
            }
            else
            {
                dprint( 0, "Unexpected CPU Temp ($cpu_temp).\n");
            }
            dprint( 0, "Assuming worst-case and going high.\n");
            $cpu_fan = "high";
        } 
        else
        {
            if( $cpu_temp >= $high_cpu_temp )
            {
                if( $cpu_fan ne "high" )
                {
                    dprint( 0, "CPU Temp: $cpu_temp >= $high_cpu_temp, CPU Fan going high.\n");
                }
                $cpu_fan = "high";
            }
            elsif( $cpu_temp >= $med_cpu_temp )
            {
                if( $cpu_fan ne "med" )
                {
                    dprint( 0, "CPU Temp: $cpu_temp >= $med_cpu_temp, CPU Fan going med.\n");
                }
                $cpu_fan = "med";
            }
            elsif( $cpu_temp > $low_cpu_temp && ($cpu_fan eq "high" || $cpu_fan eq "" ) )
            {
                dprint( 0, "CPU Temp: $cpu_temp dropped below $med_cpu_temp, CPU Fan going med.\n");
            
                $cpu_fan = "med";
            }
            elsif( $cpu_temp <= $low_cpu_temp )
            {
                if( $cpu_fan ne "low" )
                {
                    dprint( 0, "CPU Temp: $cpu_temp <= $low_cpu_temp, CPU Fan going low.\n");
                }
                $cpu_fan = "low";
            }
        }
    }
        
    dprint( 1, "CPU Fan: $cpu_fan\n");

    return $cpu_fan;
} 

# zone,dutycycle%
sub set_fan_zone_duty_cycle
{
    my ( $zone, $duty ) = @_;
    
    if( $zone < 0 || $zone > 1 )
    {
        bail_with_fans_full( "Illegal Fan Zone" );
    }

    if( $duty < 0 || $duty > 100 )
    {
        dprint( 0, "illegal duty cycle, assuming 100%\n");
        $duty = 100;
    }
        
    dprint( 1, "Setting Zone $zone duty cycle to $duty%\n");

    `$ipmitool raw 0x30 0x70 0x66 0x01 $zone $duty`;
    
    return;
}


sub set_fan_zone_level
{
    my ( $fan_zone, $level) = @_;
    my $duty = 0;
    
    #assumes high if not low or med, for safety.
    if( $level eq "low" )
    {
        $duty = $fan_duty_low;
    }
    elsif( $level eq "med" )
    {
        $duty = $fan_duty_med;
    }
    else
    {
        $duty = $fan_duty_high;
    }

    set_fan_zone_duty_cycle( $fan_zone, $duty );
}

sub get_fan_header_by_name
{
    my ($fan_name) = @_;
    
    if( $fan_name eq "CPU" )
    {
        return $cpu_fan_header;
    }
    elsif( $fan_name eq "HD" )
    {
        return $hd_fan_header;
    }
    else
    {
        bail_with_full_fans( "No such fan : $fan_name\n" );
    }
}

sub get_fan_speed
{
    my ($fan_name) = @_;
    
    my $fan = get_fan_header_by_name( $fan_name );

    my $command = "$ipmitool sdr | grep $fan";
    dprint( 4, "get fan speed command = $command\n");

     my $output = `$command`;
      my @vals = split(" ", $output);
      my $fan_speed = "$vals[2]";

    dprint( 3, "fan_speed = $fan_speed\n");


    if( $fan_speed eq "no" )
    {
        dprint( 0, "$fan_name Fan speed: No reading\n");
        $fan_speed = -1;
    }
    elsif( $fan_speed eq "disabled" )
    {
        dprint( 0, "$fan_name Fan speed: Disabled\n");
        $fan_speed = -1;

    }
    elsif( $fan_speed > 10000 || $fan_speed < 0 )
    {
        dprint( 0, "$fan_name Fan speed: $fan_speed RPM, is nonsensical\n");
        $fan_speed = -1;
    }
    else    
    {
        dprint( 1, "$fan_name Fan speed: $fan_speed RPM\n");
    }
    
    return $fan_speed;
}

sub get_fan_speed2
# get fan speed for specified fan header
{
    my ($fan_name) = @_;
    
    my $command = "$ipmitool sdr | grep $fan_name";

    my $output = `$command`;
    my @vals = split(" ", $output);
    my $fan_speed = "$vals[2]";
    
    return $fan_speed;
}

sub reset_bmc
{
    #when the BMC reboots, it comes back up in its last fan mode... which should be FULL.

    dprint( 0, "Resetting BMC\n");
    `$ipmitool bmc reset cold`;
    
    return;
}

sub read_config
{
    # read config file, if present
    if (do $config_file) 
    {
        $hd_ave_target = $config_Ta // $default_hd_ave_target;
        $Kp = $config_Kp // $default_Kp;
        $Ki = $config_Ki // $default_Ki;
        $Kd = $config_Kd // $default_Kd;
        $hd_num_peak = $config_num_disks // $default_hd_num_peak;            
        $hd_fan_duty_start = $config_hd_fan_start // $default_hd_fan_duty_start;
	$config_time = (stat($config_file))[9];
    } else {
        dprint( 0, "Config file not found.  Using default values!\n");
	print "config file not found\n";
    }
    return ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time);
}
