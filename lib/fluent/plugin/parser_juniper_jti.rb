require 'juniper_telemetry_lib.rb'
require 'protobuf'
require 'jvision_top.pb.rb'
require 'port.pb.rb'
require 'lsp_stats.pb.rb'
require 'logical_port.pb.rb'
require 'firewall.pb.rb'

module Fluent
  class TextParser
    class JuniperJtiParser < Parser

      Plugin.register_parser("juniper_jti", self)

      config_param :output_format, :string, :default => 'structured'

      # This method is called after config_params have read configuration parameters
      def configure(conf)
        super

        ## Check if "output_format" has a valid value
        unless  @output_format.to_s == "structured" ||
                @output_format.to_s == "flat" ||
                @output_format.to_s == "statsd"

          raise ConfigError, "output_format value '#{@output_format}' is not valid. Must be : structured, flat or statsd"
        end
      end

      def parse(text)

        ## Decode GBP packet
        jti_msg =  TelemetryStream.decode(text)

        resource = ""

        ## Extract device name & Timestamp
        device_name = jti_msg.system_id
        gpb_time = epoc_to_sec(jti_msg.timestamp)

        ## Extract sensor
        begin
          jnpr_sensor = jti_msg.enterprise.juniperNetworks
          datas_sensors = JSON.parse(jnpr_sensor.to_json)
          $log.debug  "Extract sensor data from #{device_name} with output #{output_format}"
        rescue => e
          $log.warn   "Unable to extract sensor data sensor from jti_msg.enterprise.juniperNetworks, Error during processing: #{$!}"
          $log.debug  "Unable to extract sensor data sensor from jti_msg.enterprise.juniperNetworks, Data Dump : " + jti_msg.inspect.to_s
          return
        end

        ## Go over each Sensor
        datas_sensors.each do |sensor, s_data|

          ##############################################################
          ### Support for resource /junos/system/linecard/interface/  ##
          ##############################################################
          if sensor == "jnpr_interface_ext"

            resource = "/junos/system/linecard/interface/"

            datas_sensors[sensor]['interface_stats'].each do |datas|

              # Save all info extracted on a list
              sensor_data = []

              # Catch Exception during parsing
              begin
                ## Extract interface name and clean up
                # interface_name = datas['if_name']
                sensor_data.push({ 'device' => device_name  })
                sensor_data.push({ 'interface' => datas['if_name']  })

                # Check if the interface has a parent
                if datas.key?('parent_ae_name')
                  sensor_data.push({ 'interface_parent' =>  datas['parent_ae_name']  })
                  datas.delete("parent_ae_name")
                end

                ## Clean up Current object
                datas.delete("if_name")
                datas.delete("init_time")
                datas.delete("snmp_if_index")

                datas.each do |section, data|

                  ## egress_queue_info is an Array
                  if data.kind_of?(Array)
                    data.each do |queue|

                      ## Create local copy to avoid variable sharing
                      queue_sensor_data = sensor_data.dup

                      ## Save and Cleanup Queue number
                      queue_sensor_data.push({ 'egress_queue' => queue['queue_number']  })
                      queue.delete("queue_number")

                      queue.each do |type,value|
                        local_sensor_data = queue_sensor_data.dup
                        local_sensor_data.push({ 'type' => section + '.' + type  })
                        local_sensor_data.push({ 'value' => value  })

                        record = build_record(output_format, local_sensor_data)
                        yield gpb_time, record
                      end
                    end
                  else
                    data.each do |type,value|

                      ## Create local copy to avoid using some variable
                      local_sensor_data = sensor_data.dup

                      local_sensor_data.push({ 'type' => section + '.' + type  })
                      local_sensor_data.push({ 'value' => value  })

                      record = build_record(output_format, local_sensor_data)
                      yield gpb_time, record
                    end
                  end
                end
              rescue => e
                $log.warn   "Unable to parse " + sensor + " sensor, Error during processing: #{$!}"
                $log.debug  "Unable to parse " + sensor + " sensor, Data Dump : " + datas.inspect.to_s
              end
            end
            ##############################################################
            ### Support for resource /junos/system/linecard/firewall/  ##
            ##############################################################
            # elsif sensor == "jnpr_firewall_ext"
            #
            #   resource = "/junos/system/linecard/firewall"
            #
            #   datas_sensors[sensor]['firewall_stats'].each do |datas|
            #
            #     begin
            #       ## Extract interface name and clean up
            #       sensor_data.push({ 'device' => device_name  })
            #       sensor_data.push({ 'filter_name' => datas['filter_name']  })
            #
            #       ## Clean up Current object
            #       # datas.delete("filter_name")
            #
            #       $log.warn  "Sensor Filter : " + datas['filter_name']
            #
            #     rescue
            #       $log.warn   "Unable to parse " + sensor + " sensor, an error occured.."
            #       $log.debug  "Unable to parse " + sensor + " sensor, Data Dump : " + datas.inspect.to_s
            #     end
            #   end
            #####################################################################
            ### Support for resource /junos/services/label-switched-path/usage/##
            #####################################################################
            #datas Dump : {"name"=>"to_mx104-9", "instance_identifier"=>0,
            #  "counter_name"=>"c-25", "packets"=>2521648779, "bytes"=>2526692076558,
            #  "packet_rate"=>598640, "byte_rate"=>599837511}
            elsif sensor == "jnpr_lsp_statistics_ext"

              resource = "/junos/services/label-switched-path/usage/"

              datas_sensors[sensor]['lsp_stats_records'].each do |datas|

              # Save all info extracted on a list
              sensor_data = []

              begin
                ## Extract interface name and clean up
                sensor_data.push({ 'device' => device_name  })
                sensor_data.push({ 'lspname' => datas['name']  })
                sensor_data.push({ 'instance_identifier' => datas['instance_identifier']  })
                sensor_data.push({ 'counter_name' => datas['counter_name']  })

                ## Clean up Current object
                datas.delete("name")
                datas.delete("instance_identifier")
                datas.delete("counter_name")

                datas.each do |type, value|

                    sensor_data.push({ 'type' =>  'lsp_stats.' + type  })
                    sensor_data.push({ 'value' => value  })

                    record = build_record(output_format, sensor_data)
                    yield gpb_time, record

                end
              rescue => e
                $log.warn   "Unable to parse " + sensor + " sensor, Error during processing: #{$!}"
                $log.debug  "Unable to parse " + sensor + " sensor, Data Dump : " + datas_sensors.inspect.to_s
              end
            end

            ##############################################################
            ### Support for resource /junos/system/linecard/interface/logical/usage ##
            ##############################################################
            elsif sensor == "jnprLogicalInterfaceExt"

              resource = "/junos/system/linecard/interface/logical/usage"

              datas_sensors[sensor]['interface_info'].each do |datas|

              # Save all info extracted on a list
              sensor_data = []

              begin
                ## Extract interface name and clean up
                sensor_data.push({ 'device' => device_name  })
                sensor_data.push({ 'interface' => datas['if_name']  })

                ## Clean up Current object
                datas.delete("if_name")
                datas.delete("init_time")
                datas.delete("snmp_if_index")
                datas.delete("op_state")

                datas.each do |section, data|
                  data.each do |type, value|

                    sensor_data.push({ 'type' => section + '.' + type  })
                    sensor_data.push({ 'value' => value  })

                    record = build_record(output_format, sensor_data)
                    yield gpb_time, record

                  end
                end
              rescue => e
                $log.warn   "Unable to parse " + sensor + " sensor, Error during processing: #{$!}"
                $log.debug  "Unable to parse " + sensor + " sensor, Data Dump : " + datas.inspect.to_s
              end
            end

            ##############################################################
            ### Support for resource /junos/system/linecard/firewall/   ##
            ##############################################################
            #{"message":"Unable to parse jnpr_firewall_ext sensor, Data Dump : {\"jnpr_firewall_ext\"=>
            #{\"firewall_stats\"=>[{\"filter_name\"=>\"__default_bpdu_filter__\", \"timestamp\"=>1465467390, \"memory_usage\"=>[{\"name\"=>\"HEAP\", \"allocated\"=>2440}]},
            #{\"filter_name\"=>\"test\", \"timestamp\"=>1465467390, \"memory_usage\"=>[{\"name\"=>\"HEAP\", \"allocated\"=>1688}],
            #\"counter_stats\"=>[{\"name\"=>\"cnt1\", \"packets\"=>79, \"bytes\"=>6320}]},
            #{\"filter_name\"=>\"__default_arp_policer__\", \"timestamp\"=>1464456904, \"memory_usage\"=>[{\"name\"=>\"HEAP\", \"allocated\"=>1600}]}]}}"}
            elsif sensor == "jnpr_firewall_ext"

              resource = "/junos/system/linecard/firewall/"

              datas_sensors[sensor]['firewall_stats'].each do |datas|

                  # Save all info extracted on a list
                  sensor_data = []

                  begin
                    ## Extract interface name and clean up
                    sensor_data.push({ 'device' => device_name  })
                    sensor_data.push({ 'filter_name' => datas['filter_name']  })
                    sensor_data.push({ 'filter_timestamp' => datas['timestamp']  })

                    ## Clean up Current object
                    datas.delete("filter_name")
                    datas.delete("timestamp")

                    datas['memory_usage'].each do |memory_usage|
                        sensor_data.push({ 'type' =>  'memory_usage.' + memory_usage['name'] })
                        sensor_data.push({ 'value' =>  memory_usage['allocated']  })
                        memory_usage.delete("name")
                        memory_usage.delete("allocated")

                        record = build_record(output_format, sensor_data)
                        yield gpb_time, record
                    end

                    ## Clean up Current object
                    datas.delete("memory_usage")

                    if datas.key?('counter_stats')
                        datas['counter_stats'].each do |counters|
                             sensor_data.push({ 'filter_counter_name' => counters['name']  })
                             counters.delete("name")
                             counters.each do |type, value|
                                 sensor_data.push({ 'type' =>  'filter_counter.' + type  })
                                 sensor_data.push({ 'value' => value  })
                                 record = build_record(output_format, sensor_data)
                                 yield gpb_time, record
                            end
                        end
                    end

                  rescue => e
                    $log.warn   "Unable to parse " + sensor + " sensor, Error during processing: #{$!}"
                    $log.debug  "Unable to parse " + sensor + " sensor, Data Dump : " + datas_sensors.inspect.to_s
                  end
              end
          else
            $log.warn  "Unsupported sensor : " + sensor
            # puts datas_sensors[sensor].inspect.to_s
          end
        end
      end
    end
  end
end
