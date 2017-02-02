#!/usr/local/bin/bash
# spinpid2.sh for dual fan zones.
VERSION="2017-01-20"
# Run as superuser. See notes at end.

##############################################
#
#  Settings
#
##############################################

# Create logfile and sends all stdout and stderr to the log, as well as to the console.
# If you want to append to existing log, add '-a' to the tee command.
LOG=/root/spinpid2.log  # Change to your desired log location/name
exec > >(tee -i $LOG) 2>&1

# Supermicro says zone 0 (FAN1-x) is for CPU/system, and
# zone 1 (FANA-x) is for Peripheral (presumably including drives)
# Reverse that here if you want (i.e, if you hook drive cooling fans
# to FAN1-4 and CPU fan to FANA, set ZONE_CPU=1, ZONE_PER=0)
ZONE_CPU=0
ZONE_PER=1

FAN_MIN=25  # Fan minimum duty cycle (%) (to avoid stalling)

#################  DRIVE SETTINGS ################

SP=36   #  Setpoint mean drive temperature (C)

#  Time interval for checking drives (minutes).  Drives change
#  temperature slowly; 5 minutes is probably overkill.
T=3
Kp=16    #  Proportional tunable constant (for drives)
Ki=0    #  Integral tunable constant (for drives)
Kd=120   #  Derivative tunable constant (for drives)

#################  CPU SETTINGS ################

#  Time interval for checking CPU (seconds).  10 or 15
#  may be appropriate, but your CPU may need more frequent
#  monitoring.
CPU_T=5

#  Reference temperature (C) for scaling CPU_DUTY (NOT a setpoint).
#  At and below this temperature, CPU will demand minimum 
#  fan speed (FAN_MIN above).  Integer only!
CPU_REF=35
#  Scalar for scaling CPU_DUTY. Integer only!
#  CPU will demand this number of percentage points in additional
#  duty cycle for each degree of temperature above CPU_REF.
CPU_SCALE=3 # will provide 100% duty cycle at 60 deg C or higher, with FAN_MIN = 25% and CPU_REF = 35

##############################################
# function get_disk_name
# Get disk name from current LINE of DEVLIST
##############################################
# The awk statement works by taking $LINE as input,
# setting '(' as a _F_ield separator and taking the second field it separates
# (ie after the separator), passing that to another awk that uses
# ',' as a separator, and taking the first field (ie before the separator).
# In other words, everything between '(' and ',' is kept.

# camcontrol output for disks on HBA seems to change every version,
# so need 2 options to get ada/da disk name.
function get_disk_name {
   if [[ $LINE == *",p"* ]] ; then     # for ([a]da#,pass#)
      DEVID=$(echo $LINE | awk -F '(' '{print $2}' | awk -F ',' '{print$1}')
   else                                # for (pass#,[a]da#)
      DEVID=$(echo $LINE | awk -F ',' '{print $2}' | awk -F ')' '{print$1}')
   fi
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header {
   DATE=$(date +"%A, %b %d")
   let "SPACES = DEVCOUNT * 5 + 47"  # 5 spaces per drive
   printf "\n%-*s %3s %29s %16s %s \n" $SPACES "$DATE" "CPU" "Curr_RPM____________________" "New_Fan%" "Interim CPU"
   echo -n "          "
   while read LINE ; do
      get_disk_name
      printf "%-5s" $DEVID
   done <<< "$DEVLIST"             # while statement works on DEVLIST
   printf "%4s %5s %5s %6s %5s %6s %3s %5s %5s %5s %5s %5s %-7s %s %-4s %s" "Tmax" "Tmean" "ERRc" "P" "I" "D" "TEMP" "FANA" "FAN1" "FAN2" "FAN3" "FAN4" "MODE" "CPU" "PER" "Adjustments"
}

#################################################
# function read_fan_data
#################################################
function read_fan_data {

   # Read duty cycles, convert to decimal.
   # Duty cycle isn't provided reliably by all boards.  If necessary, 
   # disable the DUTY_ lines, and we'll just assume it is what we last set.
   DUTY_CPU=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_CPU) # in hex with leading space
   DUTY_CPU=$((0x$(echo $DUTY_CPU)))  # strip leading space and decimalize
   DUTY_PER=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_PER) # in hex with leading space
   DUTY_PER=$((0x$(echo $DUTY_PER)))  # strip leading space and decimalize

   # Read fan mode, convert to decimal, get text equivalent.
   MODE=$($IPMITOOL raw 0x30 0x45 0) # in hex with leading space
   MODE=$((0x$(echo $MODE)))  # strip leading space and decimalize
   # Text for mode
   case $MODE in
      0) MODEt="Standard" ;;
      1) MODEt="Full" ;;
      2) MODEt="Optimal" ;;
      4) MODEt="HeavyIO" ;;
   esac

   # Get reported fan speed in RPM from sensor data repository.
   # Takes the pertinent FAN line, then 3 to 5 consecutive digits
   SDR=$($IPMITOOL sdr)
   RPM_FAN1=$(echo "$SDR" | grep "FAN1" | grep -Eo '[0-9]{3,5}')
   RPM_FAN2=$(echo "$SDR" | grep "FAN2" | grep -Eo '[0-9]{3,5}')
   RPM_FAN3=$(echo "$SDR" | grep "FAN3" | grep -Eo '[0-9]{3,5}')
   RPM_FAN4=$(echo "$SDR" | grep "FAN4" | grep -Eo '[0-9]{3,5}')
   RPM_FANA=$(echo "$SDR" | grep "FANA" | grep -Eo '[0-9]{3,5}')
}

##############################################
# function CPU_check_adjust
# Get CPU temp.  Calculate a new DUTY_CPU.
# Send to function adjust_fans.
##############################################
function CPU_check_adjust {
	CPU_TEMP=$($IPMITOOL sdr | grep "CPU Temp" | grep -Eo '[0-9]{2,5}')
#	CPU_TEMP=$(sysctl -a | grep "cpu\.0\.temp" | awk -F ' ' '{print $2}' | awk -F '.' '{print$1}')
# 	DUTY_CPU=$( echo "scale=2; ($CPU_TEMP - $CPU_REF) * $CPU_SCALE + $FAN_MIN" | bc )
# 	DUTY_CPU=$( printf %0.f $DUTY_CPU )  # round

	# This will break if settings have non-integers
	let DUTY_CPU=(CPU_TEMP-CPU_REF)*CPU_SCALE+FAN_MIN

	adjust_fans $ZONE_CPU $DUTY_CPU $DUTY_CPU_LAST
}

##############################################
# function DRIVES_check_adjust
# Print time on new log line. 
# Go through each drive, getting and printing 
# status and temp.  Calculate max and mean
# temp, then calculate PID and new duty.
# Call adjust_fans.
##############################################
function DRIVES_check_adjust {
   echo  # start new line
   # print time on each line
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   Tmax=0; Tsum=0  # initialize drive temps for new loop through drives
   i=0  # count number of spinning drives
   while read LINE ; do
      get_disk_name
      TEMP=$(/usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" | grep "Temperature_Celsius" | grep -o "..$")
      /usr/local/sbin/smartctl -n standby "/dev/$DEVID" > /var/tempfile
      RETURN=$?               # need to preserve because $? changes with each 'if'
      if [[ $RETURN == "0" ]] ; then
         STATE="*"  # spinning
      elif [[ $RETURN == "2" ]] ; then
         STATE="_"  # standby
      else
         STATE="?"  # state unknown
      fi
      printf "%s%-2d  " "$STATE" $TEMP
      # Update temperatures each drive; spinners only
      if [ "$STATE" == "*" ] ; then
         let "Tsum += $TEMP"
         if [[ $TEMP > $Tmax ]]; then Tmax=$TEMP; fi;
         let "i += 1"
      fi
   done <<< "$DEVLIST"
   
   # summarize, calculate PID and print Tmax and Tmean
   Tmean=$(echo "scale=3; $Tsum / $i" | bc)
   ERRp=$ERRc
   ERRc=$(echo "scale=2; $Tmean - $SP" | bc)
   ERR=$(echo "scale=2; $ERRc * $T + $I" | bc)
   P=$(echo "scale=2; $Kp * $ERRc" | bc)
   I=$(echo "scale=2; $Ki * $ERR" | bc)
   D=$(echo "scale=2; $Kd * ($ERRc - $ERRp) / $T" | bc)
   PID=$(echo "scale=2; $P + $I + $D" | bc)  # add 3 corrections
   PID=$(printf %0.f $PID)  # round
   # print current Tmax, Tmean
   printf "^%-3d %5.2f" $Tmax $Tmean 

   let "DUTY_PER = $DUTY_PER_LAST + $PID"

   # pass to the function adjust_fans
   adjust_fans $ZONE_PER $DUTY_PER $DUTY_PER_LAST
}

##############################################
# function adjust_fans 
# Zone, new duty, and last duty are passed as parameters
##############################################
function adjust_fans {

   # parameters passed to this function
   ZONE=$1
   DUTY=$2
   DUTY_LAST=$3

   # Don't allow duty cycle below FAN_MIN nor above 95%
   if [[ $DUTY -gt 100 ]]; then DUTY=100; fi
   if [[ $DUTY -lt $FAN_MIN ]]; then DUTY=$FAN_MIN; fi
   
   # Change if different from last duty, update last duty.
   if [[ $DUTY -ne $DUTY_LAST ]]; then
      # Set new duty cycle. "echo -n ``" prevents newline generated in log
      echo -n `$IPMITOOL raw 0x30 0x70 0x66 1 $ZONE $DUTY`
      #  If interim CPU adjustment, print new CPU duty cycle
      if [[ ZONE -eq ZONE_CPU ]]; then 
      	DUTY_CPU_LAST=$DUTY
      	# add condition "&& CPU_LOOPS -lt xx" to avoid excessive interim updates
      	if [[ FIRST_TIME -eq 0 ]]; then printf "%d " $DUTY; fi
      else 
        DUTY_PER_LAST=$DUTY
      fi
   fi
}

#####################################################
# All this happens only at the beginning
# Initializing values, list of drives, print header
#####################################################
CPU_LOOPS=$( echo "$T * 60 / $CPU_T" | bc )  # Number of whole CPU loops per drive loop
IPMITOOL=/usr/local/bin/ipmitool
I=0; ERRc=0  # Initialize errors to 0
FIRST_TIME=1

# Get list of drives
DEVLIST1=$(/sbin/camcontrol devlist)
# Remove lines with flash drives or SSD; edit as needed
# You could use another strategy, e.g., find something in the camcontrol devlist
# output that is unique to the drives you want, for instance only WDC drives:
# if [[ $LINE != *"WDC"* ]] . . .
DEVLIST="$(echo "$DEVLIST1"|sed '/KINGSTON/d;/ADATA/d;/SanDisk/d;/SSD/d')"
DEVCOUNT=$(echo "$DEVLIST" | wc -l)

# This is only needed if DUTY_* is not read by ipmitool (i.e.
# we disable DUTY_* lines in read_fan_data and
# assume duty is what we last set.  In that case we need to 
# start with a guess so we don't spend so many cycles working up from 0.
DUTY_PER=65

read_fan_data # Get mode and rpm before script changes

# Need good value DUTY_PER_LAST for 1st adjustment 
# of DUTY_PER in DRIVES_check_adjust
DUTY_PER_LAST=$DUTY_PER

# Set mode to 'Full' to avoid BMC changing duty cycle
# Need to wait a tick or it may not get next command
# "echo -n ``" to avoid annoying newline generated in log
echo -n `$IPMITOOL raw 0x30 0x45 1 1`; sleep 1

# DON'T NEED THIS?
# Then start with 50% duty cycle and let algorithms adjust from there
# Pass zone, duty cycle and last duty cycle (20 just to bootstrap)
# adjust_fans 0 50 20; sleep 1
# adjust_fans 1 50 20

printf "\nKey to drive status symbols:  * spinning;  _ standby;  ? unknown               Version $VERSION \n"
print_header
CPU_check_adjust

###########################################
# Main loop through drives every T minutes
# and CPU every CPU_T seconds
###########################################
while [ 1 ] ; do
   # Print header every quarter day.  Expression removes any
   # leading 0 so it is not seen as octal
   HM=$(date +%k%M); HM=`expr $HM + 0`
   R=$(( HM % 600 ))  # remainder after dividing by 6 hours
   if (( $R < $T )); then
      print_header; 
   fi

   if [[ FIRST_TIME -eq 0 ]]; then 
      read_fan_data

      # Every cycle but the first, reset BMC if fans seem stuck and not obeying
      # This is pointless if we can't read the real DUTY_*
      if [[ $CPU_TEMP<$CPU_REF && $DUTY_CPU>90 ]] || [[ $DUTY_CPU<$FAN_MIN ]]; then
         $IPMITOOL bmc reset warm
         printf "\n%s\n" "CPU_TEMP=$CPU_TEMP; DUTY_CPU=$DUTY_CPU I reset the BMC because DUTY_CPU was much too high for CPU_TEMP or below FAN_MIN!"
      fi
      if [[ $Tmean<$SP && $DUTY_PER>90 ]] || [[ $DUTY_PER<$FAN_MIN ]]; then
         $IPMITOOL bmc reset warm
         printf "\n%s\n" "I reset the BMC because DUTY_PER was much too high for Tmean or below FAN_MIN!"
      fi
   fi

   FIRST_TIME=0

   DRIVES_check_adjust

   # If a fan doesn't exist, RPM value will be null.  These expressions 
   # substitute a value "---" if null so printing is not messed up
   printf "%6.2f %6.2f %5.2f %6.2f %4d %5s %5s %5s %5s %5s %-7s %3d %3d  " $ERRc $P $I $D $CPU_TEMP "${RPM_FANA:----}" "${RPM_FAN1:----}" "${RPM_FAN2:----}" "${RPM_FAN3:----}" "${RPM_FAN4:----}" $MODEt $DUTY_CPU_LAST $DUTY_PER_LAST

   i=0
   while [ $i -lt $CPU_LOOPS ]; do
      sleep $CPU_T
      CPU_check_adjust
      let i=i+1
   done
done

# For SuperMicro motherboards with dual fan zones.  Per Supermicro:
# Zone 0 - CPU or System fans, labelled with a number (e.g., FAN1, FAN2, etc.)
# Zone 1 - Peripheral fans, labelled with a letter (e.g., FANA, FANB, etc.)  
# You can reverse the zones if you wish so zone 1 controls CPU.

# Adjusts fans based on drive and CPU temperatures. 

# Mean temp among drives is maintained at a setpoint
# using a PID algorithm.  CPU temp need not and cannot be maintained 
# at a setpoint, so PID is not used; instead fan duty cycle is simply 
# increased with temp using reference and scale settings.

# Drives are checked and fans adjusted on a set interval, such as 6 minutes.
# Logging is done at that point.  CPU temps can spike much faster,
# so are checked at a shorter interval, such as 30 seconds.  

# Logs:
#   - Disk status (* spinning or _ standby)
#   - Disk temperature (Celsius) if spinning
#   - Max and mean disk temperature
#   - Temperature error and PID variables
#   - CPU temperature
#   - RPM for FANA and FAN1-4 before new duty cycles
#   - Fan mode
#   - New fan duty cycle in each zone
#   - Adjustments to CPU fan duty cycle due to interim CPU loops

# Includes disks on motherboard and on HBA. 

#  Relation between percent duty cycle, hex value of that number,
#  and RPMs for my fans.  RPM will vary among fans, is not
#  precisely related to duty cycle, and does not matter to the script.
#  It is merely reported.
#
#  Percent	Hex	    RPM
#  10	      A	    300
#  20	     14	    400
#  30	     1E	    500
#  40	     28	    600/700
#  50	     32	    800
#  60	     3C	    900
#  70	     46	    1000/1100
#  80	     50	    1100/1200
#  90	     5A	    1200/1300
# 100	     64	    1300

# Because some Supermicro boards report incorrect duty cycle,
# we don't read that.  Instead we assume it is what we set.

# Tuning suggestions
# PID tuning advice on the internet generally does not work well in this application.
# First run the script spincheck.sh and get familiar with your temperature and fan variations without any intervention.
# Choose a setpoint that is an actual observed Tmean, given the number of drives you have.  It should be the Tmean associated with the Tmax that you want.  
# Set Ki=0 and leave it there.  You probably will never need it.
# Start with Kp low.  Use a value that results in a rounded correction=1 when error is the lowest value you observe other than 0  (i.e., when ERRc is minimal, Kp ~= 1 / ERRc)
# Set Kd at about Kp*10
# Get Tmean within ~0.3 degree of SP before starting script.
# Start script and run for a few hours or so.  If Tmean oscillates (best to graph it), you probably need to reduce Kd.  If no oscillation but response is too slow, raise Kd.
# Stop script and get Tmean at least 1 C off SP.  Restart.  If there is overshoot and it goes through some cycles, you may need to reduce Kd.
# If you have problems, examine PK and PD in the log and see which is messing you up.  If all else fails you can try Ki. If you use Ki, make it small, ~ 0.1 or less.

# Uses joeschmuck's smartctl method for drive status (returns 0 if spinning, 2 in standby)
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
# Other method (camcontrol cmd -a) doesn't work with HBA
