#!/usr/bin/env perl

# logging test

$Kp = 5.333;
$Ki = 0;
$Kd = 120;
$hd_ave_target = 36;
$hd_polling_interval = 10;
$log = '/root/fan_control2.log';
@hd_fan_list = ("FANA", "FANB", "FANC");

$sleep_duration = ($hd_polling_interval * 1000000) - 100000;
my $last_hd_check_time = 0;
my @hd_list = ();
my $hd_max_temp = 0;
my $hd_ave_temp = 0;
my @hd_temps = ();
my $hd_fan_mode = "";
my $ave_fan_speed = 0;

use POSIX qw(strftime);
use Time::HiRes qw(usleep nanosleep);

open LOG, ">", $log or die $!;


main();

sub main
{
    # Print Log Header
    @hd_list = get_hd_list();
    print_header(@hd_list);
    
    while()
    {
        my $check_time = time;
        usleep($sleep_duration);
        # sleep 9;
        if( $check_time - $last_hd_check_time >= $hd_polling_interval )
        {
            @last_hd_list = @hd_list;
            $last_hd_check_time = $check_time;
            @hd_list = get_hd_list();
            if (@hd_list != @last_hd_list)
            {
                @hd_list = print_header(@hd_list);
            }
            my $timestring = build_time_string();
            ($hd_max_temp, $hd_ave_temp, @hd_temps) = get_hd_temps();
            print LOG "$timestring";
            foreach my $item (@hd_temps)
            {
                printf(LOG "%5s", $item);
            }
            printf(LOG "%5s", $hd_max_temp);
            printf(LOG "%6s", $hd_ave_temp);
            printf(LOG "%6.2f", $hd_ave_temp - $hd_ave_target);
            
            my $m = get_fan_mode_code();
            if ($m == 1) { $hd_fan_mode = "Full"; }
            elsif ($m == 0) { $hd_fan_mode = " Std"; }
            elsif ($m == 2) { $hd_fan_mode = " Opt"; }
            elsif ($m == 4) { $hd_fan_mode = " Hvy"; }
            printf(LOG "%6s", $hd_fan_mode);
            $ave_fan_speed = get_fan_ave_speed(@hd_fan_list);
            printf(LOG "%6s\n", $ave_fan_speed)
        }
    }
}

sub get_hd_list
{
    my $disk_list = `camcontrol devlist | grep -v "SSD" | sed 's:.*(::;s:).*::;s:,pass[0-9]*::;s:pass[0-9]*,::' | egrep '^[a]*da[0-9]+\$' | tr '\012' ' '`;

    my @vals = split(" ", $disk_list);
    
    return @vals;
}

sub get_hd_temp
{
    my $max_temp = 0;
    
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
            $max_temp = $temp if $temp > $max_temp;
        }
    }

    return $max_temp;
}

sub get_hd_temps
# return maximum, average HD temperatures and array of individual temps
{
    my $max_temp = 0;
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
        }
    }

    my $ave_temp = $temp_sum / $HD_count;

    return ($max_temp, $ave_temp, @temp_list);
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

sub print_header
{
    @hd_list = @_;
    my $timestring = build_time_string();
    my $datestring = build_date_string();
    print LOG "$datestring  ---  Target HD Temperature = $hd_ave_target  ---  Kp = $Kp, Ki = $Ki, Kd = $Kd\n";
    print LOG "$timestring";
    foreach $item (@hd_list)
    {
        printf(LOG "%5s", $item)
    }
    print LOG "  MaxT  AveT Terr  Mode  RPM  Duty  CPUT   P   I   D\n";
    
    return @hd_list;
}

sub get_fan_ave_speed
{
    my $speed_sum = 0;
    my $fan_count = 0;
    foreach my $fan (@_)
    {
        $speed_sum += get_fan_speed(($fan));
        $fan_count += 1;
    }
    
    my $ave_speed = sprintf("%1", $speed_sum / $fan_count);
    
    return $ave_speed;
}

#unmodded

sub get_fan_speed
{
    my ($fan_name) = @_;
    
    my $fan = get_fan_header_by_name( $fan_name );

    my $command = "$ipmitool sdr | grep $fan";
    #dprint( 4, "get fan speed command = $command\n");

     my $output = `$command`;
      my @vals = split(" ", $output);
      my $fan_speed = "$vals[2]";

    #dprint( 3, "fan_speed = $fan_speed\n");


    if( $fan_speed eq "no" )
    {
        #dprint( 0, "$fan_name Fan speed: No reading\n");
        $fan_speed = -1;
    }
    elsif( $fan_speed eq "disabled" )
    {
        #dprint( 0, "$fan_name Fan speed: Disabled\n");
        $fan_speed = -1;

    }
    elsif( $fan_speed > 10000 || $fan_speed < 0 )
    {
        #dprint( 0, "$fan_name Fan speed: $fan_speed RPM, is nonsensical\n");
        $fan_speed = -1;
    }
    else    
    {
        #dprint( 1, "$fan_name Fan speed: $fan_speed RPM\n");
    }
    
    return $fan_speed;
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

sub get_cpu_temp_sysctl
{
    # significantly more efficient to filter to dev.cpu than to just grep the whole lot!
    my $core_temps = `sysctl -a dev.cpu | egrep -E \"dev.cpu\.[0-9]+\.temperature\" | awk '{print \$2}' | sed 's/.\$//'`;
    chomp($core_temps);

    my @core_temps_list = split(" ", $core_temps);
    
    my $max_core_temp = 0;
    
    foreach my $core_temp (@core_temps_list)
    {
        if( $core_temp )
        {
            $max_core_temp = $core_temp if $core_temp > $max_core_temp;
        }
    }

    $last_cpu_temp = $max_core_temp; #possible that this is 0 if there was a fault reading the core temps

    return $max_core_temp;
}


