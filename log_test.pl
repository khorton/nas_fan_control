#!/usr/bin/env perl

# logging test

$Kp = 5.333;
$Ki = 0;
$Kd = 120;
$hd_ave_target = 36;
$hd_polling_interval = 10;

$sleep_duration = ($hd_polling_interval * 1000000) - 100000;
my $last_hd_check_time = 0;

$log = '/root/fan_control.log';

use POSIX qw(strftime);
use Time::HiRes qw(usleep nanosleep);


main();

sub main
{
    # Print Log Header
    @hd_list = print_header();
    
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
                @hd_list = print_header();
            }
            my $timestring = build_time_string();
            print "$timestring\n";
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

sub get_hd_max_ave_temp
# return maximum and average HD temperatures
{
    my $max_temp = 0;
    my $temp_sum = 0;
    my $HD_count = 0;

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
            $temp_sum += $temp;
            $HD_count +=1;
            $max_temp = $temp if $temp > $max_temp;
        }
    }

    my $ave_temp = $temp_sum / $HD_count;

    return ($max_temp, $ave_temp);
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
    @hd_list = get_hd_list();
    my $timestring = build_time_string();
    my $datestring = build_date_string();
    print "$datestring  ---  Target HD Temperature = $hd_ave_target  ---  Kp = $Kp, Ki = $Ki, Kd = $Kd\n";
    print "$timestring";
    foreach $item (@hd_list)
    {
        printf("%5s", $item)
    }
    print "  MaxT  AveT Terr  Mode  RPM  Duty  CPUT   P   I   D\n";
    
    return @hd_list;
}
