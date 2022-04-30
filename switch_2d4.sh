#!/bin/bash
# switch config files so that 2d_config_4.ini is the active config
rm  /root/nas_fan_control/PID_fan_control_config.ini
ln -s /root/nas_fan_control/2d_config_4.ini /root/nas_fan_control/PID_fan_control_config.ini
touch /root/nas_fan_control/2d_config_4.ini
