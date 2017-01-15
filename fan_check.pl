#! /usr/local/bin/perl

$n = 80;
$ave_fan_speed = ( get_fan_speed('FAN1') + get_fan_speed('FAN2') + get_fan_speed('FAN4') + get_fan_speed('FAN5') + get_fan_speed('FANA') + get_fan_speed('FANB') + get_fan_speed('FANC') ) / 7;
print $ave_fan_speed;

sub get_fan_speed
{
    my ($fan_name) = @_;
    
    my $command = "$ipmitool sdr | grep $fan_name";

     my $output = `$command`;
      my @vals = split(" ", $output);
      my $fan_speed = "$vals[2]";
    
    return $fan_speed;
}

