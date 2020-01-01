#!/bin/bash
# switch config files so that 2d_config.ini is the active config
rm  /root/nas_fan_control/PID_fan_control_config.ini
ln -s /root/nas_fan_control/2d_config.ini /root/nas_fan_control/PID_fan_control_config.ini
touch /root/nas_fan_control/2d_config.ini
