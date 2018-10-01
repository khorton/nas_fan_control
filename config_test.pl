#!/usr/bin/perl

# test reading config files

use strict;
use warnings;
use 5.010;

# my $config_file = '/root/nas_fan_control/config.ini';
my $config_file = '/Users/kwh/sw_projects/git/nas_fan_control/PID_fan_control_config.ini';
my $config_time = (stat($config_file))[9];

my $default_hd_ave_target = 38;         # PID control loop will target this average temperature for the warmest N disks
my $default_Kp = 16/3;                  # PID control loop proportional gain
my $default_Ki = 0;                     # PID control loop integral gain
my $default_Kd = 24;                    # PID control loop derivative gain
my $default_hd_num_peak = 2;            # Number of warmest HDs to use when calculating average temp
my $default_hd_fan_duty_start     = 60; # HD fan duty cycle when script starts

our($config_Ta, $config_Kp, $config_Ki, $config_Kd, $config_num_disks, $config_hd_fan_start);
our($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start);

main();

sub main
{
    ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time) = read_config();
    
    while ()
    {
        sleep(10);
        my $config_time_new = (stat($config_file))[9];
        if ($config_time_new > $config_time)
        {
            ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time) = read_config();
            
            print "Ta = $hd_ave_target\n";
            print "Kp = $Kp\n";
            print "Ki = $Ki\n";
            print "Kd = $Kd\n";
            print "num disks = $hd_num_peak\n";
            print "HD fan start = $hd_fan_duty_start\n";
            
            print "Config time = $config_time\n";
            print "=================================\n\n";
        }
    }
}

sub read_config 
{
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
      warn "Config file not found.  Using default values";
    }
    
    return ($hd_ave_target, $Kp, $Ki, $Kd, $hd_num_peak, $hd_fan_duty_start, $config_time);
}
