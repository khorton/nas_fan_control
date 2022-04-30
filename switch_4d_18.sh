#!/bin/bash
# switch config files so that 4d_config_18.ini is the active config
rm  /root/nas_fan_control/PID_fan_control_config.ini
ln -s /root/nas_fan_control/4d_config_18.ini /root/nas_fan_control/PID_fan_control_config.ini
touch /root/nas_fan_control/4d_config_18.ini
