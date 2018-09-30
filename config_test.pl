#!/usr/bin/perl

# test reading config files

use strict;
use warnings;
use 5.010;

# my $config_file = '/root/nas_fan_control/config.ini';
my $config_file = '/Users/kwh/sw_projects/git/nas_fan_control/PID_fan_control_config.ini';

my $hd_ave_target;
my $Kp;
my $Ki;
my $Kd;
my $num_disks;
my $hd_fan_duty_start;

our($config_Ta, $config_Kp, $config_Ki, $config_Kd, $config_num_disks, $config_hd_fan_start);

if (do $config_file) {
  $hd_ave_target = $config_Ta // 38;               # default HD ave temp
  $Kp = $config_Kp // 16/3;                        # default Kp
  $Ki = $config_Ki // 0;                           # default Ki
  $Kd = $config_Kd // 24;                          # default Kd
  $num_disks = $config_num_disks // 2;             # default number of warmest disks to average temperature
  $hd_fan_duty_start = $config_hd_fan_start // 60; # HD fan duty cycle when script starts
} else {
  warn "Config file not found.  Using default values";
}

print "Ta = $hd_ave_target\n";
print "Kp = $Kp\n";
print "Ki = $Ki\n";
print "Kd = $Kd\n";
print "num disks = $num_disks\n";
print "HD fan start = $hd_fan_duty_start\n";

my $config_time = (stat($config_file))[9];
print "Config time = $config_time\n";

