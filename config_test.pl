#!/usr/bin/perl

# test reading config files

use strict;
use warnings;

# my $config_file = '/root/nas_fan_control/config.ini';
my $config_file = '/Users/kwh/sw_projects/git/nas_fan_control/config.ini';

my $Ta = 38;
my $Kp = 5.333;
my $Ki = 0;
my $Kd = 24;
my $num_disks = 2;

our($config_Ta, $config_Kp, $config_Ki, $config_Kd, $config_num_disks);

if (do $config_file) {
  $Ta = $config_Ta;
  $Kp = $config_Kp;
  $Ki = $config_Ki;
  $Kd = $config_Kd;
  $num_disks = $config_num_disks;
} else {
  warn "Config file not found.  Using default values";
}

print "Ta = $Ta\n";

