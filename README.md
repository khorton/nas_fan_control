# nas_fan_control
collection of scripts to control fan speed on NAS boxes

PID_fan_control.pl - Perl fan control script based on the hybrid fan control script created by @Stux, and posted at:
https://forums.freenas.org/index.php?threads/script-hybrid-cpu-hd-fan-zone-controller.46159/ .  @Stux's script was modified by replacing his fan control loop with a PID controller.  This version of the script was settings and gains used by the author on a Norco RPC-4224, with the following fans:

*  3 x Noctua NF-F12 PWM 120mm fans: hard drive wall fans replaced with .  
*  2 x Noctua NF-A8 PWM 80mm fans: chassis exit fans.  
*  1 x Noctua NH-U9DX I4: CPU cooler.

The hard drive fans are connected to fan headers assigned to the hard drive temperature control portion of the script.  The chassis exit fans and the CPU cooler are connected to fan headers assigned to the CPU temperature control portion of the script.

See the scripts for more info and commentary.

Discussion on the FreeNAS forums: https://forums.freenas.org/index.php?threads/pid-fan-controller-perl-script.50908/
