#! /usr/local/bin/perl

$ipmitool = "/usr/local/bin/ipmitool";

$n = 25;

while( $n < 100){
    set_fan_zone_duty_cycle(0,$n);
    set_fan_zone_duty_cycle(1,$n);
    sleep 10;
    $ave_fan_speed = ( get_fan_speed('FAN1') + get_fan_speed('FAN2') + get_fan_speed('FAN4') + get_fan_speed('FAN5') + get_fan_speed('FANA') + get_fan_speed('FANB') + get_fan_speed('FANC') ) / 7;
    print "$n   $ave_fan_speed\n";
    $n +=1;
}

sub get_fan_speed
{
    my ($fan_name) = @_;
    
    my $command = "$ipmitool sdr | grep $fan_name";

     my $output = `$command`;
      my @vals = split(" ", $output);
      my $fan_speed = "$vals[2]";
    
    return $fan_speed;
}

sub set_fan_zone_duty_cycle
{
    my ( $zone, $duty ) = @_;
    
    `$ipmitool raw 0x30 0x70 0x66 0x01 $zone $duty`;
    
    return;
}
