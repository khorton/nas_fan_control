#!/usr/bin/env perl

# logging test


$log = '/root/fan_control.log';

use POSIX qw(strftime);


main();

sub main
{
    @hd_list = get_hd_list();
    my $timestring = build_time_string();
    my $datestring = build_date_string();
    print "$datestring\n";
    print "$timestring";
    foreach $item (@hd_list)
    {
        printf("  %5s", $item)
    }
}

sub get_hd_list
{
    my $disk_list = `camcontrol devlist | grep -v "SSD" | sed 's:.*(::;s:).*::;s:,pass[0-9]*::;s:pass[0-9]*,::' | egrep '^[a]*da[0-9]+\$' | tr '\012' ' '`;
    dprint(3,"$disk_list\n");

    my @vals = split(" ", $disk_list);
    
    foreach my $item (@vals)
    {
        dprint(2,"$item\n");
    }

    return @vals;
}

sub get_hd_temp
{
    my $max_temp = 0;
    
    foreach my $item (@hd_list)
    {
        my $disk_dev = "/dev/$item";
        my $command = "/usr/local/sbin/smartctl -A $disk_dev | grep Temperature_Celsius";
         
        dprint( 3, "$command\n" );
        
        my $output = `$command`;

        dprint( 2, "$output");

        my @vals = split(" ", $output);

        # grab 10th item from the output, which is the hard drive temperature (on Seagate NAS HDs)
          my $temp = "$vals[9]";
        chomp $temp;
        
        if( $temp )
        {
            dprint( 1, "$disk_dev: $temp\n");
            
            $max_temp = $temp if $temp > $max_temp;
        }
    }

    dprint(0, "Maximum HD Temperature: $max_temp\n");

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

        dprint( 3, "$command\n" );

        my $output = `$command`;

        dprint( 2, "$output");

        my @vals = split(" ", $output);

        # grab 10th item from the output, which is the hard drive temperature (on Seagate NAS HDs)
        my $temp = "$vals[9]";
        chomp $temp;

        if( $temp )
        {
            dprint( 1, "$disk_dev: $temp\n");
            $temp_sum += $temp;
            $HD_count +=1;
            $max_temp = $temp if $temp > $max_temp;
        }
    }

    my $ave_temp = $temp_sum / $HD_count;

    dprint(0, "Average HD Temperature: $ave_temp\n");


    return ($max_temp, $ave_temp);
}

sub get_cpu_temp_sysctl
{
    # significantly more efficient to filter to dev.cpu than to just grep the whole lot!
    my $core_temps = `sysctl -a dev.cpu | egrep -E \"dev.cpu\.[0-9]+\.temperature\" | awk '{print \$2}' | sed 's/.\$//'`;
    chomp($core_temps);

    dprint(3,"core_temps:\n$core_temps\n");

    my @core_temps_list = split(" ", $core_temps);
    
    dprint_list( 4, "core_temps_list", @core_temps_list );

    my $max_core_temp = 0;
    
    foreach my $core_temp (@core_temps_list)
    {
        if( $core_temp )
        {
            dprint( 2, "core_temp = $core_temp C\n");
            
            $max_core_temp = $core_temp if $core_temp > $max_core_temp;
        }
    }

    dprint(1, "CPU Temp: $max_core_temp\n");

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
