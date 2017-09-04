# nas_fan_control
collection of scripts to control fan speed on NAS boxes

PID_fan_control.pl - Perl fan control script based on the hybrid fan control script created by @Stux, and posted at:
https://forums.freenas.org/index.php?threads/script-hybrid-cpu-hd-fan-zone-controller.46159/ .  @Stux's script was modified by replacing his fan control loop with a PID controller.  This version of the script was settings and gains used by the author on a Norco RPC-4224, with the following fans:

*  3 x Noctua NF-F12 PWM 120mm fans: hard drive wall fans replaced with .  
*  2 x Noctua NF-A8 PWM 80mm fans: chassis exit fans.  
*  1 x Noctua NH-U9DX I4: CPU cooler.

The hard drive fans are connected to fan headers assigned to the hard drive temperature control portion of the script.  The chassis exit fans and the CPU cooler are connected to fan headers assigned to the CPU temperature control portion of the script.

PID_fan_control_borg.pl - This is the same basic script as above, but with settings and gains as used by the author on a Fractal Design Node 804, with the following fans:

* Deep Cool UF140: hard drive side of the case on the back
* Deep Cool UF110: hard drive side of the case on the front, in the upper of two available locations.
* Stock Fractal Design exit fan on the motherboard side of the case, running at medium speed.
* Thermaltake Gravity i1: CPU cooler

See the script for more info and commentary.
